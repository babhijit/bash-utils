#!/bin/bash
# =============================================================================
#
# Script:      validate.sh
#
# Description:
#   Standalone, thorough validator for a completed migration. Reads
#   migrator's tracking file (default: <workdir>/progress.log) and performs
#   per-row checks plus optional tree-wide scans.
#
#   This is the "did everything work" gate before declaring the migration
#   complete. It is more comprehensive than `migrator.sh --mode validate`,
#   which does only the fast internal-consistency check.
#
# Per-row checks (every COMPLETED row in the tracking file):
#   1. The migrated path (new_path) exists or is a symlink.
#   2. The backup at backup_path_for(orig_path) exists.
#   3. mtime of new_path == recorded original timestamp (epoch equality).
#   4. lstat type of new_path matches lstat type of backup (file/dir/link).
#   5. For files: content of new_path either equals backup OR differs in
#      ways consistent with MIGRATION_MAP (no spurious changes).
#   6. For symlinks: new_path's target equals apply_path_mapping(backup_target).
#
# Tree-wide scan (optional, --scan-root):
#   - Walk --scan-root looking for any remaining fat1-style references in
#     names OR contents. Warns (does not fail) — there may be intentional
#     references the operator chose not to migrate.
#
# Exit code:
#   0 if all per-row checks pass.
#   1 if any per-row check fails (tree-wide scan is informational).
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=migrator.sh
source "${SCRIPT_DIR}/migrator.sh"   # for MIGRATION_MAP + backup_path_for()
require_bash_version 4 2
set -euo pipefail

# =============================================================================
#                              GLOBAL STATE
# =============================================================================

WORKDIR=""
ROOT=""
TRACKING_FILE=""
SCAN_ROOT=""
PASS=0
FAIL=0

# BACKUP_DIR is a global declared by migrator.sh; backup_path_for() reads it
# directly. We re-declare it here so validate.sh's parse_args can set it.
# (Sourcing migrator.sh into this script makes BACKUP_DIR visible already;
#  this line is documentation, not a fresh declaration.)
# BACKUP_DIR is set in parse_args() below.

# =============================================================================
#                              USAGE
# =============================================================================

usage() {
    cat >&2 <<EOF
Usage: $0 --root <path> [options]

REQUIRED:
  --root  PATH   The same --root passed to migrator (for backup_path_for
                 reconstruction). Refuses if a row's new_path is outside --root.

OPTIONAL:
  --workdir       PATH   Default: /tmp/migration_f2
  --tracking-file PATH   Default: <workdir>/progress.log
  --backup-dir    PATH   Default: <workdir>/backups
                         Must match what migrator used.
  --scan-root     PATH   Tree-wide scan for remaining fat1 references.
                         Typically the same as --root. Informational only.
  --log-file      PATH   Default: <workdir>/validate_<run-id>.log

EXIT CODES:
  0 — all per-row checks passed.
  1 — at least one per-row check failed.
  2 — usage/setup error.
EOF
    exit 2
}

parse_args() {
    local workdir_arg=""
    local tracking_arg=""
    local backup_dir_arg=""
    local log_arg=""
    if [ "$#" -eq 0 ]; then usage; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --root)           ROOT="$2"; shift 2 ;;
            --workdir)        workdir_arg="$2"; shift 2 ;;
            --tracking-file)  tracking_arg="$2"; shift 2 ;;
            --backup-dir)     backup_dir_arg="$2"; shift 2 ;;
            --scan-root)      SCAN_ROOT="$2"; shift 2 ;;
            --log-file)       log_arg="$2"; shift 2 ;;
            -h|--help)        usage ;;
            *) echo "Error: Unknown argument '$1'" >&2; usage ;;
        esac
    done
    [ -n "$ROOT" ] || { echo "Error: --root required" >&2; usage; }

    WORKDIR="${workdir_arg:-/tmp/migration_f2}"
    TRACKING_FILE="${tracking_arg:-${WORKDIR}/progress.log}"
    # BACKUP_DIR is read by backup_path_for() (defined in migrator.sh, sourced
    # above). It MUST be set or the backup-path computation produces garbage.
    BACKUP_DIR="${backup_dir_arg:-${WORKDIR}/backups}"
    export LOG_FILE="${log_arg:-${WORKDIR}/validate_$(new_run_id).log}"

    ROOT="$(normalize_path "$ROOT")"
    BACKUP_DIR="$(normalize_path "$BACKUP_DIR")"

    [ -f "$TRACKING_FILE" ] || die "Tracking file not found: $TRACKING_FILE"
    [ -d "$BACKUP_DIR" ]    || die "Backup dir not found: $BACKUP_DIR"
}

# =============================================================================
#                              PER-ROW CHECKS
# =============================================================================

check_row() {
    local orig_path="$1"
    local new_path="$2"
    local bkp="$3"
    local expected_ts="$4"

    # 0. Sanity: new_path under --root
    if ! { [ "$new_path" = "$ROOT" ] || [[ "$new_path" == "$ROOT"/* ]]; }; then
        warn "FAIL ($orig_path): new_path '$new_path' is not under --root '$ROOT'"
        FAIL=$((FAIL + 1)); return
    fi

    # 1. Migrated path exists
    if [ ! -e "$new_path" ] && [ ! -L "$new_path" ]; then
        warn "FAIL ($orig_path): migrated path missing: $new_path"
        FAIL=$((FAIL + 1)); return
    fi

    # 2. Backup exists
    if [ ! -e "$bkp" ] && [ ! -L "$bkp" ]; then
        warn "FAIL ($orig_path): backup missing: $bkp"
        FAIL=$((FAIL + 1)); return
    fi

    # 3. mtime matches recorded
    local actual_epoch expected_epoch
    actual_epoch=$(lstat_mtime_epoch "$new_path")
    expected_epoch=$(date -d "$expected_ts" +%s 2>/dev/null) || expected_epoch=""
    if [ -z "$expected_epoch" ]; then
        warn "FAIL ($orig_path): could not parse recorded timestamp '$expected_ts'"
        FAIL=$((FAIL + 1)); return
    fi
    if [ "$actual_epoch" != "$expected_epoch" ]; then
        warn "FAIL ($orig_path): mtime mismatch (have $actual_epoch, expected $expected_epoch)"
        FAIL=$((FAIL + 1)); return
    fi

    # 4. lstat type matches backup
    local t_new t_bkp
    t_new=$(lstat_type "$new_path")
    t_bkp=$(lstat_type "$bkp")
    if [ "$t_new" != "$t_bkp" ]; then
        warn "FAIL ($orig_path): lstat type mismatch (new=$t_new, backup=$t_bkp)"
        FAIL=$((FAIL + 1)); return
    fi

    # 5/6. Type-specific content/target checks
    case "$t_new" in
        symlink)
            local actual_target expected_target backup_target
            actual_target=$(readlink "$new_path")
            backup_target=$(readlink "$bkp")
            expected_target="$(apply_path_mapping "$backup_target" MIGRATION_MAP)"
            if [ "$actual_target" != "$expected_target" ]; then
                warn "FAIL ($orig_path): symlink target mismatch (have '$actual_target', expected '$expected_target')"
                FAIL=$((FAIL + 1)); return
            fi
            ;;
        file)
            # Verify content rewrite: apply mapping to backup and compare to new.
            local expected_content_tmp
            expected_content_tmp=$(mktemp)
            cp -a "$bkp" "$expected_content_tmp"
            replace_content_in_file "$expected_content_tmp" MIGRATION_MAP || {
                rm -f "$expected_content_tmp"
                warn "FAIL ($orig_path): could not compute expected content"
                FAIL=$((FAIL + 1)); return
            }
            if ! diff -q "$expected_content_tmp" "$new_path" >/dev/null 2>&1; then
                rm -f "$expected_content_tmp"
                warn "FAIL ($orig_path): content does not match expected rewrite of backup"
                FAIL=$((FAIL + 1)); return
            fi
            rm -f "$expected_content_tmp"
            ;;
        dir)
            # Directory: no content check at this level — child files were
            # rewritten and validated as their own rows IF they were in the
            # CSV. If a child wasn't in the CSV, we trust migrator's directory
            # walk (covered by the tree-wide scan below).
            :
            ;;
        other)
            warn "FAIL ($orig_path): unsupported lstat type '$t_new'"
            FAIL=$((FAIL + 1)); return
            ;;
    esac

    PASS=$((PASS + 1))
}

# =============================================================================
#                              TRACKING FILE WALK
# =============================================================================

# Build the latest-status map then iterate over COMPLETED rows only.
run_per_row_checks() {
    info "Reading tracking file: $TRACKING_FILE"

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

    local total=0
    local path
    for path in "${!latest_status[@]}"; do
        [ "${latest_status[$path]}" = "COMPLETED" ] || continue
        total=$((total + 1))
        check_row "$path" "${new_for[$path]}" \
            "$(backup_path_for "$path")" "${ts_for[$path]}"
    done

    info "----- PER-ROW SUMMARY -----"
    info "  total COMPLETED rows checked: $total"
    info "  pass: $PASS"
    info "  fail: $FAIL"
}

# =============================================================================
#                              TREE-WIDE SCAN (optional)
# =============================================================================
#
# Walks --scan-root looking for any remaining fat1-style references in
# names or contents. Informational: prints a count, does not affect exit.

run_tree_scan() {
    [ -n "$SCAN_ROOT" ] || return 0
    [ -d "$SCAN_ROOT" ] || { warn "Scan root not a directory: $SCAN_ROOT"; return 0; }

    info "Tree-wide scan: looking for residual references under $SCAN_ROOT"

    local pattern hits_name=0 hits_content=0
    local keys=("${!MIGRATION_MAP[@]}")

    for pattern in "${keys[@]}"; do
        local n_count c_count
        # Name hits
        n_count=$(find -L "$SCAN_ROOT" -iname "*${pattern}*" 2>/dev/null | wc -l)
        # Content hits (regular files only, suppress binary). grep -r -l
        # gives one line per matching file.
        c_count=$(grep -rIl -F "$pattern" "$SCAN_ROOT" 2>/dev/null | wc -l)
        if [ "$n_count" -gt 0 ] || [ "$c_count" -gt 0 ]; then
            info "  '$pattern': $n_count name-match(es), $c_count content-match(es)"
        fi
        hits_name=$((hits_name + n_count))
        hits_content=$((hits_content + c_count))
    done

    if [ "$hits_name" -eq 0 ] && [ "$hits_content" -eq 0 ]; then
        info "Tree scan: ZERO residual references under $SCAN_ROOT"
    else
        warn "Tree scan: residual references remain ($hits_name name, $hits_content content)"
        warn "  This may be intentional (CSV didn't cover them) — investigate manually."
    fi
}

# =============================================================================
#                              MAIN
# =============================================================================

main() {
    parse_args "$@"
    safe_mkdir_p "$WORKDIR"
    : > "$LOG_FILE"

    info "validate.sh starting"
    info "  root=$ROOT  workdir=$WORKDIR"
    info "  tracking=$TRACKING_FILE"
    [ -n "$SCAN_ROOT" ] && info "  scan_root=$SCAN_ROOT"

    run_per_row_checks
    run_tree_scan

    if [ "$FAIL" -gt 0 ]; then
        warn "VALIDATE FAILED: $FAIL failure(s); see $LOG_FILE"
        exit 1
    fi
    success "VALIDATE PASSED: $PASS row(s) checked, all good."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
