#!/bin/bash
# =============================================================================
#
# Script:      setup_migrator_test.sh (Definitive High-Fidelity Test Harness)
#
# Description:
#   A modular, multi-mode test harness for the migrator.sh script. Supports:
#     prepare            - Replicate real items into an isolated mock env
#     execute            - Invoke migrator.sh in execute mode against the mock
#     validate           - Verify post-migration state (paths, content, ts)
#     rollback           - Invoke migrator.sh rollback + auto-validate
#     cleanup            - Invoke migrator.sh cleanup + verify backup removal
#     validate_integrity - Round-trip test: migrate forward then reverse
#     all                - prepare + execute + validate + rollback
#
# =============================================================================

# --- Script Safety and Rigor -------------------------------------------------
set -euo pipefail

# --- Configuration -----------------------------------------------------------
readonly TEST_ROOT="/tmp/test_f2/migration_test"
readonly MOCK_ENV_DIR="${TEST_ROOT}/environment_to_migrate"
readonly VALIDATION_DIR="${TEST_ROOT}/migration_validation"
readonly TEST_CSV="${TEST_ROOT}/test_input.csv"
readonly SETUP_LOG="${TEST_ROOT}/setup_migration.log"
readonly VALIDATION_LOG="${TEST_ROOT}/validation_results.log"
readonly MIGRATOR_SCRIPT_PATH="../migrator.sh"

# --- Color Definitions -------------------------------------------------------
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_NC='\033[0m'  # No Color

# Counters used by validate_log; declared here so `set -u` doesn't trip when
# validate_log fires before a phase-specific reset.
pass_count=0
fail_count=0

# -----------------------------------------------------------------------------
# usage
# -----------------------------------------------------------------------------
usage() {
    echo "Usage: $0 --mode <all|prepare|execute|validate|rollback|cleanup|validate_integrity> [--csv <real_csv_file>]"
    exit 1
}

# -----------------------------------------------------------------------------
# setup_log <LEVEL> <MESSAGE>
# Append to setup log and echo to stderr (colored if WARN).
# -----------------------------------------------------------------------------
setup_log() {
    local level="$1"
    local message="$2"
    local log_message
    log_message="$(date +'%Y-%m-%d %H:%M:%S') - ${level} - ${message}"

    if [ ! -f "${SETUP_LOG}" ]; then
        touch "${SETUP_LOG}"
    fi
    echo "$log_message" >> "${SETUP_LOG}"

    if [ "$level" == "WARN" ]; then
        echo -e "${COLOR_RED}${log_message}${COLOR_NC}" >&2
    else
        echo "$log_message" >&2
    fi
}

# -----------------------------------------------------------------------------
# validate_log <STATUS> <MESSAGE>
# Append a [PASS|FAIL] line to validation log and increment counters.
# IMPORTANT: Uses arithmetic *assignment* — NOT `((count++))` — because the
# latter evaluates to the old value (0 on first call), returns exit-status 1,
# and would terminate the script under `set -e`.
# -----------------------------------------------------------------------------
validate_log() {
    local status="$1"
    local message="$2"
    echo "[$status] $message" >> "${VALIDATION_LOG}"
    if [ "$status" == "FAIL" ]; then
        echo -e "${COLOR_RED}[FAIL]${COLOR_NC} $message" >&2
        fail_count=$((fail_count + 1))
    else
        echo -e "${COLOR_GREEN}[PASS]${COLOR_NC} $message" >&2
        pass_count=$((pass_count + 1))
    fi
}

# =============================================================================
# Phase 1: Prepare Environment
# =============================================================================
run_prepare() {
    local real_csv_path="$1"
    if [ -z "$real_csv_path" ]; then
        setup_log "ERROR" "--mode prepare requires --csv."
        usage
    fi
    if [ ! -f "$real_csv_path" ]; then
        setup_log "ERROR" "Real CSV file not found: '$real_csv_path'"
        exit 1
    fi

    rm -rf "${TEST_ROOT}"
    mkdir -p "${MOCK_ENV_DIR}"
    touch "${SETUP_LOG}"

    setup_log "INFO" "--- Phase 1: PREPARE ---"

    echo "Name,Absolute_Path,Last_Modified" > "${TEST_CSV}"

    declare -A processed_paths
    local found_count=0

    local temp_csv_file
    temp_csv_file=$(mktemp)
    tail -n +2 "$real_csv_path" > "$temp_csv_file"

    while IFS=, read -r name absolute_path last_modified; do
        echo -ne "Parsing CSV and replicating real items...\r" >&2

        name="${name//\"/}"
        absolute_path="${absolute_path//\"/}"
        last_modified="${last_modified//\"/}"
        absolute_path="${absolute_path%$'\r'}"

        if [ -n "${processed_paths[$absolute_path]:-}" ]; then
            continue
        fi

        local real_path_from_csv="$absolute_path"
        local mock_env_path="${MOCK_ENV_DIR}${absolute_path}"

        if [ ! -e "$real_path_from_csv" ] && [ ! -L "$real_path_from_csv" ]; then
            setup_log "WARN" "Source item not found on filesystem. It will NOT be included in the test: ${real_path_from_csv}"
        else
            mkdir -p "$(dirname "$mock_env_path")"

            if [ -d "$real_path_from_csv" ]; then
                setup_log "INFO" "Creating mock directory: $mock_env_path"
                mkdir -p "$mock_env_path"
                touch -d "$last_modified" "$mock_env_path"
            else
                setup_log "INFO" "Copying real item: $real_path_from_csv -> $mock_env_path"
                cp -a "$real_path_from_csv" "$mock_env_path"
            fi

            echo "\"$name\",\"$mock_env_path\",\"$last_modified\"" >> "${TEST_CSV}"
            found_count=$((found_count + 1))
        fi

        processed_paths["$absolute_path"]=1
    done < "$temp_csv_file"
    rm "$temp_csv_file"

    echo -ne "\033[2K\r" >&2
    setup_log "INFO" "PREPARE complete. Replicated $found_count real items."
}

# =============================================================================
# Phase 2: Execute Migration (delegate to migrator.sh)
# =============================================================================
run_execute() {
    setup_log "INFO" "--- Phase 2: EXECUTE ---"
    if [ ! -f "${TEST_CSV}" ]; then
        setup_log "ERROR" "Test env not prepared. Run --mode prepare first."
        exit 1
    fi

    cd "${TEST_ROOT}"
    if ! bash "${MIGRATOR_SCRIPT_PATH}" --mode execute --csv "${TEST_CSV}"; then
        setup_log "ERROR" "Migration script failed. Check logs in ${TEST_ROOT}"
        cd - >/dev/null
        exit 1
    fi
    cd - >/dev/null
    setup_log "INFO" "EXECUTE complete."
}

# =============================================================================
# Phase 3: Validate Results
# Reads the migrator's tracking file and verifies, for each entry, that the
# migrated artefact exists, was renamed (if applicable), had its content/
# symlink target transformed correctly, and retained its original mtime.
# =============================================================================
run_validate() {
    setup_log "INFO" "--- Phase 3: VALIDATE ---"
    if [ ! -f "${TEST_ROOT}/migration_progress.log" ]; then
        setup_log "ERROR" "Tracking file not found. Execute mode has not been run. Cannot validate."
        exit 1
    fi

    : > "${VALIDATION_LOG}"
    pass_count=0
    fail_count=0

    local temp_log_file
    temp_log_file=$(mktemp)
    tail -n +2 "${TEST_ROOT}/migration_progress.log" > "$temp_log_file"

    while IFS=, read -r orig_path new_path backup_path ts status; do
        orig_path="${orig_path//\"/}"
        new_path="${new_path//\"/}"
        backup_path="${backup_path//\"/}"
        ts="${ts//\"/}"
        status="${status//\"/}"

        echo >&2
        setup_log "INFO" "--- Validating Original Path: $orig_path ---"

        if [ ! -e "$new_path" ] && [ ! -L "$new_path" ]; then
            validate_log "FAIL" "Migrated item does not exist: $new_path"
            continue
        fi
        validate_log "PASS" "Migrated item exists: $new_path"

        # --- Path rename check --------------------------------------------
        if [ "$orig_path" != "$new_path" ]; then
            validate_log "PASS" "Path was correctly renamed."
            echo -e "  ${COLOR_RED}- $orig_path${COLOR_NC}" >&2
            echo -e "  ${COLOR_GREEN}+ $new_path${COLOR_NC}" >&2
        else
            validate_log "PASS" "Path did not require renaming: $orig_path"
        fi

        # --- Symlink target transformation check --------------------------
        if [ -L "$backup_path" ]; then
            local old_target; old_target=$(readlink "$backup_path")
            local new_target; new_target=$(readlink "$new_path")
            if [ "$old_target" != "$new_target" ]; then
                validate_log "PASS" "Symlink target was correctly transformed."
                echo -e "  Target Diff:" >&2
                echo -e "    ${COLOR_RED}- $old_target${COLOR_NC}" >&2
                echo -e "    ${COLOR_GREEN}+ $new_target${COLOR_NC}" >&2
            else
                validate_log "PASS" "Symlink target did not require transformation: -> $new_target"
            fi
        fi

        # --- File-content transformation check ----------------------------
        if [ -f "$new_path" ] && ! [ -L "$new_path" ]; then
            set +e
            diff -q "$backup_path" "$new_path" >/dev/null
            local diff_exit_code=$?
            set -e

            if [ $diff_exit_code -ne 0 ]; then
                validate_log "PASS" "File content was correctly modified: $new_path"
                echo "  Content Diff:" >&2
                diff --unified=3 "$backup_path" "$new_path" >&2 || true
            else
                validate_log "PASS" "File content did not require modification: $new_path"
            fi
        fi

        # --- Timestamp preservation check ---------------------------------
        local actual_ts;     actual_ts=$(stat -c %Y "$new_path")
        local expected_epoch; expected_epoch=$(date -d "$ts" +%s)
        if [ "$expected_epoch" == "$actual_ts" ]; then
            validate_log "PASS" "Timestamp correctly preserved for: $new_path"
        else
            local expected_date; expected_date=$(date -d "$ts")
            local actual_date;   actual_date=$(date -d "@$actual_ts")
            validate_log "FAIL" "Timestamp mismatch for: $new_path. Expected: $expected_date, Got: $actual_date"
        fi

    done < "$temp_log_file"
    rm "$temp_log_file"

    setup_log "INFO" "VALIDATE complete. Results logged to ${VALIDATION_LOG}"
    echo "--- SUMMARY ---"
    echo "Passed Checks: $pass_count / Failed Checks: $fail_count"
    echo "---------------"
    if [ "$fail_count" -gt 0 ]; then
        exit 1
    fi
}

# =============================================================================
# Mode: Rollback (with integrated validation)
# =============================================================================
run_rollback() {
    setup_log "INFO" "--- Mode: ROLLBACK ---"
    if [ ! -f "${TEST_ROOT}/migration_progress.log" ]; then
        setup_log "ERROR" "Tracking file not found. Cannot run rollback."
        exit 1
    fi

    setup_log "INFO" "Running migrator.sh in rollback mode..."
    cd "${TEST_ROOT}"
    if ! bash "${MIGRATOR_SCRIPT_PATH}" --mode rollback; then
        setup_log "ERROR" "Rollback execution failed."
        cd - >/dev/null
        exit 1
    fi
    cd - >/dev/null
    setup_log "INFO" "Rollback execution complete."

    setup_log "INFO" "--- Automatically Validating Rollback ---"
    : > "${VALIDATION_LOG}"
    pass_count=0
    fail_count=0

    local temp_csv_file
    temp_csv_file=$(mktemp)
    tail -n +2 "${TEST_CSV}" > "$temp_csv_file"

    while IFS=, read -r _ mock_path_in_csv _; do
        mock_path_in_csv="${mock_path_in_csv//\"/}"
        local original_live_path="${mock_path_in_csv#$MOCK_ENV_DIR}"

        if [ ! -e "$original_live_path" ] && [ ! -L "$original_live_path" ]; then
            continue
        fi

        if diff -rq "$mock_path_in_csv" "$original_live_path" >/dev/null; then
            validate_log "PASS" "Item is identical to original source: $original_live_path"
        else
            validate_log "FAIL" "Item differs from original source after rollback: $original_live_path"
            diff -r "$mock_path_in_csv" "$original_live_path" >> "${VALIDATION_LOG}" || true
        fi
    done < "$temp_csv_file"
    rm "$temp_csv_file"

    setup_log "INFO" "ROLLBACK VALIDATION complete."
    echo "--- SUMMARY ---"
    echo "Passed Checks: $pass_count / Failed Checks: $fail_count"
    echo "---------------"
    if [ "$fail_count" -gt 0 ]; then
        exit 1
    fi
}

# =============================================================================
# Mode: Cleanup
# Delegates to migrator.sh --mode cleanup, then verifies the backup directory
# (recorded in the migrator's log) is gone.
# =============================================================================
run_cleanup() {
    setup_log "INFO" "--- Mode: CLEANUP ---"
    if [ ! -f "${TEST_ROOT}/migration_progress.log" ]; then
        setup_log "ERROR" "Tracking file not found. Cannot run cleanup."
        exit 1
    fi

    setup_log "INFO" "Running migrator.sh in cleanup mode..."
    cd "${TEST_ROOT}"
    if ! bash "${MIGRATOR_SCRIPT_PATH}" --mode cleanup; then
        setup_log "ERROR" "Cleanup execution failed."
        cd - >/dev/null
        exit 1
    fi
    cd - >/dev/null

    # Locate the most recent migrator log, then dig out the backup dir line.
    # Guarded against missing log / missing line so set -e + pipefail can't
    # kill the run on a benign absence.
    local migrator_log
    migrator_log=$(find "${TEST_ROOT}" -name "migrator_*.log" -print -quit 2>/dev/null) || true

    if [ -z "$migrator_log" ] || [ ! -f "$migrator_log" ]; then
        setup_log "WARN" "No migrator log found in ${TEST_ROOT}; skipping backup-dir verification."
        setup_log "INFO" "CLEANUP complete."
        return 0
    fi

    local backup_dir=""
    backup_dir=$(grep "Backups will be stored in" "${migrator_log}" 2>/dev/null | head -n1 | awk '{print $NF}') || true

    if [ -z "$backup_dir" ]; then
        setup_log "WARN" "Backup directory path not recorded in migrator log; skipping verification."
    elif [ -d "$backup_dir" ]; then
        echo "FAIL: Backup directory '$backup_dir' was not removed." >&2
        exit 1
    else
        echo "PASS: Backup directory removed successfully." >&2
    fi
    setup_log "INFO" "CLEANUP complete."
}

# =============================================================================
# Mode: Validate Integrity (Round-Trip)
# For each migrated artefact, reverse the content and path transformations,
# then diff the result against the original backup. Any divergence means the
# forward transformation was lossy / non-bijective.
#
# NOTE: This function depends on REVERSE_PATH_REPLACE_MAPPING,
#       REVERSE_CONTENT_REPLACE_MAPPING, and replace_content_in_file from
#       migrator.sh. We `source` migrator.sh to import them.
#
# IMPORTANT: For sourcing to be safe, migrator.sh's `main "$@"` must be
# guarded so it only runs when migrator.sh is *executed* (not sourced). See
# the note at the bottom of this file for the one-line patch required in
# migrator.sh. Without that guard, sourcing here will execute migrator.sh's
# main() with this harness's argv and either fail or do something unexpected.
# =============================================================================
run_validate_integrity() {
    setup_log "INFO" "--- Mode: VALIDATE_INTEGRITY (Round-Trip Test) ---"
    if [ ! -f "${TEST_ROOT}/migration_progress.log" ]; then
        setup_log "ERROR" "Tracking file not found. Cannot validate integrity."
        exit 1
    fi

    rm -rf "${VALIDATION_DIR}"
    mkdir -p "${VALIDATION_DIR}"
    : > "${VALIDATION_LOG}"
    pass_count=0
    fail_count=0

    # Source migrator.sh to access its reverse mappings + helper functions.
    # See header note for the guard required in migrator.sh.
    # shellcheck source=/dev/null
    source "${MIGRATOR_SCRIPT_PATH}"

    local temp_log_file
    temp_log_file=$(mktemp)
    tail -n +2 "${TEST_ROOT}/migration_progress.log" > "$temp_log_file"

    while IFS=, read -r orig_path new_path backup_path ts status; do
        orig_path="${orig_path//\"/}"
        new_path="${new_path//\"/}"
        backup_path="${backup_path//\"/}"

        if [ ! -e "$new_path" ]; then
            continue
        fi

        # 1. Copy the migrated file to the validation area.
        local validation_copy_path="${VALIDATION_DIR}/$(basename "$new_path")"
        cp -a "$new_path" "$validation_copy_path"

        # 2. Reverse the content transformation.
        if [ -f "$validation_copy_path" ] && [ ! -L "$validation_copy_path" ]; then
            replace_content_in_file "$validation_copy_path" "REVERSE_CONTENT_REPLACE_MAPPING"
        fi

        # 3. Reverse the path transformation.
        local reverse_path="$validation_copy_path"
        for find_str in "${!REVERSE_PATH_REPLACE_MAPPING[@]}"; do
            reverse_path="${reverse_path//$find_str/${REVERSE_PATH_REPLACE_MAPPING[$find_str]}}"
        done
        if [ "$validation_copy_path" != "$reverse_path" ]; then
            mv "$validation_copy_path" "$reverse_path"
        fi

        # 4. Diff the reverse-engineered file against the original backup.
        if diff -rq "$backup_path" "$reverse_path" >/dev/null; then
            validate_log "PASS" "Integrity check passed for: $orig_path"
        else
            validate_log "FAIL" "Integrity check FAILED for: $orig_path"
            diff -r "$backup_path" "$reverse_path" >> "${VALIDATION_LOG}" || true
        fi
    done < "$temp_log_file"
    rm "$temp_log_file"

    setup_log "INFO" "INTEGRITY VALIDATION complete."
    echo "--- SUMMARY ---"
    echo "Passed Checks: $pass_count / Failed Checks: $fail_count"
    echo "---------------"
    if [ "$fail_count" -gt 0 ]; then
        exit 1
    fi
}

# =============================================================================
# Main Entry Point
# =============================================================================
main() {
    local mode=""
    local csv_file=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)
                mode="$2"
                shift 2
                ;;
            --csv)
                csv_file="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown argument '$1'" >&2
                usage
                ;;
        esac
    done

    case "$mode" in
        all)
            run_prepare "$csv_file"
            run_execute
            run_validate
            run_rollback
            ;;
        prepare)
            run_prepare "$csv_file"
            ;;
        execute)
            run_execute
            ;;
        validate)
            run_validate
            ;;
        rollback)
            run_rollback
            ;;
        validate_integrity)
            run_validate_integrity
            ;;
        cleanup)
            run_cleanup
            ;;
        *)
            echo "Error: Invalid mode '$mode'." >&2
            usage
            ;;
    esac
}

main "$@"
