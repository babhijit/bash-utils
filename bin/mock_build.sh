#!/bin/bash
# =============================================================================
#
# Script:      mock_build.sh
#
# Description:
#   Builds a sandboxed mock environment from a CSV of live paths. For each
#   row in --csv, copies the real path (under --source-root) into the
#   parallel location under --mock-root, preserving lstat (cp -a). Emits a
#   companion mock_input.csv whose Absolute_Path column points at the mock
#   tree — that's what migrator consumes.
#
#   This is the "selective smart copy" called for in the DR requirements:
#     - Only paths listed in the CSV are copied (selective).
#     - Per-row stat verification confirms the mock genuinely matches live.
#     - Output mock_input.csv carries the ORIGINAL mtime so migrator's
#       final touch -h -d restores it exactly.
#
#   Idempotent: re-running mock_build with an existing --mock-root will
#   skip rows whose mock copy already exists and verifies cleanly. To
#   force a full rebuild, --reset wipes --mock-root first.
#
# Safety:
#   --source-root REQUIRED. Every CSV row's Absolute_Path must be under
#   --source-root, or mock_build refuses (assert_under_root).
#   --mock-root  MUST NOT be the same as --source-root or under it.
#
# Output:
#   <mock-root>/<original-tree>/...      copies of each listed path
#   <mock-root>/mock_input.csv           CSV with mock paths, suitable for
#                                        feeding into migrator --csv
#   <mock-root>/mock_build.log           per-run log
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_bash_version 4 2
set -euo pipefail

# =============================================================================
#                              GLOBAL STATE
# =============================================================================

CSV_FILE=""
SOURCE_ROOT=""
MOCK_ROOT=""
RESET=0

# Counters for the summary line.
COUNT_COPIED=0
COUNT_SKIPPED=0
COUNT_MISSING=0
COUNT_FAILED=0

# Mock CSV is written here; pre-allocated at start of run.
MOCK_CSV=""

# =============================================================================
#                              USAGE
# =============================================================================

usage() {
    cat >&2 <<EOF
Usage: $0 --csv <input.csv> --source-root <path> [options]

REQUIRED:
  --csv          PATH   3-column CSV (Name,Absolute_Path,Last_Modified)
  --source-root  PATH   Real filesystem root every CSV path must be under

OPTIONAL:
  --mock-root    PATH   Where to build the mock tree (default: /tmp/mock_f2)
  --reset               rm -rf --mock-root before starting (force full rebuild)
  --log-file     PATH   Default: <mock-root>/mock_build.log

EXAMPLE:
  $0 --csv tests/cases/fat2.csv \\
     --source-root /applications/opc_d2 \\
     --mock-root /tmp/mock_f2

OUTPUT:
  <mock-root>/mock_input.csv  — feed this to migrator.sh --csv
EOF
    exit 1
}

parse_args() {
    local mock_root_arg=""
    local log_file_arg=""
    if [ "$#" -eq 0 ]; then usage; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --csv)         CSV_FILE="$2"; shift 2 ;;
            --source-root) SOURCE_ROOT="$2"; shift 2 ;;
            --mock-root)   mock_root_arg="$2"; shift 2 ;;
            --reset)       RESET=1; shift ;;
            --log-file)    log_file_arg="$2"; shift 2 ;;
            -h|--help)     usage ;;
            *) echo "Error: Unknown argument '$1'" >&2; usage ;;
        esac
    done

    [ -n "$CSV_FILE" ]    || { echo "Error: --csv required" >&2; usage; }
    [ -n "$SOURCE_ROOT" ] || { echo "Error: --source-root required" >&2; usage; }
    [ -f "$CSV_FILE" ]    || die "CSV not found: $CSV_FILE"
    [ -d "$SOURCE_ROOT" ] || die "Source root does not exist: $SOURCE_ROOT"

    MOCK_ROOT="${mock_root_arg:-/tmp/mock_f2}"
    SOURCE_ROOT="$(normalize_path "$SOURCE_ROOT")"
    MOCK_ROOT="$(normalize_path "$MOCK_ROOT")"

    # Don't allow mock root to BE source root or live under it. That would
    # be catastrophic (we'd "copy" into the original tree).
    if [ "$MOCK_ROOT" = "$SOURCE_ROOT" ] || [[ "$MOCK_ROOT" == "$SOURCE_ROOT"/* ]]; then
        die "--mock-root ('$MOCK_ROOT') cannot be under --source-root ('$SOURCE_ROOT')" 2
    fi

    export LOG_FILE="${log_file_arg:-${MOCK_ROOT}/mock_build.log}"
    MOCK_CSV="${MOCK_ROOT}/mock_input.csv"
}

# =============================================================================
#                              ROW PROCESSING
# =============================================================================

# process_row <name> <src_path> <ts>
# Called by csv_read_3col for each row of input CSV. Copies src_path to its
# parallel location under MOCK_ROOT and appends a row to MOCK_CSV.
process_row() {
    local name="$1"
    local src_path="$2"
    local ts="$3"

    # Safety guard.
    assert_under_root "$src_path" "$SOURCE_ROOT"

    # Mock path = MOCK_ROOT + src_path (relative to /). The src_path is
    # absolute, so direct concatenation produces the right shape.
    local mock_path="${MOCK_ROOT}${src_path}"

    # Source must exist (file, dir, or symlink). We deliberately accept
    # symlinks-to-anywhere; the migration logic handles symlink retarget.
    if [ ! -e "$src_path" ] && [ ! -L "$src_path" ]; then
        warn "MISSING on source: $src_path"
        COUNT_MISSING=$((COUNT_MISSING + 1))
        return 0
    fi

    # Idempotence: if the mock copy already exists AND has matching lstat,
    # skip. This makes re-runs cheap and supports resume after a kill.
    if { [ -e "$mock_path" ] || [ -L "$mock_path" ]; } && \
       verify_lstat_match "$src_path" "$mock_path" 2>/dev/null; then
        info "SKIP (mock already present, lstat verified): $mock_path"
        append_mock_csv_row "$name" "$mock_path" "$ts"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        return 0
    fi

    # Make parent dir.
    safe_mkdir_p "$(dirname "$mock_path")"

    # If mock exists but is stale, remove before copying.
    if [ -e "$mock_path" ] || [ -L "$mock_path" ]; then
        rm -rf "$mock_path"
    fi

    # Determine source type WITHOUT following symlinks. The previous harness
    # used `[ -d ]` which follows symlinks — a symlink to a directory was
    # misclassified and `mkdir`'d instead of copied. Use -L first.
    if [ -L "$src_path" ]; then
        # Symlink: cp -a preserves link semantics.
        if ! cp -a "$src_path" "$mock_path"; then
            warn "FAILED to copy symlink: $src_path -> $mock_path"
            COUNT_FAILED=$((COUNT_FAILED + 1))
            return 0
        fi
    elif [ -d "$src_path" ]; then
        # Directory: cp -a copies recursively. For large directories this
        # can be slow; the operator should know if their CSV has whole
        # directories listed.
        if ! cp -a "$src_path" "$mock_path"; then
            warn "FAILED to copy directory: $src_path -> $mock_path"
            COUNT_FAILED=$((COUNT_FAILED + 1))
            return 0
        fi
    elif [ -f "$src_path" ]; then
        if ! cp -a "$src_path" "$mock_path"; then
            warn "FAILED to copy file: $src_path -> $mock_path"
            COUNT_FAILED=$((COUNT_FAILED + 1))
            return 0
        fi
    else
        warn "UNKNOWN type for source: $src_path (not link/dir/file)"
        COUNT_FAILED=$((COUNT_FAILED + 1))
        return 0
    fi

    # Verify the copy worked. cp -a should preserve lstat; if it didn't,
    # something is wrong (filesystem doesn't support timestamps, or we
    # crossed a fs boundary that strips ACLs).
    if ! verify_lstat_match "$src_path" "$mock_path"; then
        warn "VERIFY FAILED post-copy: $src_path vs $mock_path"
        COUNT_FAILED=$((COUNT_FAILED + 1))
        return 0
    fi

    append_mock_csv_row "$name" "$mock_path" "$ts"
    COUNT_COPIED=$((COUNT_COPIED + 1))
}

append_mock_csv_row() {
    local name="$1" mock_path="$2" ts="$3"
    printf '"%s","%s","%s"\n' "$name" "$mock_path" "$ts" >> "$MOCK_CSV"
}

# =============================================================================
#                              MAIN
# =============================================================================

main() {
    parse_args "$@"

    if [ "$RESET" -eq 1 ] && [ -d "$MOCK_ROOT" ]; then
        info "RESET requested; removing existing mock root: $MOCK_ROOT"
        rm -rf "$MOCK_ROOT"
    fi

    safe_mkdir_p "$MOCK_ROOT"
    : > "$LOG_FILE"

    info "mock_build.sh starting"
    info "  csv=$CSV_FILE"
    info "  source_root=$SOURCE_ROOT"
    info "  mock_root=$MOCK_ROOT"

    # Fresh mock CSV.
    echo "Name,Absolute_Path,Last_Modified" > "$MOCK_CSV"

    csv_read_3col "$CSV_FILE" process_row

    info "----- SUMMARY -----"
    info "  copied:  $COUNT_COPIED"
    info "  skipped: $COUNT_SKIPPED  (already present, lstat verified)"
    info "  missing: $COUNT_MISSING  (source path absent)"
    info "  failed:  $COUNT_FAILED"
    info "  mock CSV: $MOCK_CSV"

    if [ "$COUNT_FAILED" -gt 0 ]; then
        die "mock_build completed with $COUNT_FAILED failures; inspect $LOG_FILE" 1
    fi

    success "mock_build complete. Feed migrator with --csv $MOCK_CSV --root $MOCK_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
