#!/bin/bash
# =============================================================================
#
# Script:      migrator.sh (Definitive Version)
#
# Description:
#   A stateful, in-place migration script with backup, rollback, and cleanup.
#   This version uses robust file-reading patterns to prevent common bugs.
#
# =============================================================================

# --- Script Safety and Rigor -------------------------------------------------
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
    echo "Error: This script requires Bash version 4.2 or higher. Found: ${BASH_VERSION}." >&2
    exit 1
fi
set -euo pipefail

# =============================================================================
#                                 CONFIGURATION
# =============================================================================

# --- Forward Mappings --------------------------------------------------------
# NOTE: -Ar = associative + readonly in one flag bundle. The previous form
# `declare -A readonly NAME=(...)` was a latent bug: bash parsed `readonly`
# as a separate variable name, so NAME was never actually readonly and a
# stray empty array literally called `readonly` got declared instead.
declare -Ar PATH_REPLACE_MAPPING=(
    ["FAT1"]="FAT2"
    ["fat1"]="fat2"
    ["opc_d1"]="opc_d2"
    ["xbapp_d1"]="xbapp_d2"
    ["opcsvcf1"]="opcsvcf2"
)
declare -Ar CONTENT_REPLACE_MAPPING=(
    ["FAT1"]="FAT2"
    ["fat1"]="fat2"
    ["opcsvcf1"]="opcsvcf2"
    ["opc_d1"]="opc_d2"
    ["xbapp_d1"]="xbapp_d2"
)

# --- Reverse Mappings (for validation) ---------------------------------------
declare -Ar REVERSE_PATH_REPLACE_MAPPING=(
    ["FAT2"]="FAT1"
    ["fat2"]="fat1"
    ["opc_d2"]="opc_d1"
    ["xbapp_d2"]="xbapp_d1"
    ["opcsvcf2"]="opcsvcf1"
)
declare -Ar REVERSE_CONTENT_REPLACE_MAPPING=(
    ["FAT2"]="FAT1"
    ["fat2"]="fat1"
    ["opcsvcf2"]="opcsvcf1"
    ["opc_d2"]="opc_d1"
    ["xbapp_d2"]="xbapp_d1"
)

# =============================================================================
#                                  SCRIPT LOGIC
# =============================================================================

LOG_FILE="migrator_$(date +'%Y%m%d_%H%M%S').log"
TRACKING_FILE="migration_progress.log"
BACKUP_DIR="/tmp/migrator_backups_$(date +'%Y%m%d_%H%M%S')"

log() {
    local level="$1"
    local message="$2"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ${level} - ${message}" | tee -a "${LOG_FILE}"
}

usage() {
    echo "Usage: $0 --mode <execute|rollback|cleanup> --csv <input.csv> [options]"
    exit 1
}

# -----------------------------------------------------------------------------
# replace_content_in_file <TARGET_FILE> <ARRAY_NAME>
# Replace every occurrence of each key in the named associative array with its
# value, in $TARGET_FILE. Uses eval-based indirection because bash 4.2 lacks
# `declare -n` (namerefs require 4.3+).
# -----------------------------------------------------------------------------
replace_content_in_file() {
    local target_file="$1"
    local array_name_str="$2"  # The name of the associative array to use

    # Fetch keys of the named associative array (portable to bash 4.2).
    # Outer shell expands ${array_name_str}; eval handles the ${!ARR[@]} part.
    local keys
    eval "keys=( \"\${!${array_name_str}[@]}\" )"

    if [ ${#keys[@]} -eq 0 ]; then
        return 0
    fi

    if [ ! -f "$target_file" ] || [ -L "$target_file" ]; then
        return 0
    fi

    log "INFO" "Content Replace: Starting on $target_file using '$array_name_str'"
    local sed_expressions=()
    local key value
    for key in "${keys[@]}"; do
        eval "value=\${${array_name_str}[\"\$key\"]}"
        sed_expressions+=(-e "s|${key}|${value}|g")
    done

    local tmp_file; tmp_file=$(mktemp)
    if ! sed "${sed_expressions[@]}" "$target_file" > "$tmp_file"; then
        log "ERROR" "Content Replace: sed command failed on $target_file."
        rm -f "$tmp_file"
        return 1
    fi

    mv "$tmp_file" "$target_file"
}

# --- Mode: Execute -----------------------------------------------------------
run_execute() {
    local csv_file="$1"
    log "INFO" "Mode: EXECUTE. Starting migration."
    log "INFO" "Backups will be stored in: ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}"

    declare -A completed_paths
    if [ -f "$TRACKING_FILE" ]; then
        log "INFO" "Reading existing tracking file: $TRACKING_FILE"

        local temp_log_file
        temp_log_file=$(mktemp)
        tail -n +2 "$TRACKING_FILE" > "$temp_log_file"

        while IFS=, read -r path _ _ _ status; do
            path="${path//\"/}"
            status="${status//\"/}"
            if [ "$status" == "COMPLETED" ]; then
                completed_paths["$path"]=1
            fi
        done < "$temp_log_file"
        rm "$temp_log_file"

        log "INFO" "Found ${#completed_paths[@]} previously completed entries to skip."
    else
        log "INFO" "No tracking file found. Starting a new migration."
        echo "Original_Path,New_Path,Backup_Path,Original_Timestamp,Status" > "$TRACKING_FILE"
    fi

    local line_count=0
    local processed_count=0

    local temp_csv_file
    temp_csv_file=$(mktemp)
    tail -n +2 "$csv_file" | awk -F, '!seen[$2]++' > "$temp_csv_file"

    while IFS=, read -r name absolute_path last_modified; do
        name="${name//\"/}"
        absolute_path="${absolute_path//\"/}"
        last_modified="${last_modified//\"/}"
        absolute_path="${absolute_path%$'\r'}"

        line_count=$((line_count + 1))
        echo -ne "Processing entry $line_count: $name\r" >&2

        if [ -n "${completed_paths[$absolute_path]:-}" ]; then
            continue
        fi
        if [ ! -e "$absolute_path" ] && [ ! -L "$absolute_path" ]; then
            log "WARN" "SKIP: Source path not found: $absolute_path"
            continue
        fi

        local new_path="$absolute_path"
        for find_str in "${!PATH_REPLACE_MAPPING[@]}"; do
            new_path="${new_path//$find_str/${PATH_REPLACE_MAPPING[$find_str]}}"
        done
        local backup_path="${BACKUP_DIR}/$(basename "$absolute_path")_$(date +%s)"

        if ! cp -a "$absolute_path" "$backup_path"; then
            log "ERROR" "BACKUP failed for '$absolute_path'. Halting."; exit 1
        fi

        local backed_up_line="\"$absolute_path\",\"$new_path\",\"$backup_path\",\"$last_modified\",\"BACKED_UP\""
        echo "$backed_up_line" >> "$TRACKING_FILE"

        if [ -L "$absolute_path" ]; then
            log "INFO" "Processing Symlink: $absolute_path"
            local old_target; old_target=$(readlink "$absolute_path")
            local new_target="$old_target"
            for find_str in "${!PATH_REPLACE_MAPPING[@]}"; do
                new_target="${new_target//$find_str/${PATH_REPLACE_MAPPING[$find_str]}}"
            done

            rm "$absolute_path"
            ln -s "$new_target" "$absolute_path"
            log "INFO" "Symlink Target Updated: -> $new_target"

            if [ "$absolute_path" != "$new_path" ]; then
                mv "$absolute_path" "$new_path"
                log "INFO" "Symlink Renamed: -> $new_path"
            fi
        elif [ -d "$absolute_path" ]; then
            log "INFO" "Processing Directory: $absolute_path"
            if [ "$absolute_path" != "$new_path" ]; then
                mv "$absolute_path" "$new_path"
                log "INFO" "Directory Renamed: -> $new_path"
            fi
            # Process substitution (not pipe) keeps the loop in this shell.
            while IFS= read -r -d '' file_in_dir; do
                replace_content_in_file "$file_in_dir" "CONTENT_REPLACE_MAPPING"
            done < <(find "$new_path" -type f -print0)
        elif [ -f "$absolute_path" ]; then
            log "INFO" "Processing File: $absolute_path"
            replace_content_in_file "$absolute_path" "CONTENT_REPLACE_MAPPING"
            if [ "$absolute_path" != "$new_path" ]; then
                mv "$absolute_path" "$new_path"
                log "INFO" "File Renamed: -> $new_path"
            fi
        fi

        local final_path="$new_path"
        if ! touch -h -d "$last_modified" "$final_path"; then
            log "WARN" "Timestamp restore failed for: $final_path"
        fi

        local temp_tracking_file; temp_tracking_file=$(mktemp)
        local completed_line="\"$absolute_path\",\"$new_path\",\"$backup_path\",\"$last_modified\",\"COMPLETED\""
        # grep -v exits 1 if every line matches (zero survive). Guard so
        # set -e + pipefail can't kill us on that edge case.
        grep -vF "$backed_up_line" "$TRACKING_FILE" > "$temp_tracking_file" || true
        echo "$completed_line" >> "$temp_tracking_file"
        mv "$temp_tracking_file" "$TRACKING_FILE"

        log "SUCCESS" "COMPLETED: $absolute_path"
        processed_count=$((processed_count + 1))
    done < "$temp_csv_file"
    rm "$temp_csv_file"

    echo -ne "\033[2K\r" >&2
    log "INFO" "EXECUTE mode finished. Processed $processed_count new entries."
}

# --- Other modes (rollback, cleanup) -----------------------------------------
run_rollback() {
    log "INFO" "Mode: ROLLBACK. Reverting changes from tracking file."
    if [ ! -f "$TRACKING_FILE" ]; then
        log "ERROR" "Tracking file not found. Cannot rollback."
        exit 1
    fi

    local reverse_cmd
    if command -v tac >/dev/null; then
        reverse_cmd="tac"
    else
        reverse_cmd="tail -r"
    fi

    local temp_log_file
    temp_log_file=$(mktemp)
    $reverse_cmd "$TRACKING_FILE" | grep -v "Original_Path,New_Path,Backup_Path,Original_Timestamp,Status" > "$temp_log_file" || true

    while IFS=, read -r orig_path new_path backup_path ts status; do
        orig_path="${orig_path//\"/}"
        new_path="${new_path//\"/}"
        backup_path="${backup_path//\"/}"

        log "INFO" "Rollback: Examining entry for '$orig_path'"
        if [ -e "$new_path" ] || [ ! -e "$orig_path" ]; then
            log "INFO" "Action: Restoring '$orig_path' from '$backup_path'"
            rm -rf "$new_path"
            if ! cp -a "$backup_path" "$orig_path"; then
                log "ERROR" "ROLLBACK FAILED for '$orig_path'. Manual intervention may be required."
            else
                log "SUCCESS" "Rolled back '$orig_path'"
            fi
        else
            log "INFO" "Skip: '$orig_path' appears to be in its original state."
        fi
    done < "$temp_log_file"
    rm "$temp_log_file"
    log "INFO" "ROLLBACK mode finished."
}

run_cleanup() {
    log "INFO" "Mode: CLEANUP. Removing backup files."
    if [ ! -f "$TRACKING_FILE" ]; then
        log "ERROR" "Tracking file not found. Cannot clean up."
        exit 1
    fi

    local temp_log_file
    temp_log_file=$(mktemp)
    tail -n +2 "$TRACKING_FILE" > "$temp_log_file"

    while IFS=, read -r _ _ backup_path _; do
        backup_path="${backup_path//\"/}"
        if [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
            log "INFO" "Removing backup: $backup_path"
            rm -rf "$backup_path"
        fi
    done < "$temp_log_file"
    rm "$temp_log_file"

    # Resolve the actual backup directory used at execute-time from the log.
    # Guarded against missing log file and missing "Backups will be stored in"
    # line so set -e + pipefail can't kill us on a benign absence.
    local backup_dir_from_log=""
    if [ -f "${LOG_FILE}" ]; then
        backup_dir_from_log=$(grep "Backups will be stored in" "${LOG_FILE}" | head -n1 | awk '{print $NF}') || true
    fi
    # FIX: previous form was `[ -d "$x" ] && [ -d "$x" ]` — same check twice.
    # Intent was non-empty AND is-a-directory.
    if [ -n "$backup_dir_from_log" ] && [ -d "$backup_dir_from_log" ]; then
        rmdir "$backup_dir_from_log" 2>/dev/null || log "INFO" "Backup directory '$backup_dir_from_log' not empty, leaving as is."
    fi
    log "INFO" "CLEANUP mode finished."
}

# =============================================================================
#                                 Main Entry Point
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
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            --tracking-file)
                TRACKING_FILE="$2"
                shift 2
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown argument '$1'" >&2
                usage
                ;;
        esac
    done

    if [ -z "$mode" ]; then
        echo "Error: --mode is required." >&2
        usage
    fi
    if [[ "$mode" == "execute" && -z "$csv_file" ]]; then
        echo "Error: --csv is required for execute mode." >&2
        usage
    fi

    case "$mode" in
        execute)
            run_execute "$csv_file"
            ;;
        rollback)
            run_rollback
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

# FIX: Only run main when this script is *executed*, not when it's sourced.
# setup_migrator_test.sh sources this file in validate_integrity mode to
# pull in the REVERSE_*_MAPPING arrays and replace_content_in_file(). Without
# this guard, sourcing would immediately fire main() with the sourcing
# script's argv, fail mode validation, and exit 1 — killing the caller.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
