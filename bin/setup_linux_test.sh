#!/bin/bash
# =============================================================================
#
# Script:      setup_linux_test.sh
#
# Description:
#   Sets up a comprehensive, self-contained mock environment in /tmp to
#   safely test all features of the 'selective_copy.sh' script.
#
# Usage:
#   1. Run this script: ./setup_linux_test.sh
#   2. Follow the on-screen instructions precisely.
#
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
readonly TEST_ROOT="/tmp/selective_copy_test"
readonly SOURCE_DIR="${TEST_ROOT}/source"
readonly TARGET_DIR="${TEST_ROOT}/target"
readonly OLD_TIMESTAMP="200501010101.01" # Jan 1, 2005

# --- Main Function -----------------------------------------------------------
main() {
    echo "--- Setting up comprehensive Linux test environment in ${TEST_ROOT} ---"

    # 1. Clean up and create directory structure
    echo "Creating clean directory structure..."
    rm -rf "${TEST_ROOT}"
    mkdir -p "${SOURCE_DIR}"
    mkdir -p "${TARGET_DIR}"

    # 2. Create a complex source environment to test all features
    echo "Creating mock source files and directories..."

    # For basic directory copy
    mkdir -p "${SOURCE_DIR}/dir_to_copy"
    echo "basic dir content" > "${SOURCE_DIR}/dir_to_copy/file.txt"

    # For directory copy with exclusions
    mkdir -p "${SOURCE_DIR}/dir_with_exclusions"
    echo "should be copied" > "${SOURCE_DIR}/dir_with_exclusions/include.txt"
    echo "should be excluded" > "${SOURCE_DIR}/dir_with_exclusions/exclude.log"
    mkdir -p "${SOURCE_DIR}/dir_with_exclusions/tmp"
    echo "in excluded tmp dir" > "${SOURCE_DIR}/dir_with_exclusions/tmp/file.txt"

    # For top-level symbolic link
    ln -s "points/to/old/target.conf" "${SOURCE_DIR}/top_level_link.conf"

    # For nested item transformations
    mkdir -p "${SOURCE_DIR}/dir_with_nested_items/path/to"
    echo "this file will be renamed" > "${SOURCE_DIR}/dir_with_nested_items/path/to/file_to_rename.txt"
    mkdir -p "${SOURCE_DIR}/dir_with_nested_items/another/path"
    ln -s "../../old_nested_target" "${SOURCE_DIR}/dir_with_nested_items/another/path/link_to_transform"

    # 3. Set all source files to an old, specific timestamp
    echo "Setting all source items to an old timestamp (${OLD_TIMESTAMP})..."
    find "${SOURCE_DIR}" -print0 | xargs -0 touch -h -t "${OLD_TIMESTAMP}"

    echo ""
    echo "--- Test Environment Ready ---"
    echo "Source directory state:"
    ls -lR "${SOURCE_DIR}"
    echo "--------------------------------"
    echo ""
    echo "INSTRUCTIONS:"
    echo "1. Make a backup of your original script:"
    echo "   cp selective_copy.sh selective_copy.sh.bak"
    echo ""
    echo "2. Modify 'selective_copy.sh' to use the test configuration. Run this ENTIRE block:"
    echo '
# Set base paths
sed -i "s|readonly SOURCE_BASE_DIR=.*|readonly SOURCE_BASE_DIR=\"'"${SOURCE_DIR}"'\"|" selective_copy.sh
sed -i "s|readonly TARGET_BASE_DIR=.*|readonly TARGET_BASE_DIR=\"'"${TARGET_DIR}"'\"|" selective_copy.sh

# Overwrite mapping arrays for the test
cat <<EOF > /tmp/mappings.tmp
readonly COPY_MAPPING=(
    "dir_to_copy/|dir_to_copy/"
    "dir_with_exclusions/|dir_with_exclusions/"
    "dir_with_nested_items/|dir_with_nested_items/"
)
readonly SYMBOLIC_LINK_MAPPING=(
    "top_level_link.conf|top_level_link.conf|points/to/new/target.conf"
)
readonly EXCLUDE_MAPPING=(
    "dir_with_exclusions/:*.log"
    "dir_with_exclusions/:tmp/"
)
readonly NESTED_ITEM_TRANSFORM=(
    "dir_with_nested_items/path/to/file_to_rename.txt|file_was_renamed.txt|"
    "dir_with_nested_items/another/path/link_to_transform|link_was_transformed|../../new_nested_target"
)
EOF
# This is a trick to replace the content between two markers
sed -i "/^# --- File and Directory Mapping/,/^# --- Logging ---/{
    /^# --- File and Directory Mapping/r /tmp/mappings.tmp
    d
}" selective_copy.sh
rm /tmp/mappings.tmp
'
    echo ""
    echo "3. Run the selective copy script (as a non-root user):"
    echo "   bash ./selective_copy.sh --mode prepare"
    echo "   bash ./selective_copy.sh --mode deploy"
    echo ""
    echo "4. Verify the results. Check names, targets, and timestamps (should be from 2005)."
    echo "   ls -lR \"${TARGET_DIR}\""
    echo ""
    echo "   # Specifically check the transformed nested link target:"
    echo "   readlink \"${TARGET_DIR}/dir_with_nested_items/another/path/link_was_transformed\""
    echo ""
    echo "5. When finished, clean up the environment and restore your script:"
    echo "   rm -rf \"${TEST_ROOT}\""
    echo "   mv selective_copy.sh.bak selective_copy.sh"
    echo "--------------------------------"
}

# --- Script Entry Point ------------------------------------------------------
main
