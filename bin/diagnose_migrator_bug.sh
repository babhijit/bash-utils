#!/bin/bash
# =============================================================================
#
# Script:      diagnose_migrator_bug.sh
#
# Description:
#   Read-only diagnostic. Gathers evidence about why migrator.sh reports
#   "Source path not found" for paths that setup_migrator_test.sh logged
#   as successfully copied. Writes a single report file. Makes NO changes
#   to disk.
#
# Usage:
#   ./diagnose_migrator_bug.sh [--input-csv PATH] [--test-root PATH] [--probe SUBSTR]
#
#   Defaults:
#     --input-csv  ./fat2.csv
#     --test-root  /tmp/test_f2/migration_test
#     --probe      mq-opcsvcf1
#
# When to run:
#   After running `setup_migrator_test.sh --mode prepare` (or `--mode all`),
#   BEFORE cleanup. The mock environment under TEST_ROOT must exist for the
#   filesystem inspection to be meaningful.
#
# Output:
#   /tmp/migrator_diagnosis_<timestamp>.txt
#   Read that file (or hand it to local Claude Code) to identify the bug.
#
# =============================================================================

set -uo pipefail   # NB: deliberately NOT -e — a diagnostic should keep going
                   # even when individual probes fail. We want all the data.

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
INPUT_CSV="./fat2.csv"
TEST_ROOT="/tmp/test_f2/migration_test"
PROBE="mq-opcsvcf1"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --input-csv) INPUT_CSV="$2"; shift 2 ;;
        --test-root) TEST_ROOT="$2"; shift 2 ;;
        --probe)     PROBE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

MOCK_ENV_DIR="${TEST_ROOT}/environment_to_migrate"
TEST_CSV="${TEST_ROOT}/test_input.csv"
SETUP_LOG="${TEST_ROOT}/setup_migration.log"
REPORT="/tmp/migrator_diagnosis_$(date +%Y%m%d_%H%M%S).txt"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
section() {
    {
        echo
        echo "============================================================================"
        echo "  $1"
        echo "============================================================================"
    } | tee -a "$REPORT"
}

note() {
    echo "$@" | tee -a "$REPORT"
}

run() {
    # Echo the command, then run it, capturing both stdout and stderr.
    {
        echo
        echo "\$ $*"
    } | tee -a "$REPORT"
    "$@" 2>&1 | tee -a "$REPORT"
    local rc="${PIPESTATUS[0]}"
    if [ "$rc" -ne 0 ]; then
        echo "  (exit $rc)" | tee -a "$REPORT"
    fi
}

# ---------------------------------------------------------------------------
# 0. Header
# ---------------------------------------------------------------------------
: > "$REPORT"
section "DIAGNOSTIC RUN — $(date '+%Y-%m-%d %H:%M:%S')"
note "Host:       $(hostname)"
note "User:       $(id -un) (uid=$(id -u), gid=$(id -g))"
note "Bash:       ${BASH_VERSION}"
note "PWD:        $(pwd)"
note "INPUT_CSV:  $INPUT_CSV"
note "TEST_ROOT:  $TEST_ROOT"
note "PROBE:      $PROBE"
note "Report at:  $REPORT"

# ---------------------------------------------------------------------------
# 1. Sanity — do the key paths even exist?
# ---------------------------------------------------------------------------
section "1. EXISTENCE CHECKS"
for p in "$INPUT_CSV" "$TEST_ROOT" "$MOCK_ENV_DIR" "$TEST_CSV" "$SETUP_LOG"; do
    if [ -e "$p" ]; then
        note "FOUND     $p  ($(stat -c '%F, %s bytes, owner %U:%G, perms %a' "$p" 2>/dev/null))"
    else
        note "MISSING   $p"
    fi
done

# ---------------------------------------------------------------------------
# 2. Filesystem state under the probe
# ---------------------------------------------------------------------------
section "2. MOCK FILESYSTEM TREE UNDER PROBE ($PROBE)"
note "Everything in the mock env whose path matches '$PROBE':"
if [ -d "$MOCK_ENV_DIR" ]; then
    find "$MOCK_ENV_DIR" -path "*${PROBE}*" -printf "%y %M %u:%g %10s  %p\n" 2>/dev/null \
        | sort -k5 | tee -a "$REPORT"
else
    note "(mock env directory does not exist)"
fi

# ---------------------------------------------------------------------------
# 3. Test CSV rows matching probe
# ---------------------------------------------------------------------------
section "3. TEST CSV ROWS MATCHING PROBE"
if [ -f "$TEST_CSV" ]; then
    note "(format written by setup: Name,Absolute_Path,Last_Modified)"
    note ""
    note "--- header ---"
    head -1 "$TEST_CSV" | tee -a "$REPORT"
    note ""
    note "--- matching rows ---"
    grep -F "$PROBE" "$TEST_CSV" | tee -a "$REPORT" | wc -l \
        | awk '{print "(" $1 " matching row(s))"}' | tee -a "$REPORT"
    note ""
    note "--- hex dump of matching rows (look for stray \\r, NULs, or non-ASCII) ---"
    grep -F "$PROBE" "$TEST_CSV" | od -c | head -40 | tee -a "$REPORT"
else
    note "(test CSV does not exist — has setup --mode prepare run?)"
fi

# ---------------------------------------------------------------------------
# 4. Input CSV rows matching probe
# ---------------------------------------------------------------------------
section "4. INPUT CSV ROWS MATCHING PROBE"
if [ -f "$INPUT_CSV" ]; then
    note "(this is what was handed to setup --mode prepare)"
    note ""
    note "--- header ---"
    head -1 "$INPUT_CSV" | tee -a "$REPORT"
    note ""
    note "--- matching rows ---"
    grep -F "$PROBE" "$INPUT_CSV" | tee -a "$REPORT" | wc -l \
        | awk '{print "(" $1 " matching row(s))"}' | tee -a "$REPORT"
    note ""
    note "--- field count distribution (rows split by comma) ---"
    grep -F "$PROBE" "$INPUT_CSV" \
        | awk -F, '{ print NF }' | sort | uniq -c | tee -a "$REPORT"
    note ""
    note "--- hex dump of matching rows (look for trailing \\r, embedded commas in paths, NULs) ---"
    grep -F "$PROBE" "$INPUT_CSV" | od -c | head -60 | tee -a "$REPORT"
else
    note "(input CSV does not exist at $INPUT_CSV)"
fi

# ---------------------------------------------------------------------------
# 5. Per-path filesystem probe
# ---------------------------------------------------------------------------
section "5. PER-PATH FILESYSTEM PROBE — each path the test CSV claims exists"
note "For each Absolute_Path field in test CSV matching probe, check disk state."
note ""
if [ -f "$TEST_CSV" ]; then
    # Extract the second CSV field, strip surrounding quotes, strip any trailing \r.
    grep -F "$PROBE" "$TEST_CSV" \
        | awk -F'","' '{ gsub(/^"/, "", $1); gsub(/"$/, "", $NF); print $2 }' \
        | tr -d '\r' \
        | while IFS= read -r p; do
            note "--- $p"
            if [ -e "$p" ] || [ -L "$p" ]; then
                ls -ld "$p" 2>&1 | tee -a "$REPORT"
                note "    [-e]=$([ -e "$p" ] && echo y || echo n)  " \
                     "[-f]=$([ -f "$p" ] && echo y || echo n)  " \
                     "[-d]=$([ -d "$p" ] && echo y || echo n)  " \
                     "[-L]=$([ -L "$p" ] && echo y || echo n)"
            else
                note "    DOES NOT EXIST ON DISK"
                # Walk up and find the first ancestor that does exist.
                anc="$p"
                while [ "$anc" != "/" ] && [ ! -e "$anc" ]; do
                    anc=$(dirname "$anc")
                done
                note "    first existing ancestor: $anc"
                if [ -d "$anc" ]; then
                    note "    contents of that ancestor:"
                    ls -la "$anc" 2>&1 | sed 's/^/      /' | tee -a "$REPORT"
                fi
            fi
        done
else
    note "(no test CSV to probe from)"
fi

# ---------------------------------------------------------------------------
# 6. Setup log — what setup says it did for the probe
# ---------------------------------------------------------------------------
section "6. SETUP LOG ENTRIES MATCHING PROBE"
if [ -f "$SETUP_LOG" ]; then
    grep -F "$PROBE" "$SETUP_LOG" | tee -a "$REPORT"
    note ""
    note "--- summary by action ---"
    grep -F "$PROBE" "$SETUP_LOG" \
        | awk -F' - ' '{ print $3 }' \
        | awk -F: '{ print $1 }' \
        | sort | uniq -c | tee -a "$REPORT"
else
    note "(setup log not found)"
fi

# ---------------------------------------------------------------------------
# 7. Cross-reference: input CSV path vs test CSV path
# ---------------------------------------------------------------------------
section "7. PATH CROSS-REFERENCE"
note "For each probe path in input CSV, what did setup write to test CSV?"
note "Expected: test CSV path = MOCK_ENV_DIR + input CSV path"
note "          ($MOCK_ENV_DIR + /applications/... = $MOCK_ENV_DIR/applications/...)"
note ""
if [ -f "$INPUT_CSV" ] && [ -f "$TEST_CSV" ]; then
    grep -F "$PROBE" "$INPUT_CSV" \
        | awk -F'","' '{ gsub(/^"/, "", $1); gsub(/"$/, "", $NF); print $2 }' \
        | tr -d '\r' \
        | sort -u \
        | while IFS= read -r src_path; do
            expected_mock="${MOCK_ENV_DIR}${src_path}"
            note "input:    $src_path"
            note "expected: $expected_mock"
            note "in test CSV?"
            if grep -qF "\"$expected_mock\"" "$TEST_CSV"; then
                note "    YES — test CSV has the expected path"
            else
                note "    NO  — test CSV does NOT contain the expected path"
                note "    nearest matches in test CSV:"
                grep -F "$(basename "$src_path")" "$TEST_CSV" \
                    | sed 's/^/      /' | tee -a "$REPORT"
            fi
            note ""
        done
else
    note "(need both input CSV and test CSV to cross-reference)"
fi

# ---------------------------------------------------------------------------
# 8. Hypothesis check matrix
# ---------------------------------------------------------------------------
section "8. HYPOTHESIS CHECK MATRIX"
note ""
note "Three hypotheses for the 'Source path not found' WARN messages:"
note ""
note "  A) cp -a logged success but the file isn't actually on disk."
note "     Evidence: section 5 shows DOES NOT EXIST for paths that section 6"
note "     shows setup logging as 'Copying real item'."
note ""
note "  B) Destination path is truncated to the parent directory."
note "     Evidence: section 5 shows the parent directory exists but the file"
note "     basename is missing from it. Setup log destination (section 6) would"
note "     be shorter than the input CSV path (section 4)."
note ""
note "  C) A file in the input CSV is being treated as a directory by setup."
note "     Evidence: section 5 shows the path exists but [-d]=y when it should"
note "     be [-f]=y. Setup log (section 6) shows 'Creating mock directory'"
note "     for a basename that ends in .ini / .ini_bkp / .pem / etc."
note ""
note "Read sections 2, 5, and 6 together. The one that matches is the bug."
note ""

# ---------------------------------------------------------------------------
# 9. Tail
# ---------------------------------------------------------------------------
section "DIAGNOSTIC COMPLETE"
note "Full report saved to:  $REPORT"
note ""
note "Next step: paste this report into your local Claude Code session, e.g.:"
note "    claude < $REPORT"
note "Or share specific sections (2, 5, 6, 7) when asking for a fix."
