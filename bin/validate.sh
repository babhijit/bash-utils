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
#   2. The backup at backup_path exists.
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
# Depend on the shared modules — NOT on migrator.sh. (Sourcing migrator pulled
# its entire function set, incl. a second run_validate(), into this script,
# resolved only by definition order.)
# shellcheck source=migration_map.sh
source "${SCRIPT_DIR}/migration_map.sh"   # MIGRATION_MAP (data)
# shellcheck source=backup.sh
source "${SCRIPT_DIR}/backup.sh"           # backup_path_for()
# shellcheck source=tracking.sh
source "${SCRIPT_DIR}/tracking.sh"         # tracking_load_latest()
require_bash_version 4 2
set -euo pipefail

# =============================================================================
#                              GLOBAL STATE
# =============================================================================

WORKDIR=""
ROOT=""
TRACKING_FILE=""
SCAN_ROOT=""
VERBOSE=0
PASS=0
FAIL=0
VALIDATE_LOG=""   # plain-text log file (no ANSI codes)

# BACKUP_DIR is read by backup_path_for() (from backup.sh). validate.sh sets
# it in parse_args() below; it needs no pre-declaration.

# =============================================================================
#                              COLOURS
# =============================================================================

if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_GREEN=$'\033[0;32m'
    C_RED=$'\033[0;31m'
    C_YELLOW=$'\033[0;33m'
    C_CYAN=$'\033[0;36m'
    C_DIM=$'\033[0;90m'
    C_BOLD=$'\033[1m'
else
    C_RESET='' C_GREEN='' C_RED='' C_YELLOW='' C_CYAN='' C_DIM='' C_BOLD=''
fi

# =============================================================================
#                              OUTPUT HELPERS
# =============================================================================

# Strip ANSI escape codes for plain-text log.
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# All console output is tee'd to the log via a fd redirect set up in main().
# out() just prints to stdout; the tee handles dual output.
out() {
    printf "%s\n" "$1"
}

# Short name for display — strip the --root prefix to reduce noise.
short_path() {
    local p="$1"
    echo "${p#${ROOT}/}"
}

# Basename of a path for rename display.
base_name() {
    echo "${1##*/}"
}

row_pass() {
    local msg="${C_GREEN}  PASS${C_RESET} $1"
    PASS=$((PASS + 1))
    out "$msg"
}

row_fail() {
    local label="$1"
    shift
    FAIL=$((FAIL + 1))
    out "${C_RED}  FAIL${C_RESET} ${label}"
    local line
    for line in "$@"; do
        out "${C_RED}       ${line}${C_RESET}"
    done
}

row_detail() {
    out "${C_DIM}       $1${C_RESET}"
}

row_info() {
    out "${C_CYAN}       $1${C_RESET}"
}

# Print a coloured diff to console and plain diff to log.
print_diff() {
    local file_a="$1" file_b="$2" max_lines="${3:-30}"
    local dline
    diff -u "$file_a" "$file_b" 2>/dev/null \
        | head -"$max_lines" \
        | while IFS= read -r dline; do
            local plain="       ${dline}"
            case "$dline" in
                ---*) out "${C_RED}       ${dline}${C_RESET}" ;;
                +++*) out "${C_GREEN}       ${dline}${C_RESET}" ;;
                -*)   out "${C_RED}       ${dline}${C_RESET}" ;;
                +*)   out "${C_GREEN}       ${dline}${C_RESET}" ;;
                @@*)  out "${C_CYAN}       ${dline}${C_RESET}" ;;
                *)    out "${C_DIM}       ${dline}${C_RESET}" ;;
            esac
        done
}

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
  --verbose              Show detail for passing rows too (not just failures).

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
            --verbose)        VERBOSE=1; shift ;;
            -h|--help)        usage ;;
            *) echo "Error: Unknown argument '$1'" >&2; usage ;;
        esac
    done
    [ -n "$ROOT" ] || { echo "Error: --root required" >&2; usage; }

    WORKDIR="${workdir_arg:-/tmp/migration_f2}"
    TRACKING_FILE="${tracking_arg:-${WORKDIR}/progress.log}"
    BACKUP_DIR="${backup_dir_arg:-${WORKDIR}/backups}"
    VALIDATE_LOG="${log_arg:-${WORKDIR}/validate_$(new_run_id).log}"
    export LOG_FILE="$VALIDATE_LOG"

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

    local display_orig display_new display_bkp
    display_orig=$(short_path "$orig_path")
    display_new=$(short_path "$new_path")
    display_bkp="${bkp#${BACKUP_DIR}/}"

    local orig_base new_base
    orig_base=$(base_name "$orig_path")
    new_base=$(base_name "$new_path")

    # --- Determine type and build header ---
    local type_label="file"
    if [ -L "$new_path" ] 2>/dev/null; then
        type_label="symlink"
    elif [ -d "$new_path" ] 2>/dev/null; then
        type_label="dir"
    fi

    # Detect redirected rows (target existed, so orig != new but backup is of new)
    local redirected=0
    if [ "$orig_path" != "$new_path" ] && [ "$(backup_path_for "$new_path")" = "$bkp" ]; then
        redirected=1
    fi

    out ""
    out "${C_BOLD}[${type_label}]${C_RESET} ${display_orig}"

    # --- Show name/path change ---
    if [ "$orig_path" != "$new_path" ]; then
        if [ "$redirected" -eq 1 ]; then
            row_info "target existed on disk: ${new_base}"
            row_info "action: content rewrite only (no rename)"
        elif [ "$orig_base" != "$new_base" ]; then
            row_info "renamed: ${C_RED}${orig_base}${C_RESET} ${C_DIM}->${C_RESET} ${C_GREEN}${new_base}${C_RESET}"
        fi
        row_detail "new_path: ${display_new}"
    fi

    # --- 0. Sanity: new_path under --root ---
    if ! { [ "$new_path" = "$ROOT" ] || [[ "$new_path" == "$ROOT"/* ]]; }; then
        row_fail "root check" "new_path '${display_new}' is not under --root"
        return
    fi

    # --- 1. Migrated path exists ---
    if [ ! -e "$new_path" ] && [ ! -L "$new_path" ]; then
        row_fail "migrated path exists" "MISSING: ${display_new}"
        return
    fi
    [ "$VERBOSE" -eq 1 ] && row_detail "exists: yes"

    # --- 2. Backup exists ---
    if [ ! -e "$bkp" ] && [ ! -L "$bkp" ]; then
        row_fail "backup exists" "MISSING: ${display_bkp}"
        return
    fi
    [ "$VERBOSE" -eq 1 ] && row_detail "backup: ${display_bkp}"

    # --- 3. mtime matches recorded ---
    local actual_epoch expected_epoch
    actual_epoch=$(lstat_mtime_epoch "$new_path")
    expected_epoch=$(date -d "$expected_ts" +%s 2>/dev/null) || expected_epoch=""
    if [ -z "$expected_epoch" ]; then
        row_fail "mtime" "could not parse recorded timestamp '${expected_ts}'"
        return
    fi
    if [ "$actual_epoch" != "$expected_epoch" ]; then
        row_fail "mtime" \
            "expected: ${expected_epoch} ($(date -d "@${expected_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null))" \
            "  actual: ${actual_epoch} ($(date -d "@${actual_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null))"
        return
    fi
    [ "$VERBOSE" -eq 1 ] && row_detail "mtime: ${actual_epoch} ($(date -d "@${actual_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null))"

    # --- 4. lstat type matches backup ---
    local t_new t_bkp
    t_new=$(lstat_type "$new_path")
    t_bkp=$(lstat_type "$bkp")
    if [ "$t_new" != "$t_bkp" ]; then
        row_fail "lstat type" "new=${t_new}, backup=${t_bkp}"
        return
    fi

    # --- 5/6. Type-specific checks ---
    case "$t_new" in
        symlink)
            local actual_target expected_target backup_target
            actual_target=$(readlink "$new_path")
            backup_target=$(readlink "$bkp")
            expected_target="$(apply_path_mapping "$backup_target" MIGRATION_MAP)"

            # Show symlink target diff
            if [ "$backup_target" != "$actual_target" ]; then
                row_info "target: ${C_RED}${backup_target}${C_RESET} ${C_DIM}->${C_RESET} ${C_GREEN}${actual_target}${C_RESET}"
            else
                row_info "target: ${actual_target} (unchanged)"
            fi

            if [ "$actual_target" != "$expected_target" ]; then
                row_fail "symlink target" \
                    "backup pointed to: ${backup_target}" \
                    "expected after map: ${expected_target}" \
                    "   actual points to: ${actual_target}"
                return
            fi
            row_pass "${display_orig}"
            ;;

        file)
            # Verify content rewrite: apply mapping to backup and compare to new.
            local expected_content_tmp
            expected_content_tmp=$(mktemp)
            cp -a "$bkp" "$expected_content_tmp"
            replace_content_in_file "$expected_content_tmp" MIGRATION_MAP || {
                rm -f "$expected_content_tmp"
                row_fail "content" "could not compute expected content from backup"
                return
            }

            if ! diff -q "$expected_content_tmp" "$new_path" >/dev/null 2>&1; then
                row_fail "content" \
                    "content does not match expected rewrite of backup" \
                    "--- expected (backup + MIGRATION_MAP)" \
                    "+++ actual (migrated file)"
                print_diff "$expected_content_tmp" "$new_path" 30
                rm -f "$expected_content_tmp"
                return
            fi
            rm -f "$expected_content_tmp"

            # Determine change summary
            if diff -q "$bkp" "$new_path" >/dev/null 2>&1; then
                row_pass "${display_orig} ${C_DIM}(content unchanged)${C_RESET}"
            else
                local change_count
                change_count=$(diff "$bkp" "$new_path" 2>/dev/null | grep -c '^[<>]' || true)
                row_pass "${display_orig} ${C_DIM}(${change_count} line(s) rewritten)${C_RESET}"
                if [ "$VERBOSE" -eq 1 ]; then
                    row_detail "backup vs current:"
                    print_diff "$bkp" "$new_path" 20
                fi
            fi
            ;;

        dir)
            # Show directory rename if it happened
            if [ "$orig_path" != "$new_path" ] && [ "$redirected" -eq 0 ]; then
                local orig_dir_base new_dir_base
                orig_dir_base=$(base_name "$orig_path")
                new_dir_base=$(base_name "$new_path")
                if [ "$orig_dir_base" != "$new_dir_base" ]; then
                    row_info "dir renamed: ${C_RED}${orig_dir_base}${C_RESET} ${C_DIM}->${C_RESET} ${C_GREEN}${new_dir_base}${C_RESET}"
                fi
            fi
            row_pass "${display_orig} ${C_DIM}(directory)${C_RESET}"
            ;;

        other)
            row_fail "lstat type" "unsupported type '${t_new}'"
            return
            ;;
    esac
}

# =============================================================================
#                              TRACKING FILE WALK
# =============================================================================

# Build the latest-status map then iterate over COMPLETED rows only.
run_per_row_checks() {
    out "Reading tracking file: ${TRACKING_FILE}"

    declare -A latest_status
    declare -A new_for
    declare -A bkp_for
    declare -A ts_for
    tracking_load_latest "$TRACKING_FILE" latest_status new_for bkp_for ts_for

    local total=0
    local path
    for path in "${!latest_status[@]}"; do
        [ "${latest_status[$path]}" = "COMPLETED" ] || continue
        total=$((total + 1))
        check_row "$path" "${new_for[$path]}" \
            "${bkp_for[$path]}" "${ts_for[$path]}"
    done

    out ""
    out "${C_BOLD}====== VALIDATION SUMMARY ======${C_RESET}"
    out "  Rows checked : ${total}"
    out "  ${C_GREEN}Passed       : ${PASS}${C_RESET}"
    if [ "$FAIL" -gt 0 ]; then
        out "  ${C_RED}Failed       : ${FAIL}${C_RESET}"
    else
        out "  Failed       : 0"
    fi
    out "${C_BOLD}================================${C_RESET}"
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

    out ""
    out "${C_BOLD}====== TREE-WIDE SCAN ======${C_RESET}"
    out "  Scanning: ${SCAN_ROOT}"

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
            out "  ${C_YELLOW}'${pattern}'${C_RESET}: ${n_count} name-match(es), ${c_count} content-match(es)"
            # List the matching files for visibility
            if [ "$n_count" -gt 0 ]; then
                find -L "$SCAN_ROOT" -iname "*${pattern}*" 2>/dev/null | while IFS= read -r hit; do
                    out "    ${C_DIM}name: $(short_path "$hit")${C_RESET}"
                done
            fi
            if [ "$c_count" -gt 0 ]; then
                grep -rIl -F "$pattern" "$SCAN_ROOT" 2>/dev/null | while IFS= read -r hit; do
                    out "    ${C_DIM}content: $(short_path "$hit")${C_RESET}"
                done
            fi
        fi
        hits_name=$((hits_name + n_count))
        hits_content=$((hits_content + c_count))
    done

    if [ "$hits_name" -eq 0 ] && [ "$hits_content" -eq 0 ]; then
        out "  ${C_GREEN}ZERO residual references${C_RESET}"
    else
        out "  ${C_YELLOW}Residual: ${hits_name} name, ${hits_content} content — may be intentional${C_RESET}"
    fi
    out "${C_BOLD}=============================${C_RESET}"
}

# =============================================================================
#                              MAIN
# =============================================================================

run_validate() {
    out "${C_BOLD}validate.sh${C_RESET}"
    out "  root     : ${ROOT}"
    out "  workdir  : ${WORKDIR}"
    out "  tracking : ${TRACKING_FILE}"
    out "  log      : ${VALIDATE_LOG}"
    [ -n "$SCAN_ROOT" ] && out "  scan_root: ${SCAN_ROOT}"
    out ""

    run_per_row_checks
    run_tree_scan

    if [ "$FAIL" -gt 0 ]; then
        out ""
        out "${C_RED}${C_BOLD}VALIDATE FAILED${C_RESET}: ${FAIL} failure(s)"
        out "Log: ${VALIDATE_LOG}"
    else
        out ""
        out "${C_GREEN}${C_BOLD}VALIDATE PASSED${C_RESET}: ${PASS} row(s) checked, all good."
        out "Log: ${VALIDATE_LOG}"
    fi
    return "$FAIL"
}

main() {
    parse_args "$@"
    safe_mkdir_p "$WORKDIR"

    # Capture all output (including subshells/pipes) to a raw temp file,
    # then strip ANSI codes into the final log. This avoids the race
    # condition inherent in process substitution + exec.
    local raw_log
    raw_log=$(mktemp)
    local fail_count=0

    # Run everything; tee to console AND raw file.
    run_validate 2>&1 | tee "$raw_log" || fail_count=$?

    # Strip ANSI and write final log.
    strip_ansi < "$raw_log" > "$VALIDATE_LOG"
    rm -f "$raw_log"

    # The pipe masks the exit code from run_validate (FAIL count is
    # lost in the subshell). Re-check from the log.
    if grep -q "VALIDATE FAILED" "$VALIDATE_LOG"; then
        exit 1
    fi
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
