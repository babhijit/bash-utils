#!/bin/bash
# =============================================================================
#
# Script:      selective_copy.sh
#
# Description:
#   Two-stage selective copy designed for environments where:
#     - Source and target accounts are different Unix users on the same host.
#     - Source has read access to its own tree; target has write access to
#       its own tree.
#     - Neither user has sudo, so cross-account writes must go through a
#       world-writable staging area (typically /tmp).
#     - By design, source-user must NOT be able to modify target-user's tree
#       and vice versa — accidents would be expensive to recover from.
#
#   MODE 1: --mode prepare
#     - Run as the SOURCE user.
#     - Copies COPY_MAPPING items + SYMBOLIC_LINK_MAPPING items + their
#       lstat metadata into the staging directory.
#     - Records perms+mtime+path into a tab-separated state file inside
#       staging. (Tab-separated, not space-separated, so paths containing
#       spaces parse correctly at deploy time.)
#
#   MODE 2: --mode deploy
#     - Run as the TARGET user.
#     - Reads staging + state file, copies into target tree, applies
#       NESTED_ITEM_TRANSFORM renames/retargets, restores lstat from
#       the state file.
#
#   MODE 3: --mode cleanup
#     - Removes the staging directory. Safe to run as either user provided
#       they own the staging dir (mktemp -d creates it owned by the prepare
#       user; deploy reads it; cleanup should be run by the prepare user
#       OR by anyone if --force is given).
#
# Threat model (no-sudo environment):
#   - Staging dir lives in world-writable /tmp because that's the only
#     place both users can write. Mode 777 on the staging tree is the
#     COST OF NO SUDO. Mitigations:
#       1. mktemp -d generates a non-predictable path; printed at the end
#          of prepare and required by deploy.
#       2. Optional --shared-group flag tightens to 770 if such a group
#          exists; operator must have set this up out of band.
#       3. State file integrity: deploy refuses if the state file's mtime
#          is older than any non-state file inside staging (indicates
#          tampering after state was written).
#   - User identity checks: --source-user/--target-user pin the expected
#     `id -un` for each stage. Catches `sudo -u wrong_user bash deploy`
#     mistakes early.
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
# NOTHING job-specific is hardcoded here. Everything below is supplied at
# runtime via:
#   --config <file>   a sourced bash snippet (see selective_copy.conf.example)
#   --source-base / --target-base / --staging-dir   CLI overrides (win over config)
#
# Defaults are empty so `set -u` array expansions stay safe; the required
# values are asserted per-mode (run_prepare / run_deploy) with clear messages.
#
# Config file contract (all optional except the base dir the mode needs):
#   SOURCE_BASE_DIR="/applications/opc_d1"
#   TARGET_BASE_DIR="/applications/opc_d2"
#   STAGING_DIR="/tmp/test_f2/migration"            # optional; else a mktemp dir
#   COPY_MAPPING=( "src_name|dest_name" ... )
#   SYMBOLIC_LINK_MAPPING=( "src_link|dest_link|dest_target" ... )
#   EXCLUDE_MAPPING=( "src_name:relative_pattern" ... )
#   NESTED_ITEM_TRANSFORM=( "rel_path|new_name|new_link_target" ... )
#
# Security: --config is sourced as bash. Use only operator-authored configs
# (same trust level as the script itself).

SOURCE_BASE_DIR=""
TARGET_BASE_DIR=""

# Populated by --config. Declared empty (not readonly) so the config may set
# them; locked readonly in parse_args once config + CLI have been applied.
COPY_MAPPING=()
SYMBOLIC_LINK_MAPPING=()
EXCLUDE_MAPPING=()
NESTED_ITEM_TRANSFORM=()

# =============================================================================
#                              GLOBAL STATE (CLI)
# =============================================================================

MODE=""
CONFIG_FILE=""           # --config: sourced bash snippet with the job config
STAGING_DIR=""           # --staging-dir or config STAGING_DIR; else mktemp (prepare)
SOURCE_USER=""
TARGET_USER=""
SHARED_GROUP=""          # if set, staging chmod is 2770 + chgrp instead of 777
FORCE_CLEANUP=0

# =============================================================================
#                              USAGE
# =============================================================================

usage() {
    cat >&2 <<EOF
Usage: $0 --mode <prepare|deploy|cleanup> --config <file> [options]

Job specifics (base dirs, item lists, optional staging path) come from
--config (a sourced bash snippet) and/or the override flags below. Nothing is
hardcoded in the script. See selective_copy.conf.example for the contract.

REQUIRED for prepare:
  --mode prepare
  --config FILE         Job config defining SOURCE_BASE_DIR, TARGET_BASE_DIR,
                        COPY_MAPPING, etc. (or supply base dirs via flags below)
  --source-user USER    Expected uid name on this side (sanity check)
  --target-user USER    Expected uid name for the deploy step (recorded)

REQUIRED for deploy:
  --mode deploy
  --config FILE         The SAME config used for prepare (TARGET_BASE_DIR + the
                        item lists deploy must replay)
  --staging-dir PATH    Staging dir from prepare (or set STAGING_DIR in config)
  --target-user USER    Expected uid name on this side (sanity check)

REQUIRED for cleanup:
  --mode cleanup
  --staging-dir PATH

OPTIONAL (override the config):
  --source-base PATH    SOURCE_BASE_DIR (no hardcoded default)
  --target-base PATH    TARGET_BASE_DIR (no hardcoded default)
  --staging-dir PATH    Fixed staging dir. For prepare it is created + perms set
                        (must be empty or absent); if unset, prepare uses mktemp.
  --shared-group GROUP  Use mode 2770 + chgrp instead of 777 (both users must
                        already belong to this group; no sudo to fix that here)
  --force               cleanup proceeds even if not owned by current user
  --log-file PATH       Default: <staging-dir>/selective_copy.log

EXAMPLES:
  # As source user (e.g. opc_d1) — staging path taken from the config:
  $0 --mode prepare --config ./selective_copy.conf --source-user opc_d1 --target-user opc_d2

  # As target user (e.g. opc_d2):
  $0 --mode deploy  --config ./selective_copy.conf --target-user opc_d2 --staging-dir /tmp/test_f2/migration

  # Cleanup (either user who owns the staging dir):
  $0 --mode cleanup --staging-dir /tmp/test_f2/migration
EOF
    exit 1
}

parse_args() {
    # CLI base/staging are captured into temporaries so they can be applied
    # AFTER the config file is sourced — CLI flags must win over config.
    local log_arg="" cli_source_base="" cli_target_base="" cli_staging=""
    if [ "$#" -eq 0 ]; then usage; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)         MODE="$2"; shift 2 ;;
            --config)       CONFIG_FILE="$2"; shift 2 ;;
            --staging-dir)  cli_staging="$2"; shift 2 ;;
            --source-user)  SOURCE_USER="$2"; shift 2 ;;
            --target-user)  TARGET_USER="$2"; shift 2 ;;
            --source-base)  cli_source_base="$2"; shift 2 ;;
            --target-base)  cli_target_base="$2"; shift 2 ;;
            --shared-group) SHARED_GROUP="$2"; shift 2 ;;
            --force)        FORCE_CLEANUP=1; shift ;;
            --log-file)     log_arg="$2"; shift 2 ;;
            -h|--help)      usage ;;
            *) echo "Error: Unknown argument '$1'" >&2; usage ;;
        esac
    done

    [ -n "$MODE" ] || usage

    # Load the job config FIRST (it may set base dirs, STAGING_DIR, and the
    # item arrays), so the CLI overrides applied next take precedence.
    if [ -n "$CONFIG_FILE" ]; then
        [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
        # shellcheck disable=SC1090  # operator-authored config, sourced as bash
        source "$CONFIG_FILE"
    fi

    # CLI overrides win over config.
    [ -n "$cli_source_base" ] && SOURCE_BASE_DIR="$cli_source_base"
    [ -n "$cli_target_base" ] && TARGET_BASE_DIR="$cli_target_base"
    [ -n "$cli_staging" ]     && STAGING_DIR="$cli_staging"

    # Normalize the paths we have (collapse //, drop trailing /) so later
    # prefix/concatenation logic is clean.
    [ -n "$SOURCE_BASE_DIR" ] && SOURCE_BASE_DIR="$(normalize_path "$SOURCE_BASE_DIR")"
    [ -n "$TARGET_BASE_DIR" ] && TARGET_BASE_DIR="$(normalize_path "$TARGET_BASE_DIR")"
    [ -n "$STAGING_DIR" ]     && STAGING_DIR="$(normalize_path "$STAGING_DIR")"

    # Lock the job inputs now that config + CLI are resolved. (STAGING_DIR is
    # NOT locked — create_staging_dir assigns it in the mktemp case.)
    readonly SOURCE_BASE_DIR TARGET_BASE_DIR \
             COPY_MAPPING SYMBOLIC_LINK_MAPPING EXCLUDE_MAPPING NESTED_ITEM_TRANSFORM

    if [ -n "$log_arg" ]; then
        export LOG_FILE="$log_arg"
    fi

    # Refuse to run as root — defeats the entire split-permission model.
    if [ "$(id -u)" -eq 0 ]; then
        die "Refusing to run as root: defeats the split-user permission model"
    fi
}

# =============================================================================
#                              IDENTITY CHECKS
# =============================================================================

assert_running_as() {
    local expected_user="$1"
    local label="$2"
    local actual; actual="$(id -un)"
    if [ "$actual" != "$expected_user" ]; then
        die "$label expected user '$expected_user'; running as '$actual'"
    fi
}

# =============================================================================
#                              STAGING DIR
# =============================================================================

create_staging_dir() {
    if [ -n "$STAGING_DIR" ]; then
        # Operator-supplied fixed staging path (from --staging-dir or config).
        # Refuse to clobber an existing non-empty dir — a clean prepare and the
        # deploy-side tamper check both assume staging starts empty.
        if [ -e "$STAGING_DIR" ] && [ -n "$(ls -A "$STAGING_DIR" 2>/dev/null)" ]; then
            die "Staging dir '$STAGING_DIR' already exists and is non-empty. Remove it or choose another."
        fi
        safe_mkdir_p "$STAGING_DIR"
    else
        # No fixed path given — generate a fresh one under /tmp.
        STAGING_DIR="$(mktemp -d "/tmp/scopy.XXXXXXXX")"
    fi

    if [ -n "$SHARED_GROUP" ]; then
        if ! chgrp "$SHARED_GROUP" "$STAGING_DIR" 2>/dev/null; then
            die "chgrp '$SHARED_GROUP' failed on $STAGING_DIR (group must exist and current user must be a member)"
        fi
        chmod 2770 "$STAGING_DIR"   # 2 = setgid so subdirs inherit group
        info "Staging permissions: 2770 (setgid), group=$SHARED_GROUP"
    else
        chmod 777 "$STAGING_DIR"
        warn "Staging permissions: 777 (world-writable). Set --shared-group to tighten if a shared group exists."
    fi
    info "Staging dir: $STAGING_DIR"
}

state_file_path() {
    printf '%s/permissions.state' "$STAGING_DIR"
}

# =============================================================================
#                              MODE: PREPARE
# =============================================================================

run_prepare() {
    [ -n "$SOURCE_USER" ] || die "--mode prepare requires --source-user"
    [ -n "$TARGET_USER" ] || die "--mode prepare requires --target-user"
    [ -n "$SOURCE_BASE_DIR" ] || die "--mode prepare requires SOURCE_BASE_DIR (set it in --config or pass --source-base)"
    [ -n "$TARGET_BASE_DIR" ] || die "--mode prepare requires TARGET_BASE_DIR (recorded for deploy; set it in --config or pass --target-base)"
    [ -d "$SOURCE_BASE_DIR" ] || die "Source base dir does not exist: $SOURCE_BASE_DIR"
    if [ "${#COPY_MAPPING[@]}" -eq 0 ] && [ "${#SYMBOLIC_LINK_MAPPING[@]}" -eq 0 ]; then
        warn "No COPY_MAPPING or SYMBOLIC_LINK_MAPPING items configured — nothing to stage."
    fi
    assert_running_as "$SOURCE_USER" "prepare"

    create_staging_dir

    # LOG_FILE default now that we have staging.
    export LOG_FILE="${LOG_FILE:-${STAGING_DIR}/selective_copy.log}"
    : > "$LOG_FILE"
    info "Starting PREPARE  source=$SOURCE_USER  target=$TARGET_USER"

    # Stage regular files/dirs.
    local item_map src_name dest_name full_src_path stage_dest_path
    if [ "${#COPY_MAPPING[@]}" -gt 0 ]; then
        info "Staging regular items..."
        for item_map in "${COPY_MAPPING[@]}"; do
            IFS='|' read -r src_name dest_name <<< "${item_map}"
            src_name="${src_name%/}"; dest_name="${dest_name%/}"   # normalize trailing /
            full_src_path="${SOURCE_BASE_DIR}/${src_name}"
            stage_dest_path="${STAGING_DIR}/${dest_name}"
            if [ ! -e "$full_src_path" ] && [ ! -L "$full_src_path" ]; then
                warn "Source missing, skipping: $full_src_path"
                continue
            fi
            local rsync_exclude_args=()
            local rule rule_src_name rule_pattern
            # bash 4.2/4.3 quirk: "${arr[@]}" on an EMPTY array under `set -u`
            # is an "unbound variable" error (fixed in 4.4 — which is why bash
            # 5.x never caught this). Use the "${arr[@]+"${arr[@]}"}" form so an
            # empty EXCLUDE_MAPPING expands to nothing instead of aborting on
            # the target bash 4.2.46.
            for rule in "${EXCLUDE_MAPPING[@]+"${EXCLUDE_MAPPING[@]}"}"; do
                IFS=':' read -r rule_src_name rule_pattern <<< "$rule"
                if [ "$rule_src_name" = "$src_name" ]; then
                    rsync_exclude_args+=(--exclude="$rule_pattern")
                fi
            done
            info "Staging: $full_src_path -> $stage_dest_path"
            safe_mkdir_p "$(dirname "$stage_dest_path")"
            # Copy so the item lands AT dest_name (rename-capable), NOT nested
            # inside it. For a directory, trailing slashes on BOTH sides copy the
            # CONTENTS into dest (so /src/bin -> STAGING/<dest>, not
            # STAGING/<dest>/bin). For a file/symlink, copy to the dest path.
            # (rsync_exclude_args guarded for the same bash-4.2 empty-array reason.)
            if [ -d "$full_src_path" ] && [ ! -L "$full_src_path" ]; then
                safe_mkdir_p "$stage_dest_path"
                if ! rsync -a "${rsync_exclude_args[@]+"${rsync_exclude_args[@]}"}" "$full_src_path/" "$stage_dest_path/"; then
                    die "rsync failed: $full_src_path -> $stage_dest_path"
                fi
            else
                if ! rsync -a "${rsync_exclude_args[@]+"${rsync_exclude_args[@]}"}" "$full_src_path" "$stage_dest_path"; then
                    die "rsync failed: $full_src_path -> $stage_dest_path"
                fi
            fi
        done
    fi

    # Stage symlinks.
    local src_link_name dest_link_name dest_link_target
    if [ "${#SYMBOLIC_LINK_MAPPING[@]}" -gt 0 ]; then
        info "Staging symlinks..."
        for item_map in "${SYMBOLIC_LINK_MAPPING[@]}"; do
            IFS='|' read -r src_link_name dest_link_name dest_link_target <<< "$item_map"
            full_src_path="${SOURCE_BASE_DIR}/${src_link_name}"
            stage_dest_path="${STAGING_DIR}/${dest_link_name}"
            if [ ! -L "$full_src_path" ]; then
                warn "Source is not a symlink, skipping: $full_src_path"
                continue
            fi
            info "Staging symlink: $full_src_path -> $stage_dest_path"
            if ! rsync -a "$full_src_path" "$stage_dest_path"; then
                die "rsync failed on symlink: $full_src_path"
            fi
        done
    fi

    # Tab-separated state file: <perm>\t<mtime>\t<path>
    # Tabs are not valid in unix paths under any common convention, so this
    # is safe for paths containing spaces (the old space-delimited form broke).
    info "Recording lstat state to $(state_file_path)"
    find "$STAGING_DIR" -not -path "$(state_file_path)" -not -path "${LOG_FILE}" \
        -printf "%m\t%T@\t%p\n" > "$(state_file_path)"

    # Record the expected target user so deploy can sanity-check.
    echo "TARGET_USER=$TARGET_USER" > "${STAGING_DIR}/.expected_target_user"

    # Set open perms on staged content so target user can read+exec.
    if [ -n "$SHARED_GROUP" ]; then
        find "$STAGING_DIR" -type d -exec chmod 2770 {} +
        find "$STAGING_DIR" -type f -exec chmod 660 {} +
    else
        find "$STAGING_DIR" -type d -exec chmod 777 {} +
        find "$STAGING_DIR" -type f -exec chmod 666 {} +
    fi

    success "PREPARE complete."
    info ""
    info "Next: run as $TARGET_USER on this host:"
    info "  bash $0 --mode deploy --target-user $TARGET_USER --staging-dir $STAGING_DIR"
    info ""
}

# =============================================================================
#                              MODE: DEPLOY
# =============================================================================

run_deploy() {
    [ -n "$STAGING_DIR" ] || die "--mode deploy requires --staging-dir"
    [ -n "$TARGET_USER" ] || die "--mode deploy requires --target-user"
    [ -n "$TARGET_BASE_DIR" ] || die "--mode deploy requires TARGET_BASE_DIR (set it in --config or pass --target-base)"
    [ -d "$STAGING_DIR" ] || die "Staging dir not found: $STAGING_DIR"

    assert_running_as "$TARGET_USER" "deploy"

    export LOG_FILE="${LOG_FILE:-${STAGING_DIR}/selective_copy_deploy.log}"
    : > "$LOG_FILE"
    info "Starting DEPLOY  target=$TARGET_USER  staging=$STAGING_DIR"

    # Verify recorded target user matches.
    local expected_marker="${STAGING_DIR}/.expected_target_user"
    if [ -f "$expected_marker" ]; then
        local recorded; recorded=$(grep '^TARGET_USER=' "$expected_marker" | head -n1 | cut -d= -f2)
        if [ -n "$recorded" ] && [ "$recorded" != "$TARGET_USER" ]; then
            die "Staging was prepared for target '$recorded', not '$TARGET_USER'"
        fi
    fi

    # Tamper check: state file mtime should be the newest of all files in
    # staging (it was written last by prepare). If anything in staging is
    # newer, refuse — someone may have modified content after prepare.
    local state_file; state_file="$(state_file_path)"
    [ -f "$state_file" ] || die "State file missing: $state_file"
    local state_mtime newest_inner
    state_mtime=$(lstat_mtime_epoch "$state_file")
    newest_inner=$(find "$STAGING_DIR" \
                       -not -path "$state_file" \
                       -not -path "$LOG_FILE" \
                       -not -path "${STAGING_DIR}/.expected_target_user" \
                       -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
    if [ -n "$newest_inner" ] && [ "$newest_inner" -gt "$state_mtime" ]; then
        die "Tamper detection: a file in staging is newer than the state file. Aborting."
    fi

    # Deploy regular items.
    local item_map src_name dest_name stage_src_path final_dest_path
    if [ "${#COPY_MAPPING[@]}" -gt 0 ]; then
        info "Deploying regular items..."
        for item_map in "${COPY_MAPPING[@]}"; do
            IFS='|' read -r src_name dest_name <<< "$item_map"
            dest_name="${dest_name%/}"   # normalize, matching prepare
            stage_src_path="${STAGING_DIR}/${dest_name}"
            final_dest_path="${TARGET_BASE_DIR}/${dest_name}"
            if [ ! -e "$stage_src_path" ] && [ ! -L "$stage_src_path" ]; then
                warn "Staged item missing: $stage_src_path"
                continue
            fi
            if [ -d "$stage_src_path" ] && [ ! -L "$stage_src_path" ]; then
                safe_mkdir_p "$final_dest_path"
                info "Deploying dir: $stage_src_path/ -> $final_dest_path/"
                # Trailing slash on src + dest dir => contents land directly
                # under final_dest_path (no nesting), mirroring prepare.
                rsync -a "$stage_src_path/" "$final_dest_path/" || die "rsync failed for $stage_src_path"
            else
                safe_mkdir_p "$(dirname "$final_dest_path")"
                info "Deploying: $stage_src_path -> $final_dest_path"
                rsync -a "$stage_src_path" "$final_dest_path" || die "rsync failed for $stage_src_path"
            fi
        done
    fi

    # Create target symlinks.
    local src_link_name dest_link_name dest_link_target
    if [ "${#SYMBOLIC_LINK_MAPPING[@]}" -gt 0 ]; then
        info "Creating symlinks at target..."
        for item_map in "${SYMBOLIC_LINK_MAPPING[@]}"; do
            IFS='|' read -r src_link_name dest_link_name dest_link_target <<< "$item_map"
            final_dest_path="${TARGET_BASE_DIR}/${dest_link_name}"
            safe_mkdir_p "$(dirname "$final_dest_path")"
            info "Symlink: $final_dest_path -> $dest_link_target"
            ln -sf "$dest_link_target" "$final_dest_path"
        done
    fi

    # Nested transforms.
    if [ "${#NESTED_ITEM_TRANSFORM[@]}" -gt 0 ]; then
        info "Applying nested transforms..."
        apply_nested_transforms
    fi

    # Restore lstat from state file (tab-separated, space-safe).
    info "Restoring lstat from state file..."
    restore_state

    success "DEPLOY complete."
}

apply_nested_transforms() {
    local item original_rel_path new_name new_target
    local original_full_path new_full_path
    for item in "${NESTED_ITEM_TRANSFORM[@]}"; do
        IFS='|' read -r original_rel_path new_name new_target <<< "$item"
        original_full_path="${TARGET_BASE_DIR}/${original_rel_path}"
        new_full_path="$(dirname "$original_full_path")/${new_name}"
        if [ ! -e "$original_full_path" ] && [ ! -L "$original_full_path" ]; then
            warn "Nested item to transform not found: $original_full_path"
            continue
        fi
        if [ -z "$new_target" ]; then
            info "Renaming: $original_full_path -> $new_full_path"
            mv "$original_full_path" "$new_full_path" || die "rename failed"
        else
            info "Retargeting symlink: $new_full_path -> $new_target"
            rm -f "$original_full_path"
            ln -s "$new_target" "$new_full_path" || die "symlink retarget failed"
        fi
    done
}

restore_state() {
    local state_file; state_file="$(state_file_path)"
    local perm ts staged_path final_path

    # Build the set of transformed paths so we can skip lstat restore on
    # entries that were renamed (their staged path no longer matches the
    # final path).
    declare -A was_transformed
    if [ "${#NESTED_ITEM_TRANSFORM[@]}" -gt 0 ]; then
        local item rel _new _t
        for item in "${NESTED_ITEM_TRANSFORM[@]}"; do
            IFS='|' read -r rel _new _t <<< "$item"
            was_transformed["${TARGET_BASE_DIR}/${rel}"]=1
        done
    fi

    while IFS=$'\t' read -r perm ts staged_path; do
        [ -z "$staged_path" ] && continue
        # Strip staging prefix to derive the final path under target base.
        local rel="${staged_path#${STAGING_DIR}}"
        final_path="${TARGET_BASE_DIR}${rel}"

        if [ -n "${was_transformed[$final_path]:-}" ]; then
            info "Skipping lstat restore for transformed entry: $final_path"
            continue
        fi

        if [ ! -e "$final_path" ] && [ ! -L "$final_path" ]; then
            warn "Cannot restore lstat (path not found): $final_path"
            continue
        fi

        # Symlinks: touch with -h only; chmod has no effect on the link itself.
        if [ -L "$final_path" ]; then
            touch -h -d "@${ts%.*}" "$final_path" 2>/dev/null || \
                warn "touch -h failed on symlink: $final_path"
        else
            chmod "$perm" "$final_path" 2>/dev/null || \
                warn "chmod $perm failed on: $final_path"
            touch -d "@${ts%.*}" "$final_path" 2>/dev/null || \
                warn "touch failed on: $final_path"
        fi
    done < "$state_file"
}

# =============================================================================
#                              MODE: CLEANUP
# =============================================================================

run_cleanup() {
    [ -n "$STAGING_DIR" ] || die "--mode cleanup requires --staging-dir"
    [ -d "$STAGING_DIR" ] || { info "Staging dir already gone: $STAGING_DIR"; return 0; }

    local owner; owner=$(stat -c '%U' "$STAGING_DIR")
    local me;    me=$(id -un)
    if [ "$owner" != "$me" ] && [ "$FORCE_CLEANUP" -ne 1 ]; then
        die "Staging owned by '$owner', not by '$me'. Pass --force to override."
    fi

    info "Removing staging dir: $STAGING_DIR"
    rm -rf "$STAGING_DIR"
    success "CLEANUP complete."
}

# =============================================================================
#                              MAIN
# =============================================================================

main() {
    parse_args "$@"
    case "$MODE" in
        prepare) run_prepare ;;
        deploy)  run_deploy ;;
        cleanup) run_cleanup ;;
        *) echo "Error: invalid --mode '$MODE'" >&2; usage ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
