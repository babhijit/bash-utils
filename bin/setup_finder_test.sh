#!/bin/bash
# =============================================================================
#
# Script:      setup_finder_test.sh
#
# Description:
#   Sets up a mock environment in /tmp to test the case-insensitive and
#   symlink-following features of the 'finder.sh' script.
#
# Usage:
#   1. Run this script: ./setup_finder_test.sh
#   2. Follow the on-screen instructions to run the tests.
#
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
readonly TEST_ROOT="/tmp/finder_test"

# --- Main Function -----------------------------------------------------------
main() {
    echo "--- Setting up test environment in ${TEST_ROOT} ---"

    # 1. Clean up and create directory structure
    echo "Creating clean directory structure..."
    rm -rf "${TEST_ROOT}"
    mkdir -p "${TEST_ROOT}/real_dir"
    mkdir -p "${TEST_ROOT}/real_dir/nested"

    # 2. Create mock files and directories for testing
    echo "Creating mock files with mixed-case names and content..."

    # For name search test (one outside, one inside the linked dir)
    touch "${TEST_ROOT}/file_with_FAT1_in_name.txt"
    touch "${TEST_ROOT}/real_dir/nested/another_file_opc_d1"

    # For content search test (one outside, one inside the linked dir)
    echo "This file contains the string FAT1 in mixed case." > "${TEST_ROOT}/content1.txt"
    echo "And this one has opcSVCF1." > "${TEST_ROOT}/real_dir/nested/content2.log"
    echo "A file with no matches." > "${TEST_ROOT}/no_match.txt"

    # 3. Create a symbolic link to test traversal
    echo "Creating symbolic link to test traversal..."
    ln -s "${TEST_ROOT}/real_dir" "${TEST_ROOT}/linked_dir"

    echo ""
    echo "--- Test Environment Ready ---"
    echo "Test directory state:"
    ls -LR "${TEST_ROOT}"
    echo "--------------------------------"
    echo ""
    echo "INSTRUCTIONS:"
    echo "The finder.sh script is already configured. The search will start"
    echo "from '${TEST_ROOT}' and should now follow the 'linked_dir' symlink."
    echo ""
    echo "1. Test NAME search (should find 2 items, one via symlink):"
    echo "   bash ./finder.sh --mode name --dir \"${TEST_ROOT}\""
    echo ""
    echo "   EXPECTED OUTPUT (paths will vary):"
    echo '   "file_with_FAT1_in_name.txt",...,"fat1"'
    echo '   "another_file_opc_d1",...,"opc_d1"'
    echo ""
    echo "2. Test CONTENT search (should find 2 items, one via symlink):"
    echo "   bash ./finder.sh --mode content --dir \"${TEST_ROOT}\""
    echo ""
    echo "   EXPECTED OUTPUT (paths will vary):"
    echo '   "content1.txt",...,"fat1"'
    echo '   "content2.log",...,"opcsvcf1"'
    echo ""
    echo "3. When finished, clean up the environment:"
    echo "   rm -rf \"${TEST_ROOT}\""
    echo "--------------------------------"
}

# --- Script Entry Point ------------------------------------------------------
main
