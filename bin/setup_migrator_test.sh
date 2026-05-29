#!/bin/bash
# =============================================================================
#
# Script:      setup_migrator_test.sh
#
# Description:
#   Thin orchestrator that drives a full mock-test cycle against a real CSV:
#     prepare         -> mock_build.sh from --csv
#     execute         -> migrator.sh --mode execute against the mock
#     validate        -> validate.sh against the mock
#     rollback        -> migrator.sh --mode rollback
#     validate-rollback -> verify mock matches live source after rollback
#     cleanup         -> migrator.sh --mode cleanup + rm -rf mock root
#     all             -> prepare + execute + validate + rollback + validate-rollback
#
#   Each step is a single subprocess invocation of the relevant tool, so the
#   harness has almost no logic of its own. NONINTERACTIVE=1 is set so that
#   migrator's live-mode countdown is skipped (the mock root is under /tmp,
#   so the gate wouldn't fire anyway — this is belt-and-suspenders).
#
# Common workflow:
#   bash setup_migrator_test.sh --mode all \\
#        --csv ../tests/cases/fat2.csv \\
#        --source-root /applications/opc_d2
#
#   On a host with no fat2 tree yet, you can substitute --source-root with
#   any directory tree that contains the paths listed in the CSV.
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_bash_version 4 2
set -euo pipefail

export NONINTERACTIVE=1  # No countdowns in test runs.

# =============================================================================
#                              GLOBAL STATE
# =============================================================================

MODE=""
CSV_FILE=""
SOURCE_ROOT=""
MOCK_ROOT="/tmp/mock_f2"
WORKDIR="/tmp/migration_f2_test"   # separate from real migration_f2

# =============================================================================
#                              USAGE
# =============================================================================

usage() {
    cat >&2 <<EOF
Usage: $0 --mode <all|prepare|execute|validate|rollback|validate-rollback|cleanup> [options]

REQUIRED for prepare / all:
  --csv         PATH   3-column input CSV (e.g. tests/cases/fat2.csv)
  --source-root PATH   Where the real paths in --csv live (e.g. /applications/opc_d2)

OPTIONAL:
  --mock-root  PATH   Default: /tmp/mock_f2
  --workdir    PATH   Default: /tmp/migration_f2_test
                      Holds migrator's backups + tracking, NOT the mock tree.

EXAMPLES:
  # Full cycle
  $0 --mode all --csv ../tests/cases/fat2.csv --source-root /applications/opc_d2

  # Just prepare the mock and execute, leave for inspection
  $0 --mode prepare --csv ../tests/cases/fat2.csv --source-root /applications/opc_d2
  $0 --mode execute
  $0 --mode validate

  # Roll back and verify
  $0 --mode rollback
  $0 --mode validate-rollback --source-root /applications/opc_d2

  # Wipe everything
  $0 --mode cleanup
EOF
    exit 1
}

parse_args() {
    if [ "$#" -eq 0 ]; then usage; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)        MODE="$2"; shift 2 ;;
            --csv)         CSV_FILE="$2"; shift 2 ;;
            --source-root) SOURCE_ROOT="$2"; shift 2 ;;
            --mock-root)   MOCK_ROOT="$2"; shift 2 ;;
            --workdir)     WORKDIR="$2"; shift 2 ;;
            -h|--help)     usage ;;
            *) echo "Error: Unknown argument '$1'" >&2; usage ;;
        esac
    done
    [ -n "$MODE" ] || usage
}

# =============================================================================
#                              PHASES
# =============================================================================

phase_prepare() {
    [ -n "$CSV_FILE" ]    || die "--mode prepare requires --csv"
    [ -n "$SOURCE_ROOT" ] || die "--mode prepare requires --source-root"
    info "==== PREPARE ===="
    bash "${SCRIPT_DIR}/mock_build.sh" \
        --csv "$CSV_FILE" \
        --source-root "$SOURCE_ROOT" \
        --mock-root "$MOCK_ROOT"
}

phase_execute() {
    info "==== EXECUTE ===="
    local mock_csv="${MOCK_ROOT}/mock_input.csv"
    [ -f "$mock_csv" ] || die "Mock CSV not found: $mock_csv. Run --mode prepare first."
    bash "${SCRIPT_DIR}/migrator.sh" \
        --mode execute \
        --root "$MOCK_ROOT" \
        --csv "$mock_csv" \
        --workdir "$WORKDIR"
}

phase_validate() {
    info "==== VALIDATE ===="
    bash "${SCRIPT_DIR}/validate.sh" \
        --root "$MOCK_ROOT" \
        --workdir "$WORKDIR" \
        --scan-root "$MOCK_ROOT"
}

phase_rollback() {
    info "==== ROLLBACK ===="
    bash "${SCRIPT_DIR}/migrator.sh" \
        --mode rollback \
        --root "$MOCK_ROOT" \
        --workdir "$WORKDIR"
}

# After rollback, the mock tree should match what mock_build originally
# copied from source. Compare every entry in mock_input.csv against the
# corresponding source path and report any divergence.
phase_validate_rollback() {
    [ -n "$SOURCE_ROOT" ] || die "--mode validate-rollback requires --source-root"
    info "==== VALIDATE-ROLLBACK ===="

    local mock_csv="${MOCK_ROOT}/mock_input.csv"
    [ -f "$mock_csv" ] || die "Mock CSV not found: $mock_csv"

    local pass=0 fail=0

    _check_one() {
        local _name="$1" mock_path="$2" _ts="$3"
        # Reverse-map mock path to its source equivalent. mock_build built
        # mock_path as MOCK_ROOT + the ORIGINAL absolute source path, so
        # stripping MOCK_ROOT already yields that source path. (The previous
        # code prepended SOURCE_ROOT again, doubling it to
        # /applications/opc_d2/applications/opc_d2/... so every row hit
        # "source missing" and the rollback check passed vacuously — a
        # false green. See bug A.)
        local rel="${mock_path#${MOCK_ROOT}}"
        local src_path="$rel"
        if [ ! -e "$src_path" ] && [ ! -L "$src_path" ]; then
            warn "  source missing (cannot compare): $src_path"
            return
        fi
        if [ ! -e "$mock_path" ] && [ ! -L "$mock_path" ]; then
            warn "  ROLLBACK FAIL: mock path absent: $mock_path"
            fail=$((fail + 1)); return
        fi
        # Type + mtime equality
        if ! verify_lstat_match "$src_path" "$mock_path" 2>/dev/null; then
            warn "  ROLLBACK FAIL: lstat mismatch between source and mock for: $mock_path"
            fail=$((fail + 1)); return
        fi
        # Content equality (skip dirs and symlinks)
        if [ -f "$mock_path" ] && [ ! -L "$mock_path" ]; then
            if ! diff -q "$src_path" "$mock_path" >/dev/null 2>&1; then
                warn "  ROLLBACK FAIL: content differs from source: $mock_path"
                fail=$((fail + 1)); return
            fi
        fi
        pass=$((pass + 1))
    }

    csv_read_3col "$mock_csv" _check_one

    info "rollback validation: pass=$pass fail=$fail"
    [ "$fail" -eq 0 ] || die "rollback did not restore mock to source-equivalent state"
    success "rollback restored mock to source-equivalent state"
}

phase_cleanup() {
    info "==== CLEANUP ===="
    if [ -d "$WORKDIR" ]; then
        bash "${SCRIPT_DIR}/migrator.sh" \
            --mode cleanup \
            --root "$MOCK_ROOT" \
            --workdir "$WORKDIR"
        rm -rf "$WORKDIR"
    fi
    if [ -d "$MOCK_ROOT" ]; then
        info "Removing mock root: $MOCK_ROOT"
        rm -rf "$MOCK_ROOT"
    fi
    success "Cleanup done."
}

# =============================================================================
#                              MAIN
# =============================================================================

main() {
    parse_args "$@"
    case "$MODE" in
        prepare)            phase_prepare ;;
        execute)            phase_execute ;;
        validate)           phase_validate ;;
        rollback)           phase_rollback ;;
        validate-rollback)  phase_validate_rollback ;;
        cleanup)            phase_cleanup ;;
        all)
            phase_prepare
            phase_execute
            phase_validate
            phase_rollback
            phase_validate_rollback
            ;;
        *) echo "Error: invalid --mode '$MODE'" >&2; usage ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
