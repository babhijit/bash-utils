#!/bin/bash
# =============================================================================
#
# Script:      run_all_tests.sh
#
# Description:
#   Top-level smoke runner. Builds a synthetic source tree under /tmp,
#   generates a small synthetic CSV against it, and drives the full
#   mock_build -> migrator execute -> validate -> rollback -> validate-rollback
#   -> cleanup cycle. Does NOT require fat1/fat2 trees on the host.
#
#   The synthetic tree exercises all three lstat types (file, dir, symlink),
#   path renames, content rewrites, and the mtime-preservation contract.
#   Run this on any Linux box with bash >= 4.2 before deploying to the
#   real DR host.
#
# Exit codes:
#   0 — all phases passed.
#   non-zero — first phase that failed.
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_bash_version 4 2
set -euo pipefail

export NONINTERACTIVE=1

TEST_BASE="/tmp/run_all_tests.$$"
SRC_TREE="${TEST_BASE}/src/applications/opc_d2"
SRC_CSV="${TEST_BASE}/synthetic.csv"
MOCK_ROOT="${TEST_BASE}/mock"
WORKDIR="${TEST_BASE}/workdir"

# Old timestamp for synthetic files. Migrator must preserve this through
# both forward migration and rollback.
OLD_TS_HUMAN="2023-06-15 10:00:00"
OLD_TS_EPOCH="$(date -d "$OLD_TS_HUMAN" +%s 2>/dev/null || echo 1686823200)"

# =============================================================================
#                              SETUP
# =============================================================================

build_synthetic_tree() {
    info "Building synthetic source tree at $SRC_TREE"
    rm -rf "$TEST_BASE"
    safe_mkdir_p "$SRC_TREE"

    # 1. A file whose NAME contains fat1 markers.
    safe_mkdir_p "${SRC_TREE}/security"
    cat > "${SRC_TREE}/security/fat1_config.ini" <<'EOF'
# config referencing FAT1 and opc_d1
host=fat1.example.com
data_dir=/applications/opc_d1/data
EOF

    # 2. A file whose CONTENT references fat1 but name is fat2-style.
    safe_mkdir_p "${SRC_TREE}/conf"
    cat > "${SRC_TREE}/conf/setenv.sh" <<'EOF'
#!/bin/sh
export APP_HOME=/applications/opc_d1
export INSTANCE=FAT1
EOF

    # 3. A directory whose name contains fat1 markers.
    safe_mkdir_p "${SRC_TREE}/tools/mq-opcsvcf1"
    echo "internal config for mq-opcsvcf1" > "${SRC_TREE}/tools/mq-opcsvcf1/config"

    # 4. A symlink pointing at an opcsvcf1 path.
    ln -s "../../../tools/mq-opcsvcf1/config" "${SRC_TREE}/conf/mq_link"

    # 5. A file that contains NO fat1 references — should not be touched.
    cat > "${SRC_TREE}/conf/innocent.conf" <<'EOF'
This file mentions nothing relevant.
EOF

    # Stamp everything with the old timestamp so we can verify preservation.
    find "$SRC_TREE" -print0 | xargs -0 touch -h -d "$OLD_TS_HUMAN"
}

write_synthetic_csv() {
    info "Writing synthetic CSV: $SRC_CSV"
    cat > "$SRC_CSV" <<EOF
Name,Absolute_Path,Last_Modified
"fat1_config.ini","${SRC_TREE}/security/fat1_config.ini","${OLD_TS_HUMAN}"
"setenv.sh","${SRC_TREE}/conf/setenv.sh","${OLD_TS_HUMAN}"
"mq-opcsvcf1","${SRC_TREE}/tools/mq-opcsvcf1","${OLD_TS_HUMAN}"
"mq_link","${SRC_TREE}/conf/mq_link","${OLD_TS_HUMAN}"
EOF
}

# =============================================================================
#                              ASSERTIONS
# =============================================================================

# assert_mtime_equals <path> <expected_epoch> <label>
assert_mtime_equals() {
    local path="$1" expected="$2" label="$3"
    local actual; actual=$(lstat_mtime_epoch "$path")
    if [ "$actual" = "$expected" ]; then
        info "  [OK] mtime preserved ($label): $path"
    else
        die "  [FAIL] mtime drifted ($label): $path  have=$actual want=$expected"
    fi
}

# assert_path_exists <path> <label>
assert_path_exists() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        info "  [OK] exists ($2): $1"
    else
        die "  [FAIL] missing ($2): $1"
    fi
}

# assert_path_absent <path> <label>
assert_path_absent() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        info "  [OK] absent ($2): $1"
    else
        die "  [FAIL] should not exist ($2): $1"
    fi
}

# assert_file_contains <path> <substring> <label>
assert_file_contains() {
    if grep -qF "$2" "$1" 2>/dev/null; then
        info "  [OK] contains '$2' ($3): $1"
    else
        die "  [FAIL] does NOT contain '$2' ($3): $1"
    fi
}

assert_file_lacks() {
    if ! grep -qF "$2" "$1" 2>/dev/null; then
        info "  [OK] lacks '$2' ($3): $1"
    else
        die "  [FAIL] still contains '$2' ($3): $1"
    fi
}

# =============================================================================
#                              PHASES
# =============================================================================

phase_mock_build() {
    info "==== PHASE: mock_build ===="
    bash "${SCRIPT_DIR}/mock_build.sh" \
        --csv "$SRC_CSV" \
        --source-root "${TEST_BASE}/src" \
        --mock-root "$MOCK_ROOT" \
        --reset

    # The mock should contain copies under the same tree shape, with mtimes
    # preserved.
    local mock_csv="${MOCK_ROOT}/mock_input.csv"
    assert_path_exists "$mock_csv" "mock_input.csv"
    assert_path_exists "${MOCK_ROOT}${SRC_TREE}/security/fat1_config.ini" "mock copy of fat1_config.ini"
    assert_mtime_equals "${MOCK_ROOT}${SRC_TREE}/security/fat1_config.ini" "$OLD_TS_EPOCH" "post-mock_build"
}

phase_migrator_execute() {
    info "==== PHASE: migrator execute ===="
    bash "${SCRIPT_DIR}/migrator.sh" \
        --mode execute \
        --root "$MOCK_ROOT" \
        --csv "${MOCK_ROOT}/mock_input.csv" \
        --workdir "$WORKDIR"

    # Expectations after execute:
    #   - fat1_config.ini renamed to fat2_config.ini
    #   - setenv.sh kept its name but content rewritten
    #   - mq-opcsvcf1 directory renamed to mq-opcsvcf2
    #   - mq_link symlink retargeted to point at mq-opcsvcf2
    #   - mtimes preserved on all four
    local prefix="${MOCK_ROOT}${SRC_TREE}"

    assert_path_absent "${prefix}/security/fat1_config.ini" "post-execute (old name)"
    assert_path_exists "${prefix}/security/fat2_config.ini" "post-execute (new name)"
    assert_mtime_equals "${prefix}/security/fat2_config.ini" "$OLD_TS_EPOCH" "post-execute"

    assert_file_lacks    "${prefix}/conf/setenv.sh" "FAT1" "post-execute (no FAT1 left)"
    assert_file_lacks    "${prefix}/conf/setenv.sh" "opc_d1" "post-execute (no opc_d1 left)"
    assert_file_contains "${prefix}/conf/setenv.sh" "FAT2" "post-execute (FAT2 present)"
    assert_file_contains "${prefix}/conf/setenv.sh" "opc_d2" "post-execute (opc_d2 present)"
    assert_mtime_equals  "${prefix}/conf/setenv.sh" "$OLD_TS_EPOCH" "post-execute"

    assert_path_absent "${prefix}/tools/mq-opcsvcf1" "post-execute (old dir name)"
    assert_path_exists "${prefix}/tools/mq-opcsvcf2" "post-execute (new dir name)"
    assert_mtime_equals "${prefix}/tools/mq-opcsvcf2" "$OLD_TS_EPOCH" "post-execute (dir mtime)"

    # symlink target should now reference mq-opcsvcf2
    local sl="${prefix}/conf/mq_link"
    if [ -L "$sl" ]; then
        local target; target=$(readlink "$sl")
        case "$target" in
            *mq-opcsvcf2*) info "  [OK] symlink retargeted: $sl -> $target" ;;
            *) die "  [FAIL] symlink target not retargeted: $sl -> $target" ;;
        esac
        assert_mtime_equals "$sl" "$OLD_TS_EPOCH" "post-execute (symlink mtime)"
    else
        die "  [FAIL] symlink missing: $sl"
    fi
}

phase_validate() {
    info "==== PHASE: validate ===="
    bash "${SCRIPT_DIR}/validate.sh" \
        --root "$MOCK_ROOT" \
        --workdir "$WORKDIR" \
        --scan-root "$MOCK_ROOT"
}

phase_resume_smoke() {
    info "==== PHASE: resume smoke (re-run execute, should be no-op) ===="
    # Re-running execute should be a no-op (all rows COMPLETED).
    bash "${SCRIPT_DIR}/migrator.sh" \
        --mode execute \
        --root "$MOCK_ROOT" \
        --csv "${MOCK_ROOT}/mock_input.csv" \
        --workdir "$WORKDIR"
    info "  [OK] resume run completed without error"
}

phase_rollback() {
    info "==== PHASE: rollback ===="
    bash "${SCRIPT_DIR}/migrator.sh" \
        --mode rollback \
        --root "$MOCK_ROOT" \
        --workdir "$WORKDIR"

    local prefix="${MOCK_ROOT}${SRC_TREE}"
    # Original names should be back.
    assert_path_exists "${prefix}/security/fat1_config.ini" "post-rollback (old name restored)"
    assert_path_absent "${prefix}/security/fat2_config.ini" "post-rollback (new name removed)"
    assert_mtime_equals "${prefix}/security/fat1_config.ini" "$OLD_TS_EPOCH" "post-rollback"

    # Content restored.
    assert_file_contains "${prefix}/conf/setenv.sh" "FAT1" "post-rollback"
    assert_file_lacks    "${prefix}/conf/setenv.sh" "FAT2" "post-rollback"
    assert_mtime_equals  "${prefix}/conf/setenv.sh" "$OLD_TS_EPOCH" "post-rollback"

    # Directory restored.
    assert_path_exists "${prefix}/tools/mq-opcsvcf1" "post-rollback"
    assert_path_absent "${prefix}/tools/mq-opcsvcf2" "post-rollback"

    # Symlink target restored.
    local sl="${prefix}/conf/mq_link"
    local target; target=$(readlink "$sl")
    case "$target" in
        *mq-opcsvcf1*) info "  [OK] symlink target restored: $sl -> $target" ;;
        *) die "  [FAIL] symlink target NOT restored: $sl -> $target" ;;
    esac
}

phase_cleanup() {
    info "==== PHASE: cleanup ===="
    bash "${SCRIPT_DIR}/migrator.sh" \
        --mode cleanup \
        --root "$MOCK_ROOT" \
        --workdir "$WORKDIR"
    rm -rf "$TEST_BASE"
    info "  [OK] cleanup removed $TEST_BASE"
}

# =============================================================================
#                              MAIN
# =============================================================================

main() {
    info "run_all_tests.sh: synthetic end-to-end test"
    info "Test base: $TEST_BASE"

    build_synthetic_tree
    write_synthetic_csv

    phase_mock_build
    phase_migrator_execute
    phase_validate
    phase_resume_smoke
    phase_rollback
    phase_cleanup

    success "ALL TESTS PASSED"
}

main "$@"
