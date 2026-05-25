#!/bin/bash
# =============================================================================
#
# Script:      migrator.sh
#
# Description:
#   Stateful, in-place path/content migrator with backup, resume, rollback,
#   and cleanup. Designed for DR work where messing up the target tree
#   would cause tremendous delays — see the safety gates throughout.
#
#   Modes:
#     execute   - apply forward migration to paths listed in --csv
#     rollback  - restore every backed-up path to its pre-migration state
#     cleanup   - delete all backups and tracking state for the workdir
#     validate  - check that the migration is internally consistent
#                 (every COMPLETED row's live state differs from its backup
#                  if and only if the row's path/content should have changed,
#                  and mtime matches what was recorded at execute time)
#
#   Safety gates (live mode):
#     - --root REQUIRED; every CSV path asserted to be under --root
#     - --yes REQUIRED unless --root starts with /tmp/
#     - 5-second countdown after the live-mode summary, abortable with Ctrl-C
#     - --backup-dir refuses to be the same as --root or under --root
#
#   Resume semantics:
#     - Tracking file at <workdir>/progress.log is canonical.
#     - On startup, every BACKED_UP-but-not-COMPLETED row triggers a
#       restore-from-backup followed by re-execution. Backup is the
#       source of truth; the live path may be in any intermediate state.
#     - Re-running migrator with the same --workdir resumes; to start
#       over, run --mode cleanup first.
#
#   Backup discipline:
#     - cp -a everywhere (preserves lstat, no symlink deref).
#     - Backup tree mirrors the original tree shape under <workdir>/backups/
#       so collisions are impossible regardless of basename overlap.
#     - mtime is restored AFTER every mutation via touch -h -d.
#
# Bash version floor: 4.2 (per common.sh).
#
# =============================================================================

# --- Script Safety and Rigor -------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_bash_version 4 2
set -euo pipefail

# =============================================================================
#                                 CONFIGURATION
# =============================================================================
#
# Forward mapping ONLY. The reverse mapping is derived at runtime via
# derive_reverse_map() — change keys here, the reverse stays in sync.
#
# Both path and content rewrites use the same map. If a future job needs
# separate maps for paths vs contents, split this into two declarations.

declare -Ar MIGRATION_MAP=(
    ["FAT1"]="FAT2"
    ["fat1"]="fat2"
    ["opc_d1"]="opc_d2"
    ["xbapp_d1"]="xbapp_d2"
    ["opcsvcf1"]="opcsvcf2"
)

# Derived at runtime. Kept as a regular declare (not readonly) because
# derive_reverse_map populates it post-declaration.
declare -A REVERSE_MIGRATION_MAP=()
derive_reverse_map MIGRATION_MAP REVERSE_MIGRATION_MAP

# =============================================================================
#                                 GLOBAL STATE
# =============================================================================
#
# Set by main() after CLI parsing. Sub-functions read these globals rather
# than receive long argument lists.

MODE=""
CSV_FILE=""
ROOT=""
WORKDIR=""
BACKUP_DIR=""
TRACKING_FILE=""
LOG_FILE_PATH=""        # exported as LOG_FILE for common.sh log()
DRY_RUN=0
ASSUME_YES=0

# =============================================================================
#                                  USAGE
# =============================================================================

usage() {
    cat >&2 <<EOF
Usage: $0 --mode <execute|rollback|cleanup|validate> --root <path> [options]

REQUIRED for execute:
  --mode execute
  --root  PATH    The fat2 base (e.g. /applications/opc_d2). Every CSV path
                  must be under this directory or migrator refuses.
  --csv   PATH    3-column CSV: Name,Absolute_Path,Last_Modified

REQUIRED for rollback/cleanup/validate:
  --mode <rollback|cleanup|validate>
  --root  PATH    Same as the prior execute (used to refuse cross-root operations)

OPTIONAL:
  --workdir      PATH   Default: /tmp/migration_f2
                        Holds backups, tracking, and run logs. A re-run with
                        the same --workdir RESUMES from the tracking file.
  --backup-dir   PATH   Default: <workdir>/backups
                        Refuses to be under --root.
  --tracking-file PATH  Default: <workdir>/progress.log
  --log-file     PATH   Default: <workdir>/migrator_<run-id>.log
  --dry-run             Print what would happen; touch no disk state.
  --yes                 Skip the live-mode confirmation countdown.
                        Required for non-/tmp roots. Test harnesses should
                        set NONINTERACTIVE=1 instead.

EXAMPLES:
  # Mock run (safe, scratch tree under /tmp)
  $0 --mode execute --root /tmp/mock_f2 --csv /tmp/mock_f2/mock_input.csv

  # Live run (requires --yes + countdown)
  $0 --mode execute --root /applications/opc_d2 --csv ./fat2.csv --yes

  # Resume a killed run (just re-invoke; tracking file in --workdir)
  $0 --mode execute --root /applications/opc_d2 --csv ./fat2.csv --yes

  # Roll everything back
  $0 --mode rollback --root /applications/opc_d2

  # Delete backups + tracking after validation passes
  $0 --mode cleanup --root /applications/opc_d2
EOF
    exit 1
}

# =============================================================================
#                            BACKUP PATH MAPPING
# =============================================================================
#
# Backup tree mirrors the original tree shape so collisions are impossible.
# Example:  /applications/opc_d2/conf/x.xml
#       ->  <backup_dir>/applications/opc_d2/conf/x.xml
#
# This means rollback can use the same structural mapping to find each
# row's backup without consulting the tracking file beyond row-existence.

backup_path_for() {
    local original="$1"
    printf '%s%s' "$BACKUP_DIR" "$original"
}

# =============================================================================
#                            TRACKING FILE FORMAT
# =============================================================================
#
# Append-only CSV. Columns:
#   Original_Path,New_Path,Backup_Path,Original_Timestamp,Status
#
# Status is one of: BACKED_UP, COMPLETED, ROLLED_BACK.
#
# The latest status for a given Original_Path wins. We never rewrite the
# file in place (avoids the O(n²) cost of the previous design).

tracking_header() {
    echo "Original_Path,New_Path,Backup_Path,Original_Timestamp,Status"
}

tracking_append() {
    local orig="$1" newp="$2" bkp="$3" ts="$4" status="$5"
    printf '"%s","%s","%s","%s","%s"\n' \
        "$orig" "$newp" "$bkp" "$ts" "$status" >> "$TRACKING_FILE"
}

# tracking_latest_status_for <path>
# Echoes the latest status for <path>, or empty string if never recorded.
tracking_latest_status_for() {
    local target="$1"
    [ -f "$TRACKING_FILE" ] || { echo ""; return; }
    # Reverse-walk to find the most recent entry first. tac is widely
    # available on Linux; we don't need the macOS shim here.
    local status
    status=$(tac "$TRACKING_FILE" 2>/dev/null \
        | awk -F'","' -v target="\"$target" '
            $1 == target { gsub(/"$/, "", $5); print $5; exit }
        ') || true
    echo "$status"
}

# tracking_field_for <path> <field_number>
# Returns field N (1-based) from the latest tracking entry for <path>.
# Fields: 1=Original_Path 2=New_Path 3=Backup_Path 4=Timestamp 5=Status
tracking_field_for() {
    local target="$1"
    local fieldnum="$2"
    [ -f "$TRACKING_FILE" ] || { echo ""; return; }
    local val
    val=$(tac "$TRACKING_FILE" 2>/dev/null \
        | awk -F'","' -v target="\"$target" -v fn="$fieldnum" '
            $1 == target { gsub(/(^"|"$)/, "", $fn); print $fn; exit }
        ') || true
    echo "$val"
}

# =============================================================================
#                              ARGUMENT PARSING
# =============================================================================

parse_args() {
    if [ "$#" -eq 0 ]; then usage; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)          MODE="$2"; shift 2 ;;
            --csv)           CSV_FILE="$2"; shift 2 ;;
            --root)          ROOT="$2"; shift 2 ;;
            --workdir)       WORKDIR="$2"; shift 2 ;;
            --backup-dir)    BACKUP_DIR="$2"; shift 2 ;;
            --tracking-file) TRACKING_FILE="$2"; shift 2 ;;
            --log-file)      LOG_FILE_PATH="$2"; shift 2 ;;
            --dry-run)       DRY_RUN=1; shift ;;
            --yes)           ASSUME_YES=1; shift ;;
            -h|--help)       usage ;;
            *) echo "Error: Unknown argument '$1'" >&2; usage ;;
        esac
    done

    [ -n "$MODE" ] || { echo "Error: --mode is required" >&2; usage; }
    [ -n "$ROOT" ] || { echo "Error: --root is required" >&2; usage; }

    case "$MODE" in
        execute|rollback|cleanup|validate) ;;
        *) echo "Error: invalid --mode '$MODE'" >&2; usage ;;
    esac

    if [ "$MODE" = "execute" ] && [ -z "$CSV_FILE" ]; then
        echo "Error: --csv is required for --mode execute" >&2
        usage
    fi

    # Defaults — derived only after --workdir is known.
    WORKDIR="${WORKDIR:-/tmp/migration_f2}"
    BACKUP_DIR="${BACKUP_DIR:-${WORKDIR}/backups}"
    TRACKING_FILE="${TRACKING_FILE:-${WORKDIR}/progress.log}"
    LOG_FILE_PATH="${LOG_FILE_PATH:-${WORKDIR}/migrator_$(new_run_id).log}"

    # Normalize for assert_under_root and equality checks.
    ROOT="$(normalize_path "$ROOT")"
    BACKUP_DIR="$(normalize_path "$BACKUP_DIR")"

    # Backup dir MUST NOT be the same as --root or live under it. If it were,
    # a rollback would restore from a tree we're actively rewriting.
    if [ "$BACKUP_DIR" = "$ROOT" ] || [[ "$BACKUP_DIR" == "$ROOT"/* ]]; then
        echo "Error: --backup-dir ('$BACKUP_DIR') cannot be under --root ('$ROOT')" >&2
        exit 2
    fi
}

# =============================================================================
#                                LIVE-MODE GATE
# =============================================================================

is_live_root() {
    # /tmp/* roots are considered "mock" — no countdown, no --yes required.
    [[ "$ROOT" != /tmp/* ]] && [ "$ROOT" != "/tmp" ]
}

live_safety_gate() {
    if ! is_live_root; then
        info "Root '$ROOT' is under /tmp; treating as mock run (no countdown)"
        return 0
    fi

    if [ "$ASSUME_YES" -ne 1 ]; then
        die "Live root '$ROOT' requires --yes to confirm intent" 2
    fi

    local n_rows=0
    if [ -f "$CSV_FILE" ]; then
        n_rows=$(( $(wc -l < "$CSV_FILE") - 1 ))
    fi

    local msg="LIVE migration on '$ROOT' — about to mutate up to $n_rows paths. Backups: $BACKUP_DIR"
    confirm_with_countdown "$msg"
}

# =============================================================================
#                              EXECUTE  (forward)
# =============================================================================

# process_row <name> <orig_path> <ts>
# Migrate one CSV row to its fat2 form. Idempotent: safe to retry.
# All mutations gated by DRY_RUN.
process_row() {
    local name="$1"
    local orig_path="$2"
    local ts="$3"

    # Safety: refuse anything outside --root.
    assert_under_root "$orig_path" "$ROOT"

    # New path is the forward-mapped form of original.
    local new_path
    new_path="$(apply_path_mapping "$orig_path" MIGRATION_MAP)"

    # Resume decision based on tracking history for this row.
    local prior_status
    prior_status="$(tracking_latest_status_for "$orig_path")"

    case "$prior_status" in
        COMPLETED)
            info "SKIP (already completed): $orig_path"
            return 0
            ;;
        BACKED_UP)
            # Partial state from a prior killed run. Look up stored backup
            # path from tracking — for redirected rows, the backup is of
            # new_path, not orig_path.
            if [ "$DRY_RUN" -eq 1 ]; then
                info "DRY-RUN: row in BACKED_UP state; would restore from backup before redoing: $orig_path"
                return 0
            fi
            local stored_bkp stored_newp
            stored_bkp=$(tracking_field_for "$orig_path" 3)
            stored_newp=$(tracking_field_for "$orig_path" 2)
            local resume_target="$orig_path"
            if [ -n "$stored_newp" ] && [ -n "$stored_bkp" ] && \
               [ "$(backup_path_for "$stored_newp")" = "$stored_bkp" ] && \
               [ "$stored_newp" != "$orig_path" ]; then
                resume_target="$stored_newp"
            fi
            warn "RESUME: previous run left $orig_path in BACKED_UP state. Restoring from backup before redoing."
            restore_from_backup "$orig_path" "${stored_bkp:-}" "$resume_target"
            ;;
        ROLLED_BACK|"")
            : # fresh row, nothing to do
            ;;
        *)
            warn "Unknown prior status '$prior_status' for $orig_path; proceeding cautiously"
            ;;
    esac

    # --- Determine the effective source to process ---
    #
    # If orig != new, the path would normally be renamed. But if the target
    # (new_path) already exists on disk, we process IT directly:
    #   - Content rewrite on new_path (it may still contain fat1 references)
    #   - No rename (target already has the correct name)
    #   - Backup is of new_path (the file we're actually modifying)
    #
    # This handles the real-world case where both fat1_*.ini and fat2_*.ini
    # coexist in the same directory. The fat2 file is already "in place" but
    # its content may still need rewriting.
    #
    # Three sub-cases when orig_path != new_path:
    #   A) Only orig exists          -> backup orig, rewrite, rename (normal)
    #   B) new_path exists (±orig)   -> backup new_path, rewrite it, no rename
    #   C) Neither exists            -> skip

    local effective_src="$orig_path"
    local effective_dst="$new_path"

    if [ "$orig_path" != "$new_path" ] && \
       { [ -e "$new_path" ] || [ -L "$new_path" ]; }; then
        # Case B: target already on disk. Redirect to process it directly.
        info "TARGET EXISTS: $new_path already present; processing it directly (content rewrite only)"
        effective_src="$new_path"
        effective_dst="$new_path"
    fi

    # Effective source must exist.
    if [ ! -e "$effective_src" ] && [ ! -L "$effective_src" ]; then
        warn "SKIP: source path not found: $effective_src"
        return 0
    fi

    local bkp
    bkp="$(backup_path_for "$effective_src")"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY-RUN: would back up $effective_src -> $bkp"
        info "DRY-RUN: would migrate -> $effective_dst"
        return 0
    fi

    # --- Backup ---
    # Guard: if the backup already exists, preserve it. This happens when
    # two CSV rows converge on the same effective file (e.g. fat1_mq_jks
    # redirected to fat2_mq_jks, and fat2_mq_jks also has its own row).
    # The FIRST backup captures the original state; overwriting it with a
    # second cp -a after content has already been rewritten would lose the
    # original.
    safe_mkdir_p "$(dirname "$bkp")"
    if [ -e "$bkp" ] || [ -L "$bkp" ]; then
        info "BACKUP EXISTS (preserving original): $bkp"
    else
        if ! cp -a "$effective_src" "$bkp"; then
            die "BACKUP failed for '$effective_src' -> '$bkp'. Halting before any mutation."
        fi
    fi
    tracking_append "$orig_path" "$effective_dst" "$bkp" "$ts" "BACKED_UP"

    # --- Mutate (symlink / dir / file) ---
    if [ -L "$effective_src" ]; then
        migrate_symlink "$effective_src" "$effective_dst"
    elif [ -d "$effective_src" ]; then
        migrate_directory "$effective_src" "$effective_dst"
    elif [ -f "$effective_src" ]; then
        migrate_file "$effective_src" "$effective_dst"
    else
        warn "Unrecognized lstat type for $effective_src; skipping mutation"
    fi

    # --- Restore mtime ---
    # The mutation steps may have bumped mtime; restore from the timestamp
    # captured at finder/mock-build time. Use -h so symlinks aren't
    # dereferenced.
    if ! restore_mtime_from_human "$effective_dst" "$ts" 2>/dev/null; then
        warn "Timestamp restore failed for: $effective_dst"
    fi

    tracking_append "$orig_path" "$effective_dst" "$bkp" "$ts" "COMPLETED"
    success "COMPLETED: $orig_path"
}

migrate_symlink() {
    local orig_path="$1"
    local new_path="$2"

    local old_target new_target
    old_target=$(readlink "$orig_path")
    new_target="$(apply_path_mapping "$old_target" MIGRATION_MAP)"

    rm "$orig_path"
    ln -s "$new_target" "$orig_path"

    if [ "$orig_path" != "$new_path" ]; then
        mv "$orig_path" "$new_path"
    fi
}

migrate_directory() {
    local orig_path="$1"
    local new_path="$2"

    if [ "$orig_path" != "$new_path" ]; then
        mv "$orig_path" "$new_path"
    fi
    # Rewrite contents of every regular file inside, depth-first. Each
    # rewrite bumps the child's mtime via replace_content_in_file's
    # truncate-rewrite — we capture the child mtime first and restore
    # it after. Without this, children inside a renamed directory would
    # drift away from their fat1 originals.
    local file_in_dir child_mtime
    while IFS= read -r -d '' file_in_dir; do
        child_mtime=$(lstat_mtime_human "$file_in_dir")
        if ! replace_content_in_file "$file_in_dir" MIGRATION_MAP; then
            warn "Content replace failed inside directory: $file_in_dir"
            continue
        fi
        if ! restore_mtime_from_human "$file_in_dir" "$child_mtime" 2>/dev/null; then
            warn "Child mtime restore failed: $file_in_dir"
        fi
    done < <(find "$new_path" -type f -print0)
}

migrate_file() {
    local orig_path="$1"
    local new_path="$2"

    if ! replace_content_in_file "$orig_path" MIGRATION_MAP; then
        warn "Content replace failed: $orig_path"
    fi
    if [ "$orig_path" != "$new_path" ]; then
        mv "$orig_path" "$new_path"
    fi
}

run_execute() {
    info "Mode: EXECUTE  root=$ROOT  workdir=$WORKDIR  dry_run=$DRY_RUN"
    safe_mkdir_p "$WORKDIR"
    safe_mkdir_p "$BACKUP_DIR"
    check_tmpfs_warning "$BACKUP_DIR"

    # Tracking file: create with header if absent.
    if [ ! -f "$TRACKING_FILE" ]; then
        tracking_header > "$TRACKING_FILE"
    fi

    [ -f "$CSV_FILE" ] || die "CSV not found: $CSV_FILE"

    live_safety_gate

    # Reading CSV with a callback that mutates global state (process_row's
    # tracking appends, dry-run flags, etc.) — csv_read_3col is designed
    # to run the callback in this shell.
    csv_read_3col "$CSV_FILE" process_row

    success "EXECUTE finished. See tracking file: $TRACKING_FILE"
}

# =============================================================================
#                                ROLLBACK
# =============================================================================
#
# Walks the tracking file in reverse. For every COMPLETED row, restore the
# original path from its backup. For BACKED_UP-but-not-COMPLETED rows, also
# restore (no harm done). For ROLLED_BACK rows, skip (already done).

# restore_from_backup <orig_path> [backup_path] [restore_target]
#   orig_path      — the CSV-listed path (used to compute new_path for cleanup)
#   backup_path    — where the backup lives; defaults to backup_path_for(orig_path)
#   restore_target — where to restore TO; defaults to orig_path
#
# When a row was redirected (target already existed), the backup is of the
# target, not the CSV path. The optional arguments let rollback pass the
# correct locations from tracking rather than recomputing.
restore_from_backup() {
    local orig_path="$1"
    local bkp="${2:-$(backup_path_for "$orig_path")}"
    local restore_to="${3:-$orig_path}"

    if [ ! -e "$bkp" ] && [ ! -L "$bkp" ]; then
        warn "Backup missing for $orig_path (expected at $bkp); cannot restore"
        return 1
    fi

    # If the new (post-migration) path exists, remove it first. We don't
    # know whether the original path or the new path is currently live, so
    # remove both possibilities.
    local new_path
    new_path="$(apply_path_mapping "$orig_path" MIGRATION_MAP)"
    if [ "$new_path" != "$orig_path" ] && { [ -e "$new_path" ] || [ -L "$new_path" ]; }; then
        rm -rf "$new_path"
    fi
    if [ "$restore_to" != "$new_path" ] && { [ -e "$restore_to" ] || [ -L "$restore_to" ]; }; then
        rm -rf "$restore_to"
    fi
    if [ "$orig_path" != "$new_path" ] && [ "$orig_path" != "$restore_to" ] && \
       { [ -e "$orig_path" ] || [ -L "$orig_path" ]; }; then
        rm -rf "$orig_path"
    fi

    safe_mkdir_p "$(dirname "$restore_to")"
    if ! cp -a "$bkp" "$restore_to"; then
        warn "cp -a failed restoring $restore_to from $bkp"
        return 1
    fi
    return 0
}

run_rollback() {
    info "Mode: ROLLBACK  root=$ROOT  workdir=$WORKDIR"
    [ -f "$TRACKING_FILE" ] || die "Tracking file not found: $TRACKING_FILE"

    live_safety_gate

    # Collect the latest state per original path from tracking. We store
    # backup_path and new_path from tracking rather than recomputing them,
    # because redirected rows (target-already-existed) backed up the target
    # instead of the CSV path.
    declare -A latest_status
    declare -A ts_for_path
    declare -A bkp_for_path
    declare -A newp_for_path
    local orig newp bkp ts status

    local tmp_log
    tmp_log=$(mktemp)
    tail -n +2 "$TRACKING_FILE" > "$tmp_log"

    # Read forward; later entries overwrite earlier. After the loop,
    # latest_status[path] holds the most recent status.
    while IFS=, read -r orig newp bkp ts status; do
        orig=$(csv_strip_field "$orig")
        newp=$(csv_strip_field "$newp")
        bkp=$(csv_strip_field "$bkp")
        ts=$(csv_strip_field "$ts")
        status=$(csv_strip_field "$status")
        latest_status["$orig"]="$status"
        ts_for_path["$orig"]="$ts"
        bkp_for_path["$orig"]="$bkp"
        newp_for_path["$orig"]="$newp"
    done < "$tmp_log"
    rm -f "$tmp_log"

    # Apply rollback in reverse insertion order. We need the order, so do
    # a second pass walking the tracking file in reverse and skipping paths
    # we've already handled.
    declare -A done_rollback
    local path
    local count=0
    while IFS=, read -r orig _ _ _ _; do
        orig=$(csv_strip_field "$orig")
        [ -z "$orig" ] && continue
        [ -n "${done_rollback[$orig]:-}" ] && continue
        done_rollback["$orig"]=1

        local cur_status="${latest_status[$orig]:-}"
        local row_bkp="${bkp_for_path[$orig]:-}"
        local row_newp="${newp_for_path[$orig]:-}"
        # Determine where to restore. For redirected rows (target existed),
        # the backup is of new_path and restore target is new_path (not orig).
        local restore_to="$orig"
        if [ -n "$row_newp" ] && [ "$row_newp" = "$row_bkp" ] || \
           [ "$(backup_path_for "$row_newp")" = "$row_bkp" ]; then
            # Backup was of new_path (redirected row) — restore to new_path.
            restore_to="$row_newp"
        fi

        case "$cur_status" in
            ROLLED_BACK)
                info "SKIP (already rolled back): $orig"
                continue
                ;;
            COMPLETED|BACKED_UP)
                if [ "$DRY_RUN" -eq 1 ]; then
                    info "DRY-RUN: would restore $orig from backup"
                    continue
                fi
                if restore_from_backup "$orig" "$row_bkp" "$restore_to"; then
                    # Restore mtime on the now-restored path
                    if ! restore_mtime_from_human "$restore_to" "${ts_for_path[$orig]}" 2>/dev/null; then
                        warn "Timestamp restore failed for: $restore_to"
                    fi
                    tracking_append "$orig" "$restore_to" "$row_bkp" \
                        "${ts_for_path[$orig]}" "ROLLED_BACK"
                    success "ROLLED_BACK: $orig"
                    count=$((count + 1))
                else
                    warn "ROLLBACK failed for: $orig"
                fi
                ;;
            *)
                warn "Unknown status '$cur_status' for $orig; skipping rollback"
                ;;
        esac
    done < <(tac "$TRACKING_FILE" | grep -v '^Original_Path,')

    success "ROLLBACK finished. Restored $count paths."
}

# =============================================================================
#                                CLEANUP
# =============================================================================
#
# Removes backup directory and tracking file. Operator-on-demand only.

run_cleanup() {
    info "Mode: CLEANUP  root=$ROOT  workdir=$WORKDIR"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY-RUN: would remove backup dir: $BACKUP_DIR"
        info "DRY-RUN: would remove tracking file: $TRACKING_FILE"
        return 0
    fi

    if [ -d "$BACKUP_DIR" ]; then
        info "Removing backup directory: $BACKUP_DIR"
        rm -rf "$BACKUP_DIR"
    else
        info "No backup directory to remove (already gone or never created)"
    fi
    if [ -f "$TRACKING_FILE" ]; then
        info "Removing tracking file: $TRACKING_FILE"
        rm -f "$TRACKING_FILE"
    fi
    success "CLEANUP finished."
}

# =============================================================================
#                                VALIDATE
# =============================================================================
#
# Internal-consistency check. For every COMPLETED row:
#   - The new_path exists (or is a symlink).
#   - The backup at backup_path_for(orig) exists.
#   - For files: backup vs new content differs IFF the file had content to
#     rewrite (otherwise they're equal).
#   - The new_path's mtime equals the recorded timestamp.
#
# Does NOT cross-check against fat1 — that's a separate validator.

run_validate() {
    info "Mode: VALIDATE  root=$ROOT  workdir=$WORKDIR"
    [ -f "$TRACKING_FILE" ] || die "Tracking file not found: $TRACKING_FILE"

    local pass=0
    local fail=0

    declare -A latest_status
    declare -A new_for
    declare -A ts_for
    local orig newp bkp ts status

    local tmp_log
    tmp_log=$(mktemp)
    tail -n +2 "$TRACKING_FILE" > "$tmp_log"
    while IFS=, read -r orig newp bkp ts status; do
        orig=$(csv_strip_field "$orig")
        newp=$(csv_strip_field "$newp")
        ts=$(csv_strip_field "$ts")
        status=$(csv_strip_field "$status")
        latest_status["$orig"]="$status"
        new_for["$orig"]="$newp"
        ts_for["$orig"]="$ts"
    done < "$tmp_log"
    rm -f "$tmp_log"

    local path
    for path in "${!latest_status[@]}"; do
        local s="${latest_status[$path]}"
        [ "$s" = "COMPLETED" ] || continue

        local np="${new_for[$path]}"
        local bp; bp="$(backup_path_for "$path")"
        local expected_ts="${ts_for[$path]}"

        # 1. New path exists
        if [ ! -e "$np" ] && [ ! -L "$np" ]; then
            warn "VALIDATE FAIL: missing migrated path: $np"
            fail=$((fail + 1))
            continue
        fi

        # 2. Backup exists
        if [ ! -e "$bp" ] && [ ! -L "$bp" ]; then
            warn "VALIDATE FAIL: missing backup: $bp"
            fail=$((fail + 1))
            continue
        fi

        # 3. mtime matches recorded ts
        local actual_epoch expected_epoch
        actual_epoch=$(lstat_mtime_epoch "$np")
        expected_epoch=$(date -d "$expected_ts" +%s 2>/dev/null) || expected_epoch=""
        if [ -n "$expected_epoch" ] && [ "$actual_epoch" != "$expected_epoch" ]; then
            warn "VALIDATE FAIL: mtime mismatch for $np (have $actual_epoch, expected $expected_epoch)"
            fail=$((fail + 1))
            continue
        fi

        pass=$((pass + 1))
    done

    info "VALIDATE summary: pass=$pass  fail=$fail"
    [ "$fail" -eq 0 ] || exit 1
}

# =============================================================================
#                                MAIN
# =============================================================================

main() {
    parse_args "$@"

    safe_mkdir_p "$WORKDIR"
    export LOG_FILE="$LOG_FILE_PATH"
    : > "$LOG_FILE"   # truncate per-run log

    info "migrator.sh starting"
    info "  mode=$MODE  root=$ROOT  workdir=$WORKDIR"
    info "  backup_dir=$BACKUP_DIR  tracking=$TRACKING_FILE"

    case "$MODE" in
        execute)  run_execute  ;;
        rollback) run_rollback ;;
        cleanup)  run_cleanup  ;;
        validate) run_validate ;;
    esac
}

# Only run main when executed; allow other scripts to source this for
# access to MIGRATION_MAP, derive_reverse_map result, and helpers like
# backup_path_for() in test harnesses.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
