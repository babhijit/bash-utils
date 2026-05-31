#!/bin/bash
# =============================================================================
#
# Script:      selective_copy.sh
#
# Description:
#   Cross-user, *phased* selective copy for environments where:
#     - Source and target are different unix users on the same host.
#     - Neither has sudo, so cross-account writes go through a world-writable
#       (or shared-group) staging area in /tmp.
#     - /tmp has a HARD SIZE CAP (e.g. ~1 GB) far smaller than the data to move
#       (e.g. ~7 GB). The copy therefore cannot stage everything at once; it is
#       broken into size-bounded BATCHES and drained between them so the peak
#       /tmp footprint never exceeds one batch.
#
#   Direction (this project): SOURCE = FAT1 (opc_d1), TARGET = FAT2 (opc_d2).
#       FAT1  --(opc_d1: stage)-->  /tmp staging  --(opc_d2: deploy)-->  FAT2
#
#   THE WORKFLOW (operator-driven, two independent logins, NO inter-process
#   synchronization — each side only ever reads shared state and writes its OWN
#   marker files):
#
#     0. plan      (as SOURCE user)  ONCE
#          Walk the configured items, bin-pack every file/symlink/empty-dir into
#          batches each <= STAGING_BUDGET_BYTES, record every directory's
#          mode+mtime (for the final reconcile), and write per-batch manifests.
#          Prints the batch breakdown so the operator sees it before committing.
#
#     1. prepare   (as SOURCE user)  repeat
#          Stage the NEXT pending batch from SOURCE into staging (dest layout),
#          record original lstat (mode/mtime/symlink) to a per-batch CSV, then
#          widen perms so the target user can read. Marks the batch STAGED.
#          Refuses (no-op) if a batch is already staged awaiting deploy.
#
#     2. deploy    (as TARGET user)  repeat
#          Copy the staged batch into the target tree, restore mode+mtime+symlink
#          target from the per-batch CSV (NOT ownership — target files stay
#          owned by the target user, which is correct), then DRAIN staging to
#          free /tmp for the next batch. Marks the batch DEPLOYED.
#
#       --> rinse and repeat 1<->2 (alternating logins) until all batches DEPLOYED.
#
#     3. finalize  (as TARGET user)  ONCE
#          Create configured symlinks, apply nested transforms, then restore
#          every directory's mode+mtime from the plan (deepest-first). Directory
#          mtimes MUST be fixed here, not per-batch: a dir created in an early
#          batch is re-bumped when a later batch writes a child into it.
#
#     status   (either user, anytime)  prints the batch table.
#     cleanup  removes staging (and optionally the plan/state dir).
#
#   LOGGING (always on, two channels):
#     - HUMAN  : info()/warn()/success() to stderr + a per-mode .log file.
#     - MACHINE: emit_event() JSONL to <state>/events.jsonl (parse with jq).
#     - LIVE   : rsync runs with --info=progress2 so the console shows a moving
#                percentage/rate — proof the copy is working, not frozen.
#
#   ERROR HANDLING (operator-in-the-loop by design):
#     - A free-space preflight (check_free_space_bytes) dies BEFORE rsync if the
#       batch would not fit, rather than failing mid-copy.
#     - A failed stage/deploy writes a *_FAILED marker with the reason, cleans
#       partial staging where safe, and exits non-zero with remediation. Re-run
#       resumes that batch (idempotent). The target tree is never left with a
#       half-restored batch silently.
#
# Threat model (no-sudo environment) — unchanged from the original design:
#   - Staging in world-writable /tmp is the COST OF NO SUDO. Mitigations:
#       1. A fixed --staging-dir (or config STAGING_DIR), perms set explicitly.
#       2. Optional --shared-group tightens staging+state to 2770 + setgid.
#       3. --source-user/--target-user pin the expected `id -un` per stage.
#   - prepare records lstat BEFORE widening perms, so the recorded mode is the
#     ORIGINAL source mode, not the widened staging mode.
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_bash_version 4 2
set -euo pipefail

# =============================================================================
#                              JOB CONFIGURATION
# =============================================================================
#
# Nothing job-specific is hardcoded. Supplied at runtime via:
#   --config <file>   a sourced bash snippet (see selective_copy.conf.example)
#   --source-base / --target-base / --staging-dir / --state-dir / --budget-bytes
#
# Config file contract (all optional except the base dir the mode needs):
#   SOURCE_BASE_DIR="/applications/opc_d1"
#   TARGET_BASE_DIR="/applications/opc_d2"
#   STAGING_DIR="/tmp/test_f2/migration"            # one batch lives here at a time
#   STATE_DIR="/tmp/test_f2/migration.state"        # plan/manifests/markers (persists)
#   STAGING_BUDGET_BYTES=996147200                  # per-batch ceiling (default 950 MiB)
#   COPY_MAPPING=( "src_name|dest_name" ... )
#   SYMBOLIC_LINK_MAPPING=( "src_link|dest_link|dest_target" ... )
#   EXCLUDE_MAPPING=( "src_name:relative_pattern" ... )
#   NESTED_ITEM_TRANSFORM=( "rel_path|new_name|new_link_target" ... )

SOURCE_BASE_DIR=""
TARGET_BASE_DIR=""

# Default per-batch staging budget: 950 MiB. Sits under a ~1 GB /tmp hard cap
# with headroom for filesystem overhead and the small state dir. Overridable by
# config (STAGING_BUDGET_BYTES) or --budget-bytes.
STAGING_BUDGET_BYTES=996147200

# Populated by --config. Declared empty (not readonly) so the config may set
# them; locked readonly in parse_args once config + CLI are applied.
COPY_MAPPING=()
SYMBOLIC_LINK_MAPPING=()
EXCLUDE_MAPPING=()
NESTED_ITEM_TRANSFORM=()

# =============================================================================
#                              GLOBAL STATE (CLI)
# =============================================================================

MODE=""
CONFIG_FILE=""
STAGING_DIR=""           # where the CURRENT batch is staged (drained between batches)
STATE_DIR=""             # plan + manifests + markers + logs (persists across batches)
SOURCE_USER=""
TARGET_USER=""
SHARED_GROUP=""
FORCE_CLEANUP=0
CLEANUP_STATE=0          # cleanup also removes STATE_DIR when set

# Filled by init_logs(): the machine-readable JSONL event log path.
EVENTS_LOG=""

# =============================================================================
#                              USAGE
# =============================================================================

usage() {
    cat >&2 <<EOF
Usage: $0 --mode <plan|prepare|deploy|finalize|status|cleanup> --config <file> [options]

Phased cross-user copy under a small /tmp cap. Job specifics (base dirs, item
lists, staging path, batch budget) come from --config and/or the flags below.
See selective_copy.conf.example for the contract.

WORKFLOW (alternate the two logins; no synchronization between them):
  as SOURCE user:  $0 --mode plan    --config C --source-user U1 --target-user U2
  repeat {
    as SOURCE user: $0 --mode prepare --config C --source-user U1 --target-user U2
    as TARGET user: $0 --mode deploy  --config C --target-user U2
  } until status shows all batches DEPLOYED
  as TARGET user:  $0 --mode finalize --config C --target-user U2

MODES:
  plan       (SOURCE) Enumerate + bin-pack into batches; write manifests/state.
  prepare    (SOURCE) Stage the next pending batch into /tmp; mark STAGED.
  deploy     (TARGET) Deploy the staged batch to target; restore attrs; drain.
  finalize   (TARGET) Symlinks + nested transforms + directory mtime reconcile.
  status     (either) Print the batch table (human) + machine summary.
  cleanup    (either) Remove staging dir [+ --cleanup-state to remove state].

OPTIONS:
  --config FILE         Job config (sourced bash). See the .example file.
  --source-user USER    Expected uid name for plan/prepare (sanity check).
  --target-user USER    Expected uid name for deploy/finalize (sanity check).
  --source-base PATH     Override SOURCE_BASE_DIR.
  --target-base PATH     Override TARGET_BASE_DIR.
  --staging-dir PATH     Override STAGING_DIR (one batch at a time lives here).
  --state-dir PATH       Override STATE_DIR (default: <staging-dir>.state).
  --budget-bytes N       Override STAGING_BUDGET_BYTES (per-batch ceiling).
  --shared-group GROUP   Tighten staging+state to 2770 (setgid) for this group.
  --cleanup-state        (cleanup) also remove the state/plan dir.
  --force                (cleanup) proceed even if staging not owned by you.
  --log-file PATH        Human log path (default: <state-dir>/<mode>.log).

EXAMPLES:
  $0 --mode plan    --config ./selective_copy.conf --source-user opc_d1 --target-user opc_d2
  $0 --mode prepare --config ./selective_copy.conf --source-user opc_d1 --target-user opc_d2
  $0 --mode deploy  --config ./selective_copy.conf --target-user opc_d2
  $0 --mode finalize --config ./selective_copy.conf --target-user opc_d2
  $0 --mode status  --config ./selective_copy.conf
EOF
    exit 1
}

parse_args() {
    local log_arg="" cli_source_base="" cli_target_base="" cli_staging="" \
          cli_state="" cli_budget=""
    if [ "$#" -eq 0 ]; then usage; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)          MODE="$2"; shift 2 ;;
            --config)        CONFIG_FILE="$2"; shift 2 ;;
            --staging-dir)   cli_staging="$2"; shift 2 ;;
            --state-dir)     cli_state="$2"; shift 2 ;;
            --budget-bytes)  cli_budget="$2"; shift 2 ;;
            --source-user)   SOURCE_USER="$2"; shift 2 ;;
            --target-user)   TARGET_USER="$2"; shift 2 ;;
            --source-base)   cli_source_base="$2"; shift 2 ;;
            --target-base)   cli_target_base="$2"; shift 2 ;;
            --shared-group)  SHARED_GROUP="$2"; shift 2 ;;
            --cleanup-state) CLEANUP_STATE=1; shift ;;
            --force)         FORCE_CLEANUP=1; shift ;;
            --log-file)      log_arg="$2"; shift 2 ;;
            -h|--help)       usage ;;
            *) echo "Error: Unknown argument '$1'" >&2; usage ;;
        esac
    done

    [ -n "$MODE" ] || usage

    if [ -n "$CONFIG_FILE" ]; then
        [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
        # shellcheck disable=SC1090  # operator-authored config, sourced as bash
        source "$CONFIG_FILE"
    fi

    # CLI overrides win over config.
    [ -n "$cli_source_base" ] && SOURCE_BASE_DIR="$cli_source_base"
    [ -n "$cli_target_base" ] && TARGET_BASE_DIR="$cli_target_base"
    [ -n "$cli_staging" ]     && STAGING_DIR="$cli_staging"
    [ -n "$cli_state" ]       && STATE_DIR="$cli_state"
    [ -n "$cli_budget" ]      && STAGING_BUDGET_BYTES="$cli_budget"

    # Normalize paths.
    [ -n "$SOURCE_BASE_DIR" ] && SOURCE_BASE_DIR="$(normalize_path "$SOURCE_BASE_DIR")"
    [ -n "$TARGET_BASE_DIR" ] && TARGET_BASE_DIR="$(normalize_path "$TARGET_BASE_DIR")"
    [ -n "$STAGING_DIR" ]     && STAGING_DIR="$(normalize_path "$STAGING_DIR")"
    [ -n "$STATE_DIR" ]       && STATE_DIR="$(normalize_path "$STATE_DIR")"

    # STATE_DIR defaults next to STAGING_DIR. It must persist across batches, so
    # it is deliberately NOT inside STAGING_DIR (which is drained each batch).
    if [ -z "$STATE_DIR" ] && [ -n "$STAGING_DIR" ]; then
        STATE_DIR="${STAGING_DIR}.state"
    fi

    case "$STAGING_BUDGET_BYTES" in
        ''|*[!0-9]*) die "STAGING_BUDGET_BYTES must be a positive integer (got '$STAGING_BUDGET_BYTES')" ;;
    esac
    [ "$STAGING_BUDGET_BYTES" -gt 0 ] || die "STAGING_BUDGET_BYTES must be > 0"

    readonly SOURCE_BASE_DIR TARGET_BASE_DIR STAGING_BUDGET_BYTES \
             COPY_MAPPING SYMBOLIC_LINK_MAPPING EXCLUDE_MAPPING NESTED_ITEM_TRANSFORM

    [ -n "$log_arg" ] && export LOG_FILE="$log_arg"

    if [ "$(id -u)" -eq 0 ]; then
        die "Refusing to run as root: defeats the split-user permission model"
    fi
}

# =============================================================================
#                              IDENTITY / PATHS
# =============================================================================

assert_running_as() {
    local expected_user="$1" label="$2" actual
    actual="$(id -un)"
    if [ "$actual" != "$expected_user" ]; then
        die "$label expected user '$expected_user'; running as '$actual'"
    fi
}

manifest_file()  { printf '%s/manifests/batch_%03d.tsv' "$STATE_DIR" "$1"; }
attrs_csv()      { printf '%s/manifests/batch_%03d.attrs.csv' "$STATE_DIR" "$1"; }
marker_file()    { printf '%s/markers/batch_%03d.%s' "$STATE_DIR" "$1" "$2"; }
plan_file()      { printf '%s/plan.csv' "$STATE_DIR"; }
dirs_file()      { printf '%s/dirs.tsv' "$STATE_DIR"; }
batch_count_file() { printf '%s/batch_count' "$STATE_DIR"; }

# apply_share_perms <path>
# Open <path> so the other user can traverse/read it. With --shared-group the
# group is set and 2770/660 used; otherwise the no-sudo fallback is world perms.
apply_share_perms_dir() {
    local d="$1"
    if [ -n "$SHARED_GROUP" ]; then
        chgrp "$SHARED_GROUP" "$d" 2>/dev/null || die "chgrp '$SHARED_GROUP' failed on $d (group must exist; you must be a member)"
        chmod 2770 "$d"   # setgid; group-writable so EITHER user can drain
    else
        # 0777 NOT 1777: the deploy user must be able to delete the (stage-user-
        # owned) staged files when draining. The sticky bit (1777) restricts
        # unlink to the file owner, which would make the cross-user drain fail
        # silently. World-writable staging is already the accepted cost of no
        # sudo (see threat model); the unpredictable path + identity checks +
        # tamper detection are the mitigations, not the sticky bit.
        chmod 0777 "$d"
    fi
}

# =============================================================================
#                              LOGGING SETUP
# =============================================================================

# init_logs <mode>
# Sets the human LOG_FILE (unless the operator pinned one) and the machine
# EVENTS_LOG, both under STATE_DIR so a multi-session run accumulates one
# coherent trail. Appends, never truncates (resume-friendly).
init_logs() {
    local mode="$1" me; me="$(id -un)"
    [ -d "$STATE_DIR" ] || return 0
    # Per-USER log files (not shared): each operator writes only its own files,
    # so neither can hit "permission denied" appending to a file the other user
    # created (markers follow the same rule). Full timeline across both users:
    #   cat <state-dir>/events.*.jsonl | sort
    export LOG_FILE="${LOG_FILE:-${STATE_DIR}/${me}.log}"
    EVENTS_LOG="${STATE_DIR}/events.${me}.jsonl"
    info "=== mode=$mode user=$me host=$(hostname 2>/dev/null || echo '?') ==="
    emit_event "$EVENTS_LOG" "event=mode_start" "mode=$mode" "user=$me"
}

# =============================================================================
#                              RSYNC WITH LIVE PROGRESS
# =============================================================================

# run_rsync_live <label> <log_tag> [rsync args...]
# Runs rsync with a live overall-progress line on the console (--info=progress2,
# supported by rsync 3.1+ which is what RHEL7/centos:7 ships) so the operator
# can SEE it moving. Returns rsync's real exit code (run directly, not piped, so
# $? is rsync's). Emits a machine event with the resulting code.
run_rsync_live() {
    local label="$1" tag="$2"; shift 2
    info "rsync [$label] starting..."
    emit_event "$EVENTS_LOG" "event=rsync_start" "label=$label" "tag=$tag"
    local rc=0
    # --info=progress2: single moving progress line. --no-inc-recursive: build
    # the full file list first so the percentage is meaningful from the start.
    rsync -a --no-inc-recursive --info=progress2 --human-readable "$@" || rc=$?
    emit_event "$EVENTS_LOG" "event=rsync_end" "label=$label" "tag=$tag" "rc=$rc"
    return "$rc"
}

# =============================================================================
#                       ATTRIBUTE CSV (per batch) — record & restore
# =============================================================================
#
# The per-batch CSV is the operator's "reference for the problematic files":
# it captures the ORIGINAL source attributes so the target can be fixed up after
# the copy widens perms in staging. Columns (RFC4180-quoted via csv_quote_field;
# path-safe for commas/spaces):
#   Relative_Path,Type,Mode,Mtime_Epoch,Owner,Group,Symlink_Target
# Relative_Path is relative to the staging root, which equals the path relative
# to the target base (staging mirrors the dest layout) — so restore maps 1:1.
# Owner/Group are recorded for REFERENCE/audit only; they are NOT restored
# (target files are correctly owned by the target user, not the source user).

# attrs_record <root_dir> <out_csv>
# Walk <root_dir> and write the attribute CSV. Records files, symlinks, and
# directories (dirs for completeness/audit; their mtime is authoritatively
# restored in finalize, not from here).
attrs_record() {
    local root="$1" out="$2"
    printf 'Relative_Path,Type,Mode,Mtime_Epoch,Owner,Group,Symlink_Target\n' > "$out"
    local type mode mtime owner group rel link
    # CRITICAL (bash IFS-whitespace gotcha): `IFS=$'\t' read` COLLAPSES runs of
    # tabs (tab is IFS-whitespace) and trims leading/trailing tabs. So an EMPTY
    # field in the MIDDLE would silently shift every later field left. %l
    # (symlink target) is empty for every non-symlink, so it MUST be the LAST
    # -printf field — a trailing empty is simply trimmed, leaving rel intact.
    # (Putting %l mid-list skipped every regular file; caught by phased_copy_test.)
    local _ra=0
    while IFS=$'\t' read -r type mode mtime owner group rel link; do
        [ -z "$rel" ] && continue
        _ra=$((_ra + 1)); tick "$_ra" "recording attributes: $_ra"
        printf '%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote_field "$rel")" \
            "$(csv_quote_field "$type")" \
            "$(csv_quote_field "$mode")" \
            "$(csv_quote_field "${mtime%.*}")" \
            "$(csv_quote_field "$owner")" \
            "$(csv_quote_field "$group")" \
            "$(csv_quote_field "$link")" >> "$out"
    done < <(find "$root" -mindepth 1 -printf '%y\t%m\t%T@\t%u\t%g\t%P\t%l\n')
    progress_done
}

# attrs_restore <csv> <target_root>
# Restore mode + mtime (+ symlink mtime via -h) for FILES and SYMLINKS from the
# CSV. Directories are skipped here (finalize owns dir mtimes). Ownership is NOT
# restored. Quote-aware parse mirrors csv_read_3col's tokenizer (7 columns).
attrs_restore() {
    local csv="$1" target_root="$2"
    [ -f "$csv" ] || die "attrs CSV missing: $csv"
    local parsed; parsed="$(mktemp)"
    awk '
        NR == 1 { next }
        {
            line = $0; sub(/\r$/, "", line); n = length(line)
            field = ""; in_quote = 0; out = ""
            for (i = 1; i <= n; i++) {
                c = substr(line, i, 1)
                if (c == "\"") {
                    # RFC4180 doubled-quote inside a quoted field
                    if (in_quote && substr(line, i+1, 1) == "\"") { field = field "\""; i++; continue }
                    in_quote = 1 - in_quote; continue
                }
                if (c == "," && !in_quote) { out = out field "\t"; field = ""; continue }
                field = field c
            }
            print out field
        }
    ' "$csv" > "$parsed"

    local rel type mode mtime owner group link final restored=0
    local _rs=0
    while IFS=$'\t' read -r rel type mode mtime owner group link; do
        _rs=$((_rs + 1)); tick "$_rs" "restoring attributes: $_rs"
        rel="$(csv_strip_field "$rel")"
        type="$(csv_strip_field "$type")"
        mode="$(csv_strip_field "$mode")"
        mtime="$(csv_strip_field "$mtime")"
        link="$(csv_strip_field "$link")"
        [ -z "$rel" ] && continue
        [ "$type" = "d" ] && continue          # directories handled in finalize
        final="${target_root}/${rel}"
        if [ ! -e "$final" ] && [ ! -L "$final" ]; then
            warn "attrs_restore: target missing, skipping: $final"
            continue
        fi
        if [ "$type" = "l" ] || [ -L "$final" ]; then
            touch -h -d "@${mtime}" "$final" 2>/dev/null || warn "touch -h failed: $final"
        else
            chmod "$mode" "$final" 2>/dev/null || warn "chmod $mode failed: $final"
            touch -d "@${mtime}" "$final" 2>/dev/null || warn "touch failed: $final"
        fi
        restored=$((restored + 1))
    done < "$parsed"
    progress_done
    rm -f "$parsed"
    info "Restored attributes for $restored file(s)/symlink(s)."
    emit_event "$EVENTS_LOG" "event=attrs_restored" "count=$restored"
}

# =============================================================================
#                              MODE: PLAN
# =============================================================================

# exclude_args_for <src_name>
# Build find-prune-free exclusion: emit `-path '<root>/<pat>' -prune -o` chunks.
# We keep it simple — apply EXCLUDE_MAPPING patterns as `! -path` filters.
matches_exclude() {
    # matches_exclude <src_name> <rel_path> -> returns 0 if excluded
    local src_name="$1" rel="$2" rule rule_src rule_pat
    for rule in "${EXCLUDE_MAPPING[@]+"${EXCLUDE_MAPPING[@]}"}"; do
        IFS=':' read -r rule_src rule_pat <<< "$rule"
        [ "$rule_src" = "$src_name" ] || continue
        # shell glob match of the relative path against the pattern
        # shellcheck disable=SC2254
        case "$rel" in
            $rule_pat|$rule_pat/*) return 0 ;;
        esac
    done
    return 1
}

run_plan() {
    [ -n "$SOURCE_USER" ] || die "--mode plan requires --source-user"
    [ -n "$TARGET_USER" ] || die "--mode plan requires --target-user"
    [ -n "$SOURCE_BASE_DIR" ] || die "plan requires SOURCE_BASE_DIR (--config or --source-base)"
    [ -n "$TARGET_BASE_DIR" ] || die "plan requires TARGET_BASE_DIR (--config or --target-base)"
    [ -n "$STATE_DIR" ] || die "plan requires a state dir (set STAGING_DIR/STATE_DIR in --config or pass --state-dir)"
    [ -d "$SOURCE_BASE_DIR" ] || die "Source base dir does not exist: $SOURCE_BASE_DIR"
    assert_running_as "$SOURCE_USER" "plan"

    # (Re)create a clean state dir. Planning is idempotent: a fresh plan replaces
    # any previous one. (Markers from a prior run are intentionally cleared — a
    # re-plan is a deliberate restart of the batching.)
    if [ -d "$STATE_DIR" ] && [ -n "$(ls -A "$STATE_DIR" 2>/dev/null)" ]; then
        warn "State dir '$STATE_DIR' exists and is non-empty; re-planning replaces it."
        rm -rf "${STATE_DIR:?}/manifests" "${STATE_DIR:?}/markers" \
               "$(plan_file)" "$(dirs_file)" "$(batch_count_file)"
    fi
    safe_mkdir_p "$STATE_DIR"; apply_share_perms_dir "$STATE_DIR"
    safe_mkdir_p "${STATE_DIR}/manifests"; apply_share_perms_dir "${STATE_DIR}/manifests"
    safe_mkdir_p "${STATE_DIR}/markers"; apply_share_perms_dir "${STATE_DIR}/markers"
    check_tmpfs_warning "$STATE_DIR"

    init_logs plan
    info "Planning batches: budget=$(human_bytes "$STAGING_BUDGET_BYTES") per batch"
    info "  SOURCE_BASE_DIR=$SOURCE_BASE_DIR"
    info "  TARGET_BASE_DIR=$TARGET_BASE_DIR  (recorded for deploy)"

    : > "$(dirs_file)"
    printf 'Batch,Files,Bytes,Bytes_Human\n' > "$(plan_file)"

    local batch=1 batch_bytes=0 batch_files=0 total_bytes=0 total_files=0
    local oversize_warned=0
    local cur_manifest; cur_manifest="$(manifest_file "$batch")"
    : > "$cur_manifest"

    # close_batch: record the current batch's summary + PLANNED marker, advance.
    close_batch() {
        [ "$batch_files" -eq 0 ] && return 0
        printf '%s,%s,%s,%s\n' "$batch" "$batch_files" "$batch_bytes" "$(human_bytes "$batch_bytes")" >> "$(plan_file)"
        : > "$(marker_file "$batch" PLANNED)"
        info "  batch $batch: $batch_files ent(ies), $(human_bytes "$batch_bytes")"
        emit_event "$EVENTS_LOG" "event=batch_planned" "batch=$batch" "files=$batch_files" "bytes=$batch_bytes"
        batch=$((batch + 1)); batch_bytes=0; batch_files=0
        cur_manifest="$(manifest_file "$batch")"; : > "$cur_manifest"
    }

    # add_entry <kind> <src_name> <dest_name> <rel> <size>
    # Append one entry to the current batch, rolling to a new batch first if
    # adding it would exceed the budget. kind T = a tree entry (rel relative to
    # the item dir); kind F = the item is itself a single file/symlink.
    add_entry() {
        local kind="$1" src_name="$2" dest_name="$3" rel="$4" size="$5"
        if [ "$size" -gt "$STAGING_BUDGET_BYTES" ] && [ "$oversize_warned" -eq 0 ]; then
            warn "Entry exceeds per-batch budget on its own: $(human_bytes "$size") > $(human_bytes "$STAGING_BUDGET_BYTES")"
            warn "  -> $SOURCE_BASE_DIR/$src_name${rel:+/$rel}"
            warn "  It will get its own batch; staging it needs that much free /tmp."
            warn "  If it also exceeds the /tmp hard cap, copy THIS entry out of band."
            oversize_warned=1
        fi
        if [ "$batch_files" -gt 0 ] && [ "$((batch_bytes + size))" -gt "$STAGING_BUDGET_BYTES" ]; then
            close_batch
        fi
        # Manifest row: kind <TAB> src_name <TAB> dest_name <TAB> rel
        #   T: rel is relative to SOURCE_BASE/src_name -> STAGING/dest_name/rel
        #   F: the item itself is a file/symlink       -> STAGING/dest_name
        printf '%s\t%s\t%s\t%s\n' "$kind" "$src_name" "$dest_name" "$rel" >> "$cur_manifest"
        batch_bytes=$((batch_bytes + size)); batch_files=$((batch_files + 1))
        total_bytes=$((total_bytes + size)); total_files=$((total_files + 1))
    }

    local item src_name dest_name item_root
    for item in "${COPY_MAPPING[@]+"${COPY_MAPPING[@]}"}"; do
        IFS='|' read -r src_name dest_name <<< "$item"
        src_name="${src_name%/}"; dest_name="${dest_name%/}"
        item_root="${SOURCE_BASE_DIR}/${src_name}"
        if [ ! -e "$item_root" ] && [ ! -L "$item_root" ]; then
            warn "Source missing, skipping: $item_root"
            continue
        fi

        # A single file/symlink item (not a directory tree).
        if [ ! -d "$item_root" ] || [ -L "$item_root" ]; then
            local sz; sz="$(stat -c '%s' "$item_root" 2>/dev/null || echo 0)"
            [ -L "$item_root" ] && sz=0
            add_entry F "$src_name" "$dest_name" "" "$sz"
            continue
        fi

        # Directory tree: enumerate files, symlinks, empty dirs (rel to item_root).
        local rel size
        local _pe=0
        while IFS=$'\t' read -r size rel; do
            [ -z "$rel" ] && continue
            _pe=$((_pe + 1)); tick "$_pe" "planning '$src_name': $_pe items"
            matches_exclude "$src_name" "$rel" && continue
            add_entry T "$src_name" "$dest_name" "$rel" "$size"
        done < <(find "$item_root" -mindepth 1 \( -type f -printf '%s\t%P\n' \) -o \
                                   \( -type l -printf '0\t%P\n' \) -o \
                                   \( -type d -empty -printf '0\t%P\n' \) )
        progress_done

        # Record EVERY directory's mode+mtime for the finalize reconcile, mapped
        # to the dest layout (dest_name + path-below-item). Deepest-first.
        while IFS=$'\t' read -r mode mtime rel; do
            [ -z "$rel" ] && rel=""
            matches_exclude "$src_name" "$rel" && continue
            local dest_rel="$dest_name"
            [ -n "$rel" ] && dest_rel="$dest_name/$rel"
            printf '%s\t%s\t%s\n' "$mode" "${mtime%.*}" "$dest_rel" >> "$(dirs_file)"
        done < <(find "$item_root" -depth -type d -printf '%m\t%T@\t%P\n')
    done

    close_batch
    local n_batches=$((batch - 1))
    printf '%s\n' "$n_batches" > "$(batch_count_file)"

    success "PLAN complete: $n_batches batch(es), $total_files entr(ies), $(human_bytes "$total_bytes") total."
    emit_event "$EVENTS_LOG" "event=plan_complete" "batches=$n_batches" "files=$total_files" "bytes=$total_bytes"
    info ""
    info "Next: alternate these two logins until status shows all DEPLOYED:"
    info "  as $SOURCE_USER:  bash $0 --mode prepare --config <cfg> --source-user $SOURCE_USER --target-user $TARGET_USER"
    info "  as $TARGET_USER:  bash $0 --mode deploy  --config <cfg> --target-user $TARGET_USER"
    info "Then once:"
    info "  as $TARGET_USER:  bash $0 --mode finalize --config <cfg> --target-user $TARGET_USER"
}

# =============================================================================
#                       BATCH STATE (marker-file derived)
# =============================================================================

total_batches() {
    local f; f="$(batch_count_file)"
    [ -f "$f" ] || { echo 0; return 0; }
    cat "$f"
}

# batch_status <n> -> echoes DEPLOYED|STAGED|STAGE_FAILED|DEPLOY_FAILED|PLANNED|NONE
# Precedence reflects forward progress; *_FAILED markers are surfaced so a retry
# path is visible but do not mask a later success.
batch_status() {
    local n="$1"
    if   [ -f "$(marker_file "$n" DEPLOYED)" ]; then echo DEPLOYED
    elif [ -f "$(marker_file "$n" DEPLOY_FAILED)" ]; then echo DEPLOY_FAILED
    elif [ -f "$(marker_file "$n" STAGED)" ]; then echo STAGED
    elif [ -f "$(marker_file "$n" STAGE_FAILED)" ]; then echo STAGE_FAILED
    elif [ -f "$(marker_file "$n" PLANNED)" ]; then echo PLANNED
    else echo NONE
    fi
}

# staged_batch_awaiting_deploy -> echoes batch number with STAGED-but-not-DEPLOYED, or 0
staged_batch_awaiting_deploy() {
    local n total st; total="$(total_batches)"
    for (( n=1; n<=total; n++ )); do
        st="$(batch_status "$n")"
        if [ "$st" = "STAGED" ] || [ "$st" = "DEPLOY_FAILED" ]; then echo "$n"; return 0; fi
    done
    echo 0
}

# next_batch_to_stage -> echoes lowest batch not yet STAGED/DEPLOYED, or 0
next_batch_to_stage() {
    local n total st; total="$(total_batches)"
    for (( n=1; n<=total; n++ )); do
        st="$(batch_status "$n")"
        if [ "$st" = "PLANNED" ] || [ "$st" = "STAGE_FAILED" ]; then echo "$n"; return 0; fi
    done
    echo 0
}

# =============================================================================
#                              MODE: PREPARE  (stage one batch)
# =============================================================================

run_prepare() {
    [ -n "$SOURCE_USER" ] || die "--mode prepare requires --source-user"
    [ -n "$SOURCE_BASE_DIR" ] || die "prepare requires SOURCE_BASE_DIR"
    [ -n "$STAGING_DIR" ] || die "prepare requires --staging-dir (or STAGING_DIR in config)"
    [ -n "$STATE_DIR" ] || die "prepare requires a state dir"
    [ -d "$STATE_DIR" ] || die "No plan found at $STATE_DIR. Run --mode plan first."
    assert_running_as "$SOURCE_USER" "prepare"
    init_logs prepare

    local total; total="$(total_batches)"
    [ "$total" -gt 0 ] || die "Plan has 0 batches (run --mode plan)."

    # Single staging slot: refuse if a batch is already staged awaiting deploy.
    local awaiting; awaiting="$(staged_batch_awaiting_deploy)"
    if [ "$awaiting" -ne 0 ]; then
        info "Batch $awaiting is already STAGED awaiting deploy. Nothing to stage."
        info "  -> Run deploy as the TARGET user, then prepare again."
        return 0
    fi

    local n; n="$(next_batch_to_stage)"
    if [ "$n" -eq 0 ]; then
        success "All $total batch(es) already staged/deployed. Nothing to prepare."
        return 0
    fi

    local manifest; manifest="$(manifest_file "$n")"
    [ -f "$manifest" ] || die "Manifest missing for batch $n: $manifest"

    # Batch byte size from plan.csv (for the preflight + logs).
    local batch_bytes; batch_bytes="$(awk -F, -v b="$n" 'NR>1 && $1==b {print $3}' "$(plan_file)")"
    [ -n "$batch_bytes" ] || batch_bytes=0

    info "Preparing batch $n/$total ($(human_bytes "$batch_bytes"))..."
    emit_event "$EVENTS_LOG" "event=prepare_start" "batch=$n" "total=$total" "bytes=$batch_bytes"

    # Free-space preflight: fail BEFORE rsync if /tmp can't hold this batch.
    # +64 MiB headroom for fs overhead and the small per-batch CSV.
    check_free_space_bytes "$(dirname "$STAGING_DIR")" "$((batch_bytes + 67108864))"

    # Defensive clean: with the slot free per markers, staging must start empty.
    safe_mkdir_p "$STAGING_DIR"
    rm -rf "${STAGING_DIR:?}/"* 2>/dev/null || true
    find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -name '.*' -exec rm -rf {} + 2>/dev/null || true
    apply_share_perms_dir "$STAGING_DIR"

    # Stage the batch, grouped by (src_name,dest_name) so renames are honored and
    # we can use one `rsync --files-from` per item group (efficient + correct).
    local rc=0
    if ! stage_batch_groups "$n" "$manifest"; then rc=1; fi

    if [ "$rc" -ne 0 ]; then
        warn "Batch $n staging FAILED. Cleaning partial staging."
        rm -rf "${STAGING_DIR:?}/"* 2>/dev/null || true
        printf 'rsync failed (see %s)\n' "${LOG_FILE:-?}" > "$(marker_file "$n" STAGE_FAILED)"
        emit_event "$EVENTS_LOG" "event=prepare_failed" "batch=$n"
        die "Batch $n staging failed. Staging cleaned. Free /tmp or inspect logs, then re-run prepare (resumes this batch)."
    fi

    # Record ORIGINAL attributes (before widening) to the per-batch CSV.
    info "Recording attribute reference CSV for batch $n..."
    attrs_record "$STAGING_DIR" "$(attrs_csv "$n")"

    # Widen perms so the target user can read+traverse the staged batch.
    if [ -n "$SHARED_GROUP" ]; then
        find "$STAGING_DIR" -type d -exec chmod 2770 {} + 2>/dev/null || true
        find "$STAGING_DIR" -type f -exec chmod 660 {} + 2>/dev/null || true
        chgrp -R "$SHARED_GROUP" "$STAGING_DIR" 2>/dev/null || warn "chgrp -R $SHARED_GROUP failed on staging"
    else
        find "$STAGING_DIR" -type d -exec chmod 777 {} + 2>/dev/null || true
        find "$STAGING_DIR" -type f -exec chmod 666 {} + 2>/dev/null || true
    fi

    rm -f "$(marker_file "$n" STAGE_FAILED)" 2>/dev/null || true
    printf 'staged %s\n' "$(date +%s)" > "$(marker_file "$n" STAGED)"
    success "Batch $n STAGED. ($(human_bytes "$batch_bytes"))"
    emit_event "$EVENTS_LOG" "event=prepare_done" "batch=$n"
    info "  -> Next: run deploy as the TARGET user."
}

# stage_batch_groups <n> <manifest>
# Group the manifest's rows by (src_name,dest_name) and rsync each group's
# relative-path list from SOURCE_BASE/src_name into STAGING/dest_name.
stage_batch_groups() {
    local n="$1" manifest="$2"
    local cur_src="" cur_dest="" tmp_list=""
    local kind src dest rel rc=0

    flush_group() {
        [ -z "$cur_src" ] && return 0
        local src_root="${SOURCE_BASE_DIR}/${cur_src}"
        local dst_root="${STAGING_DIR}/${cur_dest}"
        safe_mkdir_p "$dst_root"
        info "  staging group: $cur_src -> $cur_dest ($(wc -l < "$tmp_list") entr(ies))"
        if ! run_rsync_live "stage $cur_dest" "batch$n" \
                --files-from="$tmp_list" "$src_root/" "$dst_root/"; then
            rc=1
        fi
        rm -f "$tmp_list"; tmp_list=""
        cur_src=""; cur_dest=""
        return 0
    }

    local _st=0
    while IFS=$'\t' read -r kind src dest rel; do
        [ -z "$kind" ] && continue
        _st=$((_st + 1)); tick "$_st" "staging batch entries: $_st"
        if [ "$kind" = "F" ]; then
            # Single file/symlink item: direct rsync WITH rename (--files-from
            # cannot rename). Close any open tree group first.
            flush_group
            local sroot="${SOURCE_BASE_DIR}/${src}"
            local droot="${STAGING_DIR}/${dest}"
            safe_mkdir_p "$(dirname "$droot")"
            info "  staging file: $src -> $dest"
            if ! run_rsync_live "stage $dest" "batch$n" "$sroot" "$droot"; then rc=1; fi
            continue
        fi
        # kind = T (tree entry; rel relative to the item dir)
        [ -z "$rel" ] && continue
        if [ "$src" != "$cur_src" ] || [ "$dest" != "$cur_dest" ]; then
            flush_group
            cur_src="$src"; cur_dest="$dest"; tmp_list="$(mktemp)"
        fi
        printf '%s\n' "$rel" >> "$tmp_list"
    done < "$manifest"
    progress_done
    flush_group
    return "$rc"
}

# =============================================================================
#                              MODE: DEPLOY  (deploy one staged batch)
# =============================================================================

run_deploy() {
    [ -n "$TARGET_USER" ] || die "--mode deploy requires --target-user"
    [ -n "$TARGET_BASE_DIR" ] || die "deploy requires TARGET_BASE_DIR"
    [ -n "$STAGING_DIR" ] || die "deploy requires --staging-dir (or STAGING_DIR in config)"
    [ -n "$STATE_DIR" ] || die "deploy requires a state dir"
    [ -d "$STATE_DIR" ] || die "No plan/state found at $STATE_DIR."
    assert_running_as "$TARGET_USER" "deploy"
    init_logs deploy

    local n; n="$(staged_batch_awaiting_deploy)"
    if [ "$n" -eq 0 ]; then
        local total; total="$(total_batches)"
        local left; left="$(next_batch_to_stage)"
        if [ "$left" -eq 0 ] && [ "$total" -gt 0 ]; then
            success "All $total batch(es) deployed. Next: run --mode finalize as the TARGET user."
        else
            info "Nothing staged to deploy. Run prepare as the SOURCE user first."
        fi
        return 0
    fi

    [ -d "$STAGING_DIR" ] || die "Staging dir missing but batch $n marked STAGED: $STAGING_DIR"
    info "Deploying batch $n -> $TARGET_BASE_DIR ..."
    emit_event "$EVENTS_LOG" "event=deploy_start" "batch=$n"

    safe_mkdir_p "$TARGET_BASE_DIR"
    # Staging mirrors the dest layout, so a single structure-preserving rsync
    # lands the batch correctly. -a keeps times/perms/links from staging; the
    # authoritative original attrs are re-applied next from the per-batch CSV.
    if ! run_rsync_live "deploy batch $n" "batch$n" "$STAGING_DIR/" "$TARGET_BASE_DIR/"; then
        printf 'rsync to target failed (see %s)\n' "${LOG_FILE:-?}" > "$(marker_file "$n" DEPLOY_FAILED)"
        emit_event "$EVENTS_LOG" "event=deploy_failed" "batch=$n"
        die "Batch $n deploy failed. Staging left intact for retry. Inspect logs, then re-run deploy."
    fi

    # Restore original mode+mtime (+symlink) from the reference CSV.
    info "Restoring attributes for batch $n from reference CSV..."
    attrs_restore "$(attrs_csv "$n")" "$TARGET_BASE_DIR"

    # DRAIN staging to free /tmp for the next batch (the "move" semantics).
    info "Draining staging for batch $n..."
    rm -rf "${STAGING_DIR:?}/"* 2>/dev/null || true
    find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -name '.*' -exec rm -rf {} + 2>/dev/null || true

    rm -f "$(marker_file "$n" DEPLOY_FAILED)" 2>/dev/null || true
    printf 'deployed %s\n' "$(date +%s)" > "$(marker_file "$n" DEPLOYED)"
    success "Batch $n DEPLOYED + drained."
    emit_event "$EVENTS_LOG" "event=deploy_done" "batch=$n"

    local left; left="$(next_batch_to_stage)"
    if [ "$left" -eq 0 ]; then
        info "  -> All batches deployed. Next: run --mode finalize as the TARGET user."
    else
        info "  -> Next: run prepare as the SOURCE user (batch $left)."
    fi
}

# =============================================================================
#                              MODE: FINALIZE
# =============================================================================

run_finalize() {
    [ -n "$TARGET_USER" ] || die "--mode finalize requires --target-user"
    [ -n "$TARGET_BASE_DIR" ] || die "finalize requires TARGET_BASE_DIR"
    [ -n "$STATE_DIR" ] || die "finalize requires a state dir"
    [ -d "$STATE_DIR" ] || die "No plan/state found at $STATE_DIR."
    assert_running_as "$TARGET_USER" "finalize"
    init_logs finalize

    # Guard: all planned batches must be deployed before finalize.
    local total n st undeployed=0; total="$(total_batches)"
    for (( n=1; n<=total; n++ )); do
        st="$(batch_status "$n")"
        [ "$st" = "DEPLOYED" ] || { warn "Batch $n is $st (not DEPLOYED)"; undeployed=$((undeployed + 1)); }
    done
    if [ "$undeployed" -gt 0 ]; then
        die "$undeployed batch(es) not yet DEPLOYED. Finish the prepare/deploy loop first (see --mode status)."
    fi

    # 1) Configured symlinks.
    local item src_link dest_link dest_target final
    if [ "${#SYMBOLIC_LINK_MAPPING[@]}" -gt 0 ]; then
        info "Creating configured symlinks..."
        for item in "${SYMBOLIC_LINK_MAPPING[@]}"; do
            IFS='|' read -r src_link dest_link dest_target <<< "$item"
            final="${TARGET_BASE_DIR}/${dest_link}"
            safe_mkdir_p "$(dirname "$final")"
            ln -sfn "$dest_target" "$final"
            info "  symlink: $final -> $dest_target"
        done
    fi

    # 2) Nested transforms (rename / retarget).
    local original_rel new_name new_target original_full new_full
    if [ "${#NESTED_ITEM_TRANSFORM[@]}" -gt 0 ]; then
        info "Applying nested transforms..."
        for item in "${NESTED_ITEM_TRANSFORM[@]}"; do
            IFS='|' read -r original_rel new_name new_target <<< "$item"
            original_full="${TARGET_BASE_DIR}/${original_rel}"
            new_full="$(dirname "$original_full")/${new_name}"
            if [ ! -e "$original_full" ] && [ ! -L "$original_full" ]; then
                warn "  transform target not found: $original_full"; continue
            fi
            if [ -z "$new_target" ]; then
                info "  rename: $original_full -> $new_full"
                mv "$original_full" "$new_full" || die "rename failed: $original_full"
            else
                info "  retarget symlink: $new_full -> $new_target"
                rm -f "$original_full"
                ln -s "$new_target" "$new_full" || die "symlink retarget failed: $new_full"
            fi
        done
    fi

    # 3) Directory mode+mtime reconcile (deepest-first, from the plan). This is
    #    the cross-batch fix: a dir written across multiple batches has a bumped
    #    mtime until set here, after all content + transforms are in place.
    local dirs; dirs="$(dirs_file)"
    if [ -f "$dirs" ]; then
        info "Reconciling directory mode+mtime (deepest-first)..."
        local mode mtime dest_rel target_dir count=0
        while IFS=$'\t' read -r mode mtime dest_rel; do
            [ -z "$dest_rel" ] && continue
            target_dir="${TARGET_BASE_DIR}/${dest_rel}"
            [ -d "$target_dir" ] || continue
            chmod "$mode" "$target_dir" 2>/dev/null || warn "chmod $mode failed: $target_dir"
            touch -d "@${mtime}" "$target_dir" 2>/dev/null || warn "touch failed: $target_dir"
            count=$((count + 1))
            if [ "$((count % 500))" -eq 0 ]; then info "  ...reconciled $count dirs"; fi
        done < "$dirs"
        info "Reconciled $count directories."
        emit_event "$EVENTS_LOG" "event=dirs_reconciled" "count=$count"
    else
        warn "No dirs.tsv found; skipping directory reconcile."
    fi

    success "FINALIZE complete. Target tree attributes reconciled."
    emit_event "$EVENTS_LOG" "event=finalize_done"
}

# =============================================================================
#                              MODE: STATUS
# =============================================================================

run_status() {
    [ -n "$STATE_DIR" ] || die "status requires a state dir (--state-dir or STAGING_DIR/STATE_DIR in config)"
    [ -d "$STATE_DIR" ] || die "No plan/state found at $STATE_DIR. Run --mode plan first."
    local total; total="$(total_batches)"
    local n st deployed=0 staged=0 planned=0 failed=0
    printf '\n  Batch status (%s)\n' "$STATE_DIR" >&2
    printf '  %-7s %-14s %s\n' "BATCH" "STATUS" "SIZE" >&2
    printf '  %-7s %-14s %s\n' "-----" "------" "----" >&2
    for (( n=1; n<=total; n++ )); do
        st="$(batch_status "$n")"
        local bytes; bytes="$(awk -F, -v b="$n" 'NR>1 && $1==b {print $3}' "$(plan_file)" 2>/dev/null)"
        printf '  %-7s %-14s %s\n' "$n" "$st" "$(human_bytes "${bytes:-0}")" >&2
        case "$st" in
            DEPLOYED) deployed=$((deployed + 1)) ;;
            STAGED)   staged=$((staged + 1)) ;;
            PLANNED)  planned=$((planned + 1)) ;;
            *FAILED)  failed=$((failed + 1)) ;;
        esac
    done
    printf '\n  total=%s deployed=%s staged=%s planned=%s failed=%s\n\n' \
        "$total" "$deployed" "$staged" "$planned" "$failed" >&2
    # Machine-readable one-liner (stdout, so it can be captured/piped).
    printf '{"total":%s,"deployed":%s,"staged":%s,"planned":%s,"failed":%s}\n' \
        "$total" "$deployed" "$staged" "$planned" "$failed"
}

# =============================================================================
#                              MODE: CLEANUP
# =============================================================================

run_cleanup() {
    [ -n "$STAGING_DIR" ] || die "--mode cleanup requires --staging-dir"
    if [ -d "$STAGING_DIR" ]; then
        local owner me; owner="$(stat -c '%U' "$STAGING_DIR")"; me="$(id -un)"
        if [ "$owner" != "$me" ] && [ "$FORCE_CLEANUP" -ne 1 ]; then
            die "Staging owned by '$owner', not '$me'. Pass --force to override."
        fi
        info "Removing staging dir: $STAGING_DIR"
        rm -rf "$STAGING_DIR"
    else
        info "Staging dir already gone: $STAGING_DIR"
    fi
    if [ "$CLEANUP_STATE" -eq 1 ] && [ -n "$STATE_DIR" ] && [ -d "$STATE_DIR" ]; then
        warn "Removing state/plan dir (batch history + manifests + logs): $STATE_DIR"
        rm -rf "$STATE_DIR"
    fi
    success "CLEANUP complete."
}

# =============================================================================
#                              MAIN
# =============================================================================

main() {
    parse_args "$@"
    case "$MODE" in
        plan)     run_plan ;;
        prepare)  run_prepare ;;
        deploy)   run_deploy ;;
        finalize) run_finalize ;;
        status)   run_status ;;
        cleanup)  run_cleanup ;;
        *) echo "Error: invalid --mode '$MODE'" >&2; usage ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
