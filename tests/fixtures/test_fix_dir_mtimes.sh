#!/bin/bash
# =============================================================================
#
# Script:      tests/fixtures/test_fix_dir_mtimes.sh
#
# Description:
#   End-to-end test for bin/fix_dir_mtimes.sh. Builds a synthetic tree
#   under /tmp with known mtimes, simulates a migration-style bump on
#   some directories, runs fix_dir_mtimes.sh, and asserts the bumped
#   directories were restored to their content's max mtime.
#
#   Run this on Linux. macOS lacks `stat -c`, `touch -d "@epoch"`, and
#   GNU find -printf, so the test won't execute end-to-end on Darwin.
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOL="${REPO_ROOT}/bin/fix_dir_mtimes.sh"

TEST_BASE="/tmp/test_fix_dir_mtimes.$$"
TREE="${TEST_BASE}/tree"

OLD_TS_HUMAN="2023-06-15 10:00:00"
OLD_TS_EPOCH=$(date -d "$OLD_TS_HUMAN" +%s)
CUTOFF_HUMAN="2023-12-31 23:59:59"
CUTOFF_EPOCH=$(date -d "$CUTOFF_HUMAN" +%s)
BUMP_HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"
BUMP_EPOCH=$(date +%s)

pass_count=0
fail_count=0

PASS() { pass_count=$((pass_count + 1)); printf '  [PASS] %s\n' "$1"; }
FAIL() { fail_count=$((fail_count + 1)); printf '  [FAIL] %s\n' "$1" >&2; }

# -----------------------------------------------------------------------------
# Build the tree
# -----------------------------------------------------------------------------
build_tree() {
    rm -rf "$TEST_BASE"
    mkdir -p "$TREE"

    # /tree/a/         (will be bumped — simulating a dir whose entries got renamed)
    # /tree/a/file1    (mtime = OLD)
    # /tree/a/file2    (mtime = OLD)
    # /tree/b/         (NOT bumped — should be left alone)
    # /tree/b/file3    (mtime = OLD)
    # /tree/c/         (bumped, contains a subdir)
    # /tree/c/sub/     (also bumped)
    # /tree/c/sub/file4 (mtime = OLD)
    # /tree/c/file5    (mtime = OLD)
    # /tree/empty/     (bumped but empty — should be skipped)

    mkdir -p "$TREE/a" "$TREE/b" "$TREE/c/sub" "$TREE/empty"
    : > "$TREE/a/file1"
    : > "$TREE/a/file2"
    : > "$TREE/b/file3"
    : > "$TREE/c/sub/file4"
    : > "$TREE/c/file5"

    # Stamp everything with OLD timestamp.
    find "$TREE" -print0 | xargs -0 touch -h -d "$OLD_TS_HUMAN"

    # Simulate the migration: bump dirs a/, c/, c/sub/, empty/ to "now".
    touch -h -d "$BUMP_HUMAN" "$TREE/a" "$TREE/c" "$TREE/c/sub" "$TREE/empty"

    echo "Built synthetic tree at $TREE"
    echo "  OLD timestamp : $OLD_TS_HUMAN  (epoch $OLD_TS_EPOCH)"
    echo "  BUMP timestamp: $BUMP_HUMAN  (epoch $BUMP_EPOCH)"
    echo "  CUTOFF used   : $CUTOFF_HUMAN  (epoch $CUTOFF_EPOCH)"
    echo ""
    echo "Pre-fix dir mtimes (expected: a/c/c/sub/empty = BUMP, b = OLD):"
    find "$TREE" -type d -printf '  %p\t%TY-%Tm-%Td %TH:%TM:%TS\n' | sort
    echo ""
}

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------
assert_mtime_epoch() {
    local path="$1" expected="$2" label="$3"
    local actual
    actual=$(stat -c '%Y' "$path")
    if [ "$actual" = "$expected" ]; then
        PASS "$label: $path mtime=$actual (expected $expected)"
    else
        FAIL "$label: $path mtime=$actual, expected $expected"
    fi
}

assert_mtime_less_than() {
    local path="$1" threshold="$2" label="$3"
    local actual
    actual=$(stat -c '%Y' "$path")
    if [ "$actual" -lt "$threshold" ]; then
        PASS "$label: $path mtime=$actual < $threshold"
    else
        FAIL "$label: $path mtime=$actual, expected < $threshold"
    fi
}

# -----------------------------------------------------------------------------
# Phases
# -----------------------------------------------------------------------------

phase_smoke_dryrun() {
    echo "==== PHASE 1: dry-run (no writes) ===="
    local before_a; before_a=$(stat -c '%Y' "$TREE/a")
    local before_b; before_b=$(stat -c '%Y' "$TREE/b")

    bash "$TOOL" --root "$TREE" --cutoff "$CUTOFF_HUMAN" --dry-run --verbose

    local after_a; after_a=$(stat -c '%Y' "$TREE/a")
    local after_b; after_b=$(stat -c '%Y' "$TREE/b")

    if [ "$before_a" = "$after_a" ] && [ "$before_b" = "$after_b" ]; then
        PASS "dry-run did not modify any mtimes"
    else
        FAIL "dry-run modified mtimes (a: $before_a -> $after_a, b: $before_b -> $after_b)"
    fi
    echo ""
}

phase_smoke_apply() {
    echo "==== PHASE 2: apply ===="
    bash "$TOOL" --root "$TREE" --cutoff "$CUTOFF_HUMAN" --verbose
    echo ""

    echo "Post-fix dir mtimes:"
    find "$TREE" -type d -printf '  %p\t%TY-%Tm-%Td %TH:%TM:%TS\n' | sort
    echo ""

    # /tree/a was bumped; its files are at OLD_TS_EPOCH. Max content = OLD_TS_EPOCH.
    # After fix: /tree/a should be at OLD_TS_EPOCH.
    assert_mtime_epoch "$TREE/a" "$OLD_TS_EPOCH" "a/ fixed to max content (OLD)"

    # /tree/b was NOT bumped (mtime < cutoff). Should be untouched at OLD.
    assert_mtime_epoch "$TREE/b" "$OLD_TS_EPOCH" "b/ left alone (was below cutoff)"

    # /tree/c was bumped. Its sub/ was also bumped. Deepest-first: sub fixed first
    # (max content = file4 at OLD), then c (max content = max(sub, file5) = OLD).
    assert_mtime_epoch "$TREE/c/sub" "$OLD_TS_EPOCH" "c/sub/ fixed to OLD"
    assert_mtime_epoch "$TREE/c"     "$OLD_TS_EPOCH" "c/ fixed to OLD after sub corrected"

    # /tree/empty was bumped but has no content. Should be skipped (left at BUMP).
    # Note: BUMP_EPOCH is whatever 'date +%s' returned at build time.
    local empty_mtime; empty_mtime=$(stat -c '%Y' "$TREE/empty")
    if [ "$empty_mtime" -ge "$CUTOFF_EPOCH" ]; then
        PASS "empty/ left alone (no content to derive new mtime from)"
    else
        FAIL "empty/ was changed but had no content (mtime=$empty_mtime)"
    fi
    echo ""
}

phase_idempotent() {
    echo "==== PHASE 3: idempotence (re-run should be no-op) ===="
    bash "$TOOL" --root "$TREE" --cutoff "$CUTOFF_HUMAN" --verbose 2>&1 | tail -10
    # After first apply, no dir has mtime > cutoff (except empty/), so the
    # second run should find nothing impacted (or only empty/ which is skipped).
    assert_mtime_epoch "$TREE/a"     "$OLD_TS_EPOCH" "a/ still at OLD after re-run"
    assert_mtime_epoch "$TREE/c"     "$OLD_TS_EPOCH" "c/ still at OLD after re-run"
    assert_mtime_epoch "$TREE/c/sub" "$OLD_TS_EPOCH" "c/sub/ still at OLD after re-run"
    echo ""
}

phase_cleanup() {
    rm -rf "$TEST_BASE"
    echo "Removed $TEST_BASE"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    echo "test_fix_dir_mtimes.sh"
    echo "  tool: $TOOL"
    echo ""

    if [ ! -x "$TOOL" ]; then
        echo "Error: $TOOL not found or not executable" >&2
        exit 1
    fi

    build_tree
    phase_smoke_dryrun
    phase_smoke_apply
    phase_idempotent
    phase_cleanup

    echo ""
    echo "==== SUMMARY ===="
    echo "  passes: $pass_count"
    echo "  fails : $fail_count"
    if [ "$fail_count" -eq 0 ]; then
        echo "  RESULT: ALL TESTS PASSED"
        exit 0
    else
        echo "  RESULT: FAILED"
        exit 1
    fi
}

main "$@"
