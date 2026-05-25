#!/bin/bash
# =============================================================================
#
# Script:      selective_copy.sh
#
# Description:
#   Performs a selective, two-stage copy to handle environments with split
#   user permissions where 'sudo' is not available. It supports regular files,
#   directories, and explicitly defined symbolic links.
#
#   MODE 1: --prepare
#     - Run by a user with read access to the source (e.g., xbapp_d1).
#     - Copies files and links to a temporary staging directory.
#     - Records original permissions and timestamps in a state file.
#     - Sets open permissions on staged files for the next stage.
#
#   MODE 2: --deploy
#     - Run by the target user (e.g., xbapp_d2).
#     - Deploys files and links from staging to the final destination.
#     - Creates symbolic links with their specified new targets.
#     - Restores original permissions and timestamps (lstat attributes).
#
# Usage:
#   ./selective_copy.sh --mode prepare
#   ./selective_copy.sh --mode deploy
#
# =============================================================================

# --- Script Safety and Rigor -------------------------------------------------
set -euo pipefail

# =============================================================================
#                                 CONFIGURATION
# =============================================================================

# --- Base Paths -------------------------------------------------------------
# The main source and target directories for the copy operation.
readonly SOURCE_BASE_DIR="/home/xbapp_d1"
readonly TARGET_BASE_DIR="/home/xbapp_d2"

# --- Staging Area -----------------------------------------------------------
# A shared temporary location for the two-stage process.
readonly STAGING_DIR="/tmp/selective_copy_stage"
readonly STATE_FILE="${STAGING_DIR}/permissions.state"

# --- File and Directory Mapping (regular files and directories ONLY) --------
readonly COPY_MAPPING=(
    "bulk-helm-opc|bulk-helm-opc/"
    "oradiag_xbapp_d1|oradiag_xbapp_d2/"
)

# --- Symbolic Link Mapping (Source Name | Destination Name | Destination Target)
readonly SYMBOLIC_LINK_MAPPING=()

# --- Exclusion Rules --------------------------------------------------------
# A list of rsync exclusion patterns. Each entry is a string in the format:
# "Source Name from COPY_MAPPING:relative_exclude_pattern"
# Example: "my_app/:logs/*" to exclude all files under the 'logs' directory within 'my_app/'.
readonly EXCLUDE_MAPPING=()

# --- Nested Item Transformations --------------------------------------------
# Defines how to find, rename, and/or retarget a specific file or link
# after its parent directory has been copied.
# Format: "Path to Original Item|New Name|New Link Target (for links only)"
readonly NESTED_ITEM_TRANSFORM=(
    "oradiag_xbapp_d2/diag/clients/user_xbapp_d1|user_xbapp_d2|"
)

# --- Logging ----------------------------------------------------------------
readonly LOG_FILE="selective_copy_$(date +'%Y%m%d_%H%M%S').log"

# =============================================================================
#                                  SCRIPT LOGIC
# =============================================================================

# --- Logging Function -------------------------------------------------------
log() {
    local level="$1"
    local message="$2"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ${level} - ${message}" | tee -a "${LOG_FILE}"
}

# --- Stage 1: Prepare -------------------------------------------------------
run_prepare() {
    log "INFO" "Starting PREPARE stage."

    log "INFO" "Checking status of staging directory: ${STAGING_DIR}"
    if [ -d "${STAGING_DIR}" ]; then
        if [ ! -w "${STAGING_DIR}" ] || [ ! -x "${STAGING_DIR}" ]; then
            log "FATAL" "Staging directory ${STAGING_DIR} exists but is not writable/executable. Please remove it manually (e.g., 'sudo rm -rf ${STAGING_DIR}') and re-run."
            return 1
        fi
        log "INFO" "Staging directory exists. Cleaning contents..."
        rm -rf "${STAGING_DIR:?}"/*
    else
        log "INFO" "Creating new staging directory: ${STAGING_DIR}"
        mkdir -p "${STAGING_DIR}"
        chmod 777 "${STAGING_DIR}"
    fi

    if [ ${#COPY_MAPPING[@]} -gt 0 ]; then
        log "INFO" "Staging regular files and directories..."
        for item_map in "${COPY_MAPPING[@]}"; do
            IFS='|' read -r src_name dest_name <<< "${item_map}"
            local full_src_path="${SOURCE_BASE_DIR}/${src_name}"
            local stage_dest_path="${STAGING_DIR}/${dest_name}"

            if [ ! -e "${full_src_path}" ]; then
                log "WARN" "Source path does not exist, skipping: ${full_src_path}"
                continue
            fi

            local rsync_exclude_args=()
            if [ ${#EXCLUDE_MAPPING[@]} -gt 0 ]; then
                for rule in "${EXCLUDE_MAPPING[@]}"; do
                    # Use a different separator for the inner read to avoid conflict with paths
                    IFS=':' read -r rule_src_name rule_pattern <<< "${rule}"
                    if [ "${rule_src_name}" == "${src_name}" ]; then
                        rsync_exclude_args+=(--exclude="${rule_pattern}")
                    fi
                done
            fi

            log "INFO" "Staging ${full_src_path} -> ${stage_dest_path}"
            local rsync_success=0
            if [ ${#rsync_exclude_args[@]} -gt 0 ]; then
                if ! rsync -a "${rsync_exclude_args[@]}" "${full_src_path}" "${stage_dest_path}"; then
                    rsync_success=1
                fi
            else
                if ! rsync -a "${full_src_path}" "${stage_dest_path}"; then
                    rsync_success=1
                fi
            fi

            if [ ${rsync_success} -ne 0 ]; then
                log "ERROR" "Failed to copy ${full_src_path} to ${stage_dest_path}. Check read permissions."
                return 1
            fi
        done
    fi

    if [ ${#SYMBOLIC_LINK_MAPPING[@]} -gt 0 ]; then
        log "INFO" "Staging symbolic links..."
        for item_map in "${SYMBOLIC_LINK_MAPPING[@]}"; do
            IFS='|' read -r src_link_name dest_link_name dest_link_target <<< "${item_map}"
            local full_src_path="${SOURCE_BASE_DIR}/${src_link_name}"
            local stage_dest_path="${STAGING_DIR}/${dest_link_name}"

            if [ ! -L "${full_src_path}" ]; then
                log "WARN" "Source path is not a symbolic link, skipping: ${full_src_path}"
                continue
            fi

            log "INFO" "Staging symlink ${full_src_path} -> ${stage_dest_path}"
            if ! rsync -a "${full_src_path}" "${stage_dest_path}"; then
                log "ERROR" "Failed to copy symlink ${full_src_path} to ${stage_dest_path}."
                return 1
            fi
        done
    fi

    log "INFO" "Generating permissions and timestamp state file: ${STATE_FILE}"
    find "${STAGING_DIR}" -print0 | xargs -0 stat -c "%a %Y %n" > "${STATE_FILE}"

    log "INFO" "Setting open permissions on staged files for deployment..."
    find "${STAGING_DIR}" -type d -exec chmod 755 {} +
    find "${STAGING_DIR}" -type f -exec chmod 644 {} +

    log "SUCCESS" "PREPARE stage completed."
}

# --- Stage 2: Deploy --------------------------------------------------------
run_deploy() {
    log "INFO" "Starting DEPLOY stage."

    if [ ! -d "${STAGING_DIR}" ]; then
        log "FATAL" "Staging directory not found: ${STAGING_DIR}. Please run the --prepare stage first."
        return 1
    fi

    if [ ${#COPY_MAPPING[@]} -gt 0 ]; then
        log "INFO" "Deploying regular files and directories..."
        for item_map in "${COPY_MAPPING[@]}"; do
            IFS='|' read -r src_name dest_name <<< "${item_map}"
            local stage_src_path="${STAGING_DIR}/${dest_name}"
            local final_dest_path="${TARGET_BASE_DIR}/${dest_name}"

            if [ ! -e "${stage_src_path}" ]; then
                log "WARN" "Staged item not found, skipping: ${stage_src_path}"
                continue
            fi

            if [ -d "${stage_src_path}" ]; then
                mkdir -p "${final_dest_path}"
                log "INFO" "Deploying directory contents: ${stage_src_path}/ -> ${final_dest_path}"
                if ! rsync -a "${stage_src_path}/" "${final_dest_path}"; then
                    log "ERROR" "Failed to deploy directory ${stage_src_path}."
                    return 1
                fi
            else
                mkdir -p "$(dirname "${final_dest_path}")"
                log "INFO" "Deploying file: ${stage_src_path} -> ${final_dest_path}"
                if ! rsync -a "${stage_src_path}" "${final_dest_path}"; then
                    log "ERROR" "Failed to deploy file ${stage_src_path}."
                    return 1
                fi
            fi
        done
    fi

    if [ ${#SYMBOLIC_LINK_MAPPING[@]} -gt 0 ]; then
        log "INFO" "Creating symbolic links at final destination..."
        for item_map in "${SYMBOLIC_LINK_MAPPING[@]}"; do
            IFS='|' read -r src_link_name dest_link_name dest_link_target <<< "${item_map}"
            local final_dest_path="${TARGET_BASE_DIR}/${dest_link_name}"

            log "INFO" "Creating symlink: ${final_dest_path} -> ${dest_link_target}"
            mkdir -p "$(dirname "${final_dest_path}")"
            ln -sf "${dest_link_target}" "${final_dest_path}"
        done
    fi

    if [ ${#NESTED_ITEM_TRANSFORM[@]} -gt 0 ]; then
        log "INFO" "Performing nested item transformations..."
        for item_transform in "${NESTED_ITEM_TRANSFORM[@]}"; do
            IFS='|' read -r original_rel_path new_name new_target <<< "${item_transform}"
            local original_full_path="${TARGET_BASE_DIR}/${original_rel_path}"
            local new_full_path
            new_full_path="$(dirname "${original_full_path}")/${new_name}"

            if [ ! -e "${original_full_path}" ] && [ ! -L "${original_full_path}" ]; then
                log "WARN" "Nested item to transform not found, skipping: ${original_full_path}"
                continue
            fi

            if [ -z "${new_target}" ]; then
                # This is a file rename
                log "INFO" "Renaming nested file: ${original_full_path} -> ${new_full_path}"
                if ! mv "${original_full_path}" "${new_full_path}"; then
                    log "ERROR" "Failed to rename nested file."
                    return 1
                fi
            else
                # This is a symbolic link rename and retarget
                # Find original timestamp from state file. The `|| true` keeps set -e
                # from killing the script when grep finds no match — empty result is a
                # valid outcome that the downstream `-z` check handles. `-F` makes the
                # pattern a fixed string so path metacharacters aren't treated as regex.
                local staged_path_for_stat="${STAGING_DIR}/${original_rel_path}"
                local original_timestamp
                original_timestamp=$(grep -F "${staged_path_for_stat}" "${STATE_FILE}" | awk '{print $2}' || true)

                if [ -z "${original_timestamp}" ]; then
                    log "WARN" "Could not find original timestamp for ${original_rel_path}, skipping timestamp preservation."
                    # Just create the link without restoring timestamp
                    log "INFO" "Transforming nested link: ${new_full_path} -> ${new_target}"
                    rm -f "${original_full_path}"
                    if ! ln -s "${new_target}" "${new_full_path}"; then
                        log "ERROR" "Failed to transform nested link."
                        return 1
                    fi
                else
                    # Create the link and restore the timestamp
                    log "INFO" "Transforming nested link (with timestamp): ${new_full_path} -> ${new_target}"
                    rm -f "${original_full_path}"
                    if ! ln -s "${new_target}" "${new_full_path}"; then
                        log "ERROR" "Failed to transform nested link."
                        return 1
                    fi
                    if ! touch -h -d "@${original_timestamp}" "${new_full_path}"; then
                        log "WARN" "Failed to restore timestamp on transformed link: ${new_full_path}"
                    fi
                fi
            fi
        done
    fi

    log "INFO" "Restoring original permissions and timestamps from state file..."
    if [ ! -f "${STATE_FILE}" ]; then
        log "FATAL" "Permissions state file not found: ${STATE_FILE}. Cannot restore permissions."
        return 1
    fi

    while IFS= read -r line; do
        local perm timestamp staged_path
        perm=$(echo "$line" | awk '{print $1}')
        timestamp=$(echo "$line" | awk '{print $2}')
        staged_path=$(echo "$line" | cut -d' ' -f3-)

        local final_path="${staged_path#${STAGING_DIR}}"  # Remove staging dir prefix
        final_path="${TARGET_BASE_DIR}${final_path}"

        # Skip any items that were handled by the nested transform logic, as they may have new names
        local was_transformed=false
        if [ ${#NESTED_ITEM_TRANSFORM[@]} -gt 0 ]; then
            for item_transform in "${NESTED_ITEM_TRANSFORM[@]}"; do
                IFS='|' read -r original_rel_path new_name new_target <<< "${item_transform}"
                if [ "${final_path}" == "${TARGET_BASE_DIR}/${original_rel_path}" ]; then
                    was_transformed=true
                    break
                fi
            done
        fi

        if [ "$was_transformed" = true ]; then
            log "INFO" "Skipping attribute restoration for already transformed item: ${final_path}"
            continue
        fi

        if [ -e "${final_path}" ] || [ -L "${final_path}" ]; then
            if [ -L "${final_path}" ]; then
                log "INFO" "Restoring timestamp on symlink: ${final_path}"
                if ! touch -h -d "@${timestamp}" "${final_path}"; then
                    log "WARN" "Failed to restore timestamp on symlink: ${final_path}"
                fi
            else
                log "INFO" "Restoring perm ${perm} and timestamp on ${final_path}"
                if ! chmod "${perm}" "${final_path}"; then
                    log "WARN" "Failed to restore permissions on: ${final_path}"
                fi
                if ! touch -d "@${timestamp}" "${final_path}"; then
                    log "WARN" "Failed to restore timestamp on: ${final_path}"
                fi
            fi
        else
            log "WARN" "Cannot restore attributes, path not found: ${final_path}"
        fi
    done < "${STATE_FILE}"

    log "SUCCESS" "DEPLOY stage completed successfully."
}

# --- Main Function ----------------------------------------------------------
main() {
    # Prevent running as root
    if [ "$(id -u)" -eq 0 ]; then
        log "FATAL" "This script should not be run as root. Run it as the appropriate user for each stage."
        exit 1
    fi

    # Argument parsing
    if [ "$#" -ne 2 ] || [ "$1" != "--mode" ]; then
        echo "Usage: $0 --mode [prepare|deploy]"
        exit 1
    fi
    local mode="$2"

    log "INFO" "Script started in --mode ${mode}"

    case "$mode" in
        prepare)
            run_prepare
            ;;
        deploy)
            run_deploy
            ;;
        *)
            log "FATAL" "Invalid mode: '${mode}'. Use 'prepare' or 'deploy'."
            exit 1
            ;;
    esac
}

# --- Script Entry Point -----------------------------------------------------
# `if ! main` disables set -e for the main call so the FATAL handler runs
# instead of the script being killed silently at the first inner failure.
if ! main "$@"; then
    log "FATAL" "Script terminated due to a critical error."
    exit 1
fi
