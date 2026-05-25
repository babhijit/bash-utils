#!/bin/bash
# =============================================================================
#
# Script:      tests/fixtures/run_local_test.sh
#
# Description:
#   End-to-end migration test using the committed fixture source tree.
#   Mirrors the production workflow (mock_build -> migrator -> validate ->
#   rollback -> cleanup) so that the same mental model applies to both
#   testing and live operation.
#
# Modes:
#   prepare   — copy fixture to TEST_BASE, stamp timestamps, write CSV,
#               run mock_build.sh
#   execute   — migrator.sh --mode execute + post-migration assertions
#   validate  — validate.sh post-execute check
#   resume    — re-run execute (should be no-op) + same assertions
#   rollback  — migrator.sh --mode rollback + post-rollback assertions
#   cleanup   — migrator.sh --mode cleanup + rm -rf TEST_BASE
#   all       — all of the above in sequence
#
# Fixed paths (deterministic between invocations):
#   TEST_BASE  = /tmp/run_local_test  (override with --test-base)
#   MOCK_ROOT  = TEST_BASE/mock
#   WORKDIR    = TEST_BASE/workdir
#
# Production equivalent:
#   prepare  ≈  mock_build.sh --csv ... --source-root ... --mock-root ...
#   execute  ≈  migrator.sh --mode execute --root ... --csv ... --workdir ...
#   validate ≈  validate.sh --root ... --workdir ...
#   rollback ≈  migrator.sh --mode rollback --root ... --workdir ...
#   cleanup  ≈  migrator.sh --mode cleanup --root ... --workdir ...
#
# Bash version floor: 4.2
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "${SCRIPT_DIR}/../../bin" && pwd)"

# shellcheck source=../../bin/common.sh
source "${BIN_DIR}/common.sh"
require_bash_version 4 2
set -euo pipefail

export NONINTERACTIVE=1

# =============================================================================
#                              DEFAULTS
# =============================================================================

TEST_BASE="/tmp/run_local_test"
MODE=""

# =============================================================================
#                              USAGE
# =============================================================================

usage() {
    cat >&2 <<EOF
Usage: $0 --mode <MODE> [--test-base PATH]

MODES:
  prepare    Copy fixture to test base, stamp timestamps, write CSV, mock_build
  execute    Run migrator execute + assert post-migration state
  validate   Run validate.sh against the migrated mock
  resume     Re-run execute (expect no-op) + assert state unchanged
  rollback   Run migrator rollback + assert pre-migration state restored
  cleanup    Run migrator cleanup + remove test base
  all        Run all phases in sequence

OPTIONS:
  --test-base PATH   Working directory (default: /tmp/run_local_test)

EXAMPLES:
  # Phase by phase (mirrors production workflow):
  $0 --mode prepare
  $0 --mode execute
  $0 --mode validate
  $0 --mode rollback
  $0 --mode cleanup

  # Full cycle:
  $0 --mode all
EOF
    exit 1
}

parse_args() {
    if [ "$#" -eq 0 ]; then usage; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)      MODE="$2"; shift 2 ;;
            --test-base) TEST_BASE="$2"; shift 2 ;;
            -h|--help)   usage ;;
            *) echo "Error: Unknown argument '$1'" >&2; usage ;;
        esac
    done
    [ -n "$MODE" ] || usage
}

# =============================================================================
#                              DERIVED PATHS
# =============================================================================

FIXTURE_SRC=""
TMP_SRC=""
OPC=""
MOCK_ROOT=""
WORKDIR=""
CSV_FILE=""
MOPC=""       # MOCK_ROOT + OPC — assertion root after mock_build

init_paths() {
    FIXTURE_SRC="${SCRIPT_DIR}/source"
    TMP_SRC="${TEST_BASE}/src"
    OPC="${TMP_SRC}/applications/opc_d2"
    MOCK_ROOT="${TEST_BASE}/mock"
    WORKDIR="${TEST_BASE}/workdir"
    CSV_FILE="${TEST_BASE}/fixture_input.csv"
    MOPC="${MOCK_ROOT}${OPC}"

    mkdir -p "${TEST_BASE}"
    export LOG_FILE="${TEST_BASE}/run_local_test.log"
}

# =============================================================================
#                          TIMESTAMP GROUPS
# =============================================================================
#
# Three groups matching the real fat2 tree mtimes.
# TS_A: Server_8_FAT2 bin/conf files and etc/
# TS_B: bin/, security/, tools/certnanny/, tools/mq-tool/,
#       tools/simulators/, tools/ucd/
# TS_C: home/, tools/pkibot_working/, tools/sftpserver/,
#       installed.properties

TS_A="2025-09-13 15:03:13"
TS_B="2021-10-01 14:03:58"
TS_C="2026-03-21 09:26:21"

TS_A_EPOCH=""
TS_B_EPOCH=""
TS_C_EPOCH=""

init_epochs() {
    TS_A_EPOCH=$(date -d "${TS_A} +0200" +%s)
    TS_B_EPOCH=$(date -d "${TS_B} +0200" +%s)
    TS_C_EPOCH=$(date -d "${TS_C} +0200" +%s)
}

# =============================================================================
#                          ASSERTION HELPERS
# =============================================================================

PASS_COUNT=0
FAIL_COUNT=0

assert_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    info "  PASS: $1"
}

assert_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "ERROR" "  FAIL: $1"
}

assert_path_exists() {
    local path="$1" label="${2:-$1}"
    if [ -e "${path}" ] || [ -L "${path}" ]; then
        assert_pass "exists: ${label}"
    else
        assert_fail "expected to exist: ${label}"
    fi
}

assert_path_absent() {
    local path="$1" label="${2:-$1}"
    if [ -e "${path}" ] || [ -L "${path}" ]; then
        assert_fail "expected absent: ${label}"
    else
        assert_pass "absent: ${label}"
    fi
}

assert_file_contains() {
    local file="$1" string="$2" label="${3:-$1 contains '$2'}"
    if grep -qF -- "${string}" "${file}" 2>/dev/null; then
        assert_pass "${label}"
    else
        assert_fail "${label}"
    fi
}

assert_file_lacks() {
    local file="$1" string="$2" label="${3:-$1 lacks '$2'}"
    if grep -qF -- "${string}" "${file}" 2>/dev/null; then
        assert_fail "${label}"
    else
        assert_pass "${label}"
    fi
}

assert_mtime_epoch() {
    local path="$1" expected="$2" label="${3:-mtime of $1}"
    local actual
    actual=$(stat -c %Y "${path}" 2>/dev/null || echo "")
    if [ "${actual}" = "${expected}" ]; then
        assert_pass "${label} mtime=${expected}"
    else
        assert_fail "${label}: expected mtime=${expected}, got=${actual:-MISSING}"
    fi
}

assert_symlink_target() {
    local path="$1" expected="$2" label="${3:-symlink target of $1}"
    local actual
    actual=$(readlink "${path}" 2>/dev/null || echo "")
    if [ "${actual}" = "${expected}" ]; then
        assert_pass "${label} -> ${expected}"
    else
        assert_fail "${label}: expected -> '${expected}', got -> '${actual:-MISSING}'"
    fi
}

# =============================================================================
#                          PHASE: PREPARE
# =============================================================================

stamp_timestamps() {
    # Set CHILD mtimes first, then parent dirs AFTER so the parent's mtime
    # is not bumped by the child writes.

    # TS_A: application/Server_8_FAT2/bin and conf, plus etc/
    find "${OPC}/application/Server_8_FAT2/bin" \
         "${OPC}/application/Server_8_FAT2/conf" \
         "${OPC}/etc" \
         -maxdepth 1 -type f -print0 \
        | xargs -0 -r touch -h -d "${TS_A}"

    # TS_B: bin/ (bld.setenv), bin/env/ files (including symlink),
    #       security/ files, certnanny/ files, mq-tool/ files,
    #       simulators/ files, ucd/ (except installed.properties)
    find "${OPC}/bin" -maxdepth 1 -type f -print0 \
        | xargs -0 -r touch -h -d "${TS_B}"
    find "${OPC}/bin/env" -maxdepth 1 \( -type f -o -type l \) -print0 \
        | xargs -0 -r touch -h -d "${TS_B}"
    find "${OPC}/security" -type f -print0 \
        | xargs -0 -r touch -h -d "${TS_B}"
    find "${OPC}/tools/certnanny" -type f -print0 \
        | xargs -0 -r touch -h -d "${TS_B}"
    find "${OPC}/tools/mq-tool" -type f -print0 \
        | xargs -0 -r touch -h -d "${TS_B}"
    find "${OPC}/tools/simulators" -type f -print0 \
        | xargs -0 -r touch -h -d "${TS_B}"
    find "${OPC}/tools/ucd" -type f \
         ! -path "*/conf/agent/installed.properties" -print0 \
        | xargs -0 -r touch -h -d "${TS_B}"

    # TS_C: home/, pkibot_working/, sftpserver/, installed.properties
    find "${OPC}/home" -type f -print0 \
        | xargs -0 -r touch -h -d "${TS_C}"
    find "${OPC}/tools/pkibot_working" \( -type f -o -type d \) -print0 \
        | xargs -0 -r touch -h -d "${TS_C}"
    find "${OPC}/tools/sftpserver" -type f -print0 \
        | xargs -0 -r touch -h -d "${TS_C}"
    touch -h -d "${TS_C}" \
        "${OPC}/tools/ucd/udeploy/ibm-ucdagent/conf/agent/installed.properties"

    # Stamp directories last (children before parents).
    touch -d "${TS_A}" "${OPC}/application/Server_8_FAT2/bin"
    touch -d "${TS_A}" "${OPC}/application/Server_8_FAT2/conf"
    touch -d "${TS_A}" "${OPC}/application/Server_8_FAT2"
    touch -d "${TS_A}" "${OPC}/etc"
    touch -d "${TS_B}" "${OPC}/bin/env"
    touch -d "${TS_B}" "${OPC}/bin"
    find "${OPC}/security" -type d -print0 | xargs -0 -r touch -d "${TS_B}"
    find "${OPC}/tools/certnanny" -type d -print0 | xargs -0 -r touch -d "${TS_B}"
    find "${OPC}/tools/mq-tool" -type d -print0 | xargs -0 -r touch -d "${TS_B}"
    find "${OPC}/tools/simulators" -type d -print0 | xargs -0 -r touch -d "${TS_B}"
    find "${OPC}/tools/ucd" -type d -print0 | xargs -0 -r touch -d "${TS_B}"
    find "${OPC}/home" -type d -print0 | xargs -0 -r touch -d "${TS_C}"
    find "${OPC}/tools/pkibot_working" -type d -print0 | xargs -0 -r touch -d "${TS_C}"
    find "${OPC}/tools/sftpserver" -type d -print0 | xargs -0 -r touch -d "${TS_C}"
    touch -d "${TS_B}" "${OPC}/tools" || true
    touch -d "${TS_A}" "${OPC}/application" || true
}

write_csv() {
    cat > "${CSV_FILE}" <<EOF
Name,Absolute_Path,Last_Modified
setenv.sh,${OPC}/application/Server_8_FAT2/bin/setenv.sh,${TS_A}.000000000 +0200
setenv.sh.2024-10-27-01-13-14,${OPC}/application/Server_8_FAT2/bin/setenv.sh.2024-10-27-01-13-14,${TS_A}.000000000 +0200
setenv.sh.2024-10-31-13-21-50,${OPC}/application/Server_8_FAT2/bin/setenv.sh.2024-10-31-13-21-50,${TS_A}.000000000 +0200
setenv.sh.2025-09-04-15-04-39,${OPC}/application/Server_8_FAT2/bin/setenv.sh.2025-09-04-15-04-39,${TS_A}.000000000 +0200
setenv.sh.2025-09-09,${OPC}/application/Server_8_FAT2/bin/setenv.sh.2025-09-09,${TS_A}.000000000 +0200
setenv.sh.backup-2025-09-03,${OPC}/application/Server_8_FAT2/bin/setenv.sh.backup-2025-09-03,${TS_A}.000000000 +0200
setenv.sh_20220813,${OPC}/application/Server_8_FAT2/bin/setenv.sh_20220813,${TS_A}.000000000 +0200
setenv.sh_20221011,${OPC}/application/Server_8_FAT2/bin/setenv.sh_20221011,${TS_A}.000000000 +0200
setenv.sh_backup202202101645,${OPC}/application/Server_8_FAT2/bin/setenv.sh_backup202202101645,${TS_A}.000000000 +0200
context.xml,${OPC}/application/Server_8_FAT2/conf/context.xml,${TS_A}.000000000 +0200
context.xml_backup_04-09-2025,${OPC}/application/Server_8_FAT2/conf/context.xml_backup_04-09-2025,${TS_A}.000000000 +0200
context_eidg.xml.2024-10-25-21-45-26,${OPC}/application/Server_8_FAT2/conf/context_eidg.xml.2024-10-25-21-45-26,${TS_A}.000000000 +0200
context_exacc.xml,${OPC}/application/Server_8_FAT2/conf/context_exacc.xml,${TS_A}.000000000 +0200
context_exacc.xml_backup_04-09-2025,${OPC}/application/Server_8_FAT2/conf/context_exacc.xml_backup_04-09-2025,${TS_A}.000000000 +0200
context_exacc.bkup.xml,${OPC}/application/Server_8_FAT2/conf/context_exacc.bkup.xml,${TS_A}.000000000 +0200
context_passive.xml,${OPC}/application/Server_8_FAT2/conf/context_passive.xml,${TS_A}.000000000 +0200
logging.properties,${OPC}/application/Server_8_FAT2/conf/logging.properties,${TS_A}.000000000 +0200
logging.properties.2025-09-09-17-18-42.bak,${OPC}/application/Server_8_FAT2/conf/logging.properties.2025-09-09-17-18-42.bak,${TS_A}.000000000 +0200
oracledebug.properties,${OPC}/application/Server_8_FAT2/conf/oracledebug.properties,${TS_A}.000000000 +0200
server.xml,${OPC}/application/Server_8_FAT2/conf/server.xml,${TS_A}.000000000 +0200
bld.setenv,${OPC}/bin/bld.setenv,${TS_B}.000000000 +0200
bld.proxy,${OPC}/bin/env/bld.proxy,${TS_B}.000000000 +0200
bld.proxy.FAT1,${OPC}/bin/env/bld.proxy.FAT1,${TS_B}.000000000 +0200
bld.umask.nonprod,${OPC}/bin/env/bld.umask.nonprod,${TS_B}.000000000 +0200
tail.FAT2.rc_art,${OPC}/bin/env/tail.FAT2.rc_art,${TS_B}.000000000 +0200
rc_art,${OPC}/etc/rc_art,${TS_A}.000000000 +0200
rc_art.bak.20250624-123353,${OPC}/etc/rc_art.bak.20250624-123353,${TS_A}.000000000 +0200
rc_art.20250827-085305,${OPC}/etc/rc_art.20250827-085305,${TS_A}.000000000 +0200
rc_art.bak.20251018-093606,${OPC}/etc/rc_art.bak.20251018-093606,${TS_A}.000000000 +0200
rc_art.20251018-093933,${OPC}/etc/rc_art.20251018-093933,${TS_A}.000000000 +0200
rc_art.bak.20250824_08_24,${OPC}/etc/rc_art.bak.20250824_08_24,${TS_A}.000000000 +0200
setenv,${OPC}/etc/setenv,${TS_B}.000000000 +0200
log.xml,${OPC}/home/xbapp_d2/oradiag_xbapp_d2/diag/clients/user_xbapp_d2/host_1599897763_110/alert/log.xml,${TS_C}.000000000 +0200
log.xml,${OPC}/home/xbapp_d2/oradiag_xbapp_d2/diag/clients/user_xbapp_d2/host_3385385914_110/alert/log.xml,${TS_C}.000000000 +0200
check_copy_readiness.sh,${OPC}/home/xbapp_d2/tmp/check_copy_readiness.sh,${TS_C}.000000000 +0200
selective_copy.sh,${OPC}/home/xbapp_d2/tmp/selective_copy.sh,${TS_C}.000000000 +0200
txns.csv,${OPC}/home/xbapp_d2/txns.csv,${TS_C}.000000000 +0200
jks.tomc.inf,${OPC}/security/jks.tomc.inf,${TS_B}.000000000 +0200
convert_cacerts_to_pem.sh,${OPC}/security/pkibot_config/convert_cacerts_to_pem.sh,${TS_B}.000000000 +0200
fat1_mq_jks.pkibot.ini,${OPC}/security/pkibot_config/fat1_mq_jks.pkibot.ini,${TS_B}.000000000 +0200
fat1_tomcat_jks.pkibot.ini,${OPC}/security/pkibot_config/fat1_tomcat_jks.pkibot.ini,${TS_B}.000000000 +0200
tmp_fat1_mq.jks.pkibot.ini,${OPC}/security/pkibot_config/tmp_fat1_mq.jks.pkibot.ini,${TS_B}.000000000 +0200
tmp_fat1_tomcat_jks.pkibot.ini,${OPC}/security/pkibot_config/tmp_fat1_tomcat_jks.pkibot.ini,${TS_B}.000000000 +0200
uat1_tomcat_jks.pkibot.ini,${OPC}/security/pkibot_config/UAT1/uat1_tomcat_jks.pkibot.ini,${TS_B}.000000000 +0200
uat2_tomcat_jks.pkibot.ini,${OPC}/security/pkibot_config/UAT2/uat2_tomcat_jks.pkibot.ini,${TS_B}.000000000 +0200
sqlnet.ora.2024-10-25-21-35-09,${OPC}/security/wallets/fragtseppltu3a.2025-03-21-09-03-31/sqlnet.ora.2024-10-25-21-35-09,${TS_B}.000000000 +0200
pexb.FRXBP2U_fq.cfg,${OPC}/security/wallets/pexb.FRXBP2U_fq.cfg,${TS_B}.000000000 +0200
crontab.snip,${OPC}/tools/certnanny/mq-opcsvcf2/crontab.snip,${TS_B}.000000000 +0200
certstore-java.cfg,${OPC}/tools/certnanny/mq-opcsvcf2/dbcertnanny/etc/certstore-java.cfg,${TS_B}.000000000 +0200
certstore-secrets.cfg,${OPC}/tools/certnanny/mq-opcsvcf2/dbcertnanny/etc/certstore-secrets.cfg,${TS_B}.000000000 +0200
mq_opcsvcf1_getNextCA.cnf,${OPC}/tools/certnanny/mq-opcsvcf2/dbcertnanny/state/mq_opcsvcf1_getNextCA.cnf,${TS_C}.000000000 +0200
mq_opcsvcf1-tmpkeystore,${OPC}/tools/certnanny/mq-opcsvcf2/dbcertnanny/state/mq_opcsvcf1-tmpkeystore,${TS_C}.000000000 +0200
opcsvcf1.de.db.com_mqofat1.jks,${OPC}/tools/certnanny/mq-opcsvcf2/kst/opcsvcf1.de.db.com_mqofat1.jks,${TS_C}.000000000 +0200
opcsvcf1.de.db.com_mqofat1.jks.backup,${OPC}/tools/certnanny/mq-opcsvcf2/kst/opcsvcf1.de.db.com_mqofat1.jks.backup,${TS_C}.000000000 +0200
certstore-java.cfg,${OPC}/tools/certnanny/tc-opcsvcf2/dbcertnanny/etc/certstore-java.cfg,${TS_B}.000000000 +0200
certstore-secrets.cfg,${OPC}/tools/certnanny/tc-opcsvcf2/dbcertnanny/etc/certstore-secrets.cfg,${TS_B}.000000000 +0200
tc_opcsvcf1_getCA.cnf,${OPC}/tools/certnanny/tc-opcsvcf2/dbcertnanny/state/tc_opcsvcf1_getCA.cnf,${TS_C}.000000000 +0200
tc_opcsvcf1_getNextCA.cnf,${OPC}/tools/certnanny/tc-opcsvcf2/dbcertnanny/state/tc_opcsvcf1_getNextCA.cnf,${TS_C}.000000000 +0200
fragtseppltu3a.de.db.com_tcfat1.jks,${OPC}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat1.jks,${TS_C}.000000000 +0200
fragtseppltu3a.de.db.com_tcfat1.jks.backup,${OPC}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat1.jks.backup,${TS_C}.000000000 +0200
fragtseppltu3a.de.db.com_tcfat1.jks_feb_18_2026_bkp,${OPC}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat1.jks_feb_18_2026_bkp,${TS_C}.000000000 +0200
certstore-secrets.cfg,${OPC}/tools/certnanny/templates/certstore-secrets.cfg,${TS_B}.000000000 +0200
crontab.snip,${OPC}/tools/certnanny/templates/crontab.snip,${TS_B}.000000000 +0200
jmsBrowser.sh,${OPC}/tools/mq-tool/jmsBrowser.sh,${TS_B}.000000000 +0200
mq-opcsvcf1,${OPC}/tools/pkibot_working/mq-opcsvcf1,${TS_C}.000000000 +0200
opcPkibot.ini,${OPC}/tools/pkibot_working/mq-opcsvcf1/pkibot_config/opcPkibot.ini,${TS_C}.000000000 +0200
opcPkibot.ini_bkp,${OPC}/tools/pkibot_working/mq-opcsvcf1/pkibot_config/opcPkibot.ini_bkp,${TS_C}.000000000 +0200
tc-opcsvcf1,${OPC}/tools/pkibot_working/tc-opcsvcf1,${TS_C}.000000000 +0200
opcPkibot.ini,${OPC}/tools/pkibot_working/tc-opcsvcf1/pkibot_config/opcPkibot.ini,${TS_C}.000000000 +0200
opcPkibot.ini,${OPC}/tools/pkibot_working/tc-opcsvcu5/pkibot_config/opcPkibot.ini,${TS_C}.000000000 +0200
opcsvcf1.xml,${OPC}/tools/sftpserver/configs/opcsvcf1.xml,${TS_C}.000000000 +0200
sftpserver,${OPC}/tools/sftpserver/sftpserver,${TS_B}.000000000 +0200
cron.snip,${OPC}/tools/simulators/cron/cron.snip,${TS_B}.000000000 +0200
hostname,${OPC}/tools/ucd/hostname,${TS_B}.000000000 +0200
readme,${OPC}/tools/ucd/readme,${TS_B}.000000000 +0200
agent,${OPC}/tools/ucd/udeploy/ibm-ucdagent/bin/agent,${TS_B}.000000000 +0200
classpath.conf,${OPC}/tools/ucd/udeploy/ibm-ucdagent/bin/classpath.conf,${TS_B}.000000000 +0200
configure-agent,${OPC}/tools/ucd/udeploy/ibm-ucdagent/bin/configure-agent,${TS_B}.000000000 +0200
ibm-ucdagent.bak,${OPC}/tools/ucd/udeploy/ibm-ucdagent/bin/ibm-ucdagent.bak,${TS_B}.000000000 +0200
ibm-ucdagent_control,${OPC}/tools/ucd/udeploy/ibm-ucdagent/bin/ibm-ucdagent_control,${TS_B}.000000000 +0200
ibm-ucdagent-uninstall.sh,${OPC}/tools/ucd/udeploy/ibm-ucdagent/bin/ibm-ucdagent-uninstall.sh,${TS_B}.000000000 +0200
agent,${OPC}/tools/ucd/udeploy/ibm-ucdagent/bin/init/agent,${TS_B}.000000000 +0200
upgrade.out,${OPC}/tools/ucd/udeploy/ibm-ucdagent/bin/upgrade.out,${TS_B}.000000000 +0200
worker-args.conf,${OPC}/tools/ucd/udeploy/ibm-ucdagent/bin/worker-args.conf,${TS_B}.000000000 +0200
installed.properties,${OPC}/tools/ucd/udeploy/ibm-ucdagent/conf/agent/installed.properties,${TS_C}.000000000 +0200
EOF
}

phase_prepare() {
    info "==== PREPARE ===="

    [ -d "$FIXTURE_SRC" ] || die "Fixture source not found: $FIXTURE_SRC"

    # Clean slate for the source copy (mock_build handles its own --reset).
    if [ -d "$TMP_SRC" ]; then
        info "Removing stale source copy: $TMP_SRC"
        rm -rf "$TMP_SRC"
    fi

    mkdir -p "${TEST_BASE}"
    cp -a "${FIXTURE_SRC}/." "${TMP_SRC}"
    info "Fixture copied to ${TMP_SRC}"

    stamp_timestamps
    info "Timestamps applied"

    write_csv
    info "CSV written: ${CSV_FILE} ($(wc -l < "$CSV_FILE") lines incl. header)"

    # This mirrors: bash bin/mock_build.sh --csv ... --source-root ... --mock-root ...
    info "---- mock_build ----"
    bash "${BIN_DIR}/mock_build.sh" \
        --csv "${CSV_FILE}" \
        --source-root "${TMP_SRC}" \
        --mock-root "${MOCK_ROOT}" \
        --reset

    success "PREPARE complete"
    info "  test_base:  ${TEST_BASE}"
    info "  mock_root:  ${MOCK_ROOT}"
    info "  mock_csv:   ${MOCK_ROOT}/mock_input.csv"
    info "  workdir:    ${WORKDIR}"
    info ""
    info "Next: $0 --mode execute"
}

# =============================================================================
#                          PHASE: EXECUTE
# =============================================================================

assert_post_execute() {
    info "---- Post-execute assertions ----"

    local opc="${MOPC}"

    # ---- Security: pkibot_config filename renames (fat1 -> fat2) ----
    assert_path_absent "${opc}/security/pkibot_config/fat1_mq_jks.pkibot.ini" \
        "fat1_mq_jks.pkibot.ini absent (renamed)"
    assert_path_exists "${opc}/security/pkibot_config/fat2_mq_jks.pkibot.ini" \
        "fat2_mq_jks.pkibot.ini present"

    assert_path_absent "${opc}/security/pkibot_config/fat1_tomcat_jks.pkibot.ini" \
        "fat1_tomcat_jks.pkibot.ini absent"
    assert_path_exists "${opc}/security/pkibot_config/fat2_tomcat_jks.pkibot.ini" \
        "fat2_tomcat_jks.pkibot.ini present"

    assert_path_absent "${opc}/security/pkibot_config/tmp_fat1_mq.jks.pkibot.ini" \
        "tmp_fat1_mq.jks.pkibot.ini absent"
    assert_path_exists "${opc}/security/pkibot_config/tmp_fat2_mq.jks.pkibot.ini" \
        "tmp_fat2_mq.jks.pkibot.ini present"

    assert_path_absent "${opc}/security/pkibot_config/tmp_fat1_tomcat_jks.pkibot.ini" \
        "tmp_fat1_tomcat_jks.pkibot.ini absent"
    assert_path_exists "${opc}/security/pkibot_config/tmp_fat2_tomcat_jks.pkibot.ini" \
        "tmp_fat2_tomcat_jks.pkibot.ini present"

    # ---- Server_8_FAT2/bin/setenv.sh content rewrites ----
    local setenv="${opc}/application/Server_8_FAT2/bin/setenv.sh"
    assert_file_lacks    "${setenv}" "FAT1"     "setenv.sh: no FAT1 remaining"
    assert_file_lacks    "${setenv}" "opc_d1"   "setenv.sh: no opc_d1 remaining"
    assert_file_lacks    "${setenv}" "opcsvcf1" "setenv.sh: no opcsvcf1 remaining"
    assert_file_lacks    "${setenv}" "xbapp_d1" "setenv.sh: no xbapp_d1 remaining"
    assert_file_contains "${setenv}" "FAT2"     "setenv.sh: has FAT2"
    assert_file_contains "${setenv}" "opc_d2"   "setenv.sh: has opc_d2"

    # ---- tools/pkibot_working directory renames ----
    assert_path_absent "${opc}/tools/pkibot_working/mq-opcsvcf1" \
        "mq-opcsvcf1 dir absent (renamed)"
    assert_path_exists "${opc}/tools/pkibot_working/mq-opcsvcf2" \
        "mq-opcsvcf2 dir present"

    assert_path_absent "${opc}/tools/pkibot_working/tc-opcsvcf1" \
        "tc-opcsvcf1 dir absent (renamed)"
    assert_path_exists "${opc}/tools/pkibot_working/tc-opcsvcf2" \
        "tc-opcsvcf2 dir present"

    # ---- bin/env/bld.proxy.FAT1 symlink rename ----
    assert_path_absent "${opc}/bin/env/bld.proxy.FAT1" \
        "bld.proxy.FAT1 symlink absent (renamed)"
    assert_path_exists "${opc}/bin/env/bld.proxy.FAT2" \
        "bld.proxy.FAT2 symlink present"
    assert_symlink_target "${opc}/bin/env/bld.proxy.FAT2" "bld.proxy" \
        "bld.proxy.FAT2 target unchanged"

    # ---- tools/sftpserver/configs/opcsvcf1.xml rename ----
    assert_path_absent "${opc}/tools/sftpserver/configs/opcsvcf1.xml" \
        "opcsvcf1.xml absent (renamed)"
    assert_path_exists "${opc}/tools/sftpserver/configs/opcsvcf2.xml" \
        "opcsvcf2.xml present"

    # ---- certnanny/mq-opcsvcf2 state file renames ----
    assert_path_absent "${opc}/tools/certnanny/mq-opcsvcf2/dbcertnanny/state/mq_opcsvcf1_getNextCA.cnf" \
        "mq_opcsvcf1_getNextCA.cnf absent (renamed)"
    assert_path_exists "${opc}/tools/certnanny/mq-opcsvcf2/dbcertnanny/state/mq_opcsvcf2_getNextCA.cnf" \
        "mq_opcsvcf2_getNextCA.cnf present"

    assert_path_absent "${opc}/tools/certnanny/mq-opcsvcf2/dbcertnanny/state/mq_opcsvcf1-tmpkeystore" \
        "mq_opcsvcf1-tmpkeystore absent (renamed)"
    assert_path_exists "${opc}/tools/certnanny/mq-opcsvcf2/dbcertnanny/state/mq_opcsvcf2-tmpkeystore" \
        "mq_opcsvcf2-tmpkeystore present"

    # ---- certnanny/mq-opcsvcf2 kst file renames ----
    assert_path_absent "${opc}/tools/certnanny/mq-opcsvcf2/kst/opcsvcf1.de.db.com_mqofat1.jks" \
        "opcsvcf1.de.db.com_mqofat1.jks absent (renamed)"
    assert_path_exists "${opc}/tools/certnanny/mq-opcsvcf2/kst/opcsvcf2.de.db.com_mqofat2.jks" \
        "opcsvcf2.de.db.com_mqofat2.jks present"

    assert_path_absent "${opc}/tools/certnanny/mq-opcsvcf2/kst/opcsvcf1.de.db.com_mqofat1.jks.backup" \
        "opcsvcf1.de.db.com_mqofat1.jks.backup absent (renamed)"
    assert_path_exists "${opc}/tools/certnanny/mq-opcsvcf2/kst/opcsvcf2.de.db.com_mqofat2.jks.backup" \
        "opcsvcf2.de.db.com_mqofat2.jks.backup present"

    # ---- certnanny/tc-opcsvcf2 state file renames ----
    assert_path_absent "${opc}/tools/certnanny/tc-opcsvcf2/dbcertnanny/state/tc_opcsvcf1_getCA.cnf" \
        "tc_opcsvcf1_getCA.cnf absent"
    assert_path_exists "${opc}/tools/certnanny/tc-opcsvcf2/dbcertnanny/state/tc_opcsvcf2_getCA.cnf" \
        "tc_opcsvcf2_getCA.cnf present"

    assert_path_absent "${opc}/tools/certnanny/tc-opcsvcf2/dbcertnanny/state/tc_opcsvcf1_getNextCA.cnf" \
        "tc_opcsvcf1_getNextCA.cnf absent"
    assert_path_exists "${opc}/tools/certnanny/tc-opcsvcf2/dbcertnanny/state/tc_opcsvcf2_getNextCA.cnf" \
        "tc_opcsvcf2_getNextCA.cnf present"

    # ---- certnanny/tc-opcsvcf2 kst file renames ----
    assert_path_absent "${opc}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat1.jks" \
        "tcfat1.jks absent"
    assert_path_exists "${opc}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat2.jks" \
        "tcfat2.jks present"

    assert_path_absent "${opc}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat1.jks.backup" \
        "tcfat1.jks.backup absent"
    assert_path_exists "${opc}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat2.jks.backup" \
        "tcfat2.jks.backup present"

    assert_path_absent "${opc}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat1.jks_feb_18_2026_bkp" \
        "tcfat1.jks_feb_18_2026_bkp absent"
    assert_path_exists "${opc}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat2.jks_feb_18_2026_bkp" \
        "tcfat2.jks_feb_18_2026_bkp present"

    # ---- pkibot_working mq-opcsvcf2: content inside renamed dir ----
    assert_file_lacks "${opc}/tools/pkibot_working/mq-opcsvcf2/pkibot_config/opcPkibot.ini" \
        "opcsvcf1" "mq opcPkibot.ini: no opcsvcf1 remaining"
    assert_file_contains "${opc}/tools/pkibot_working/mq-opcsvcf2/pkibot_config/opcPkibot.ini" \
        "opcsvcf2" "mq opcPkibot.ini: has opcsvcf2"

    # ---- UAT files should be untouched ----
    assert_path_exists "${opc}/security/pkibot_config/UAT1/uat1_tomcat_jks.pkibot.ini" \
        "UAT1 file still exists (no fat1 refs)"
    assert_path_exists "${opc}/security/pkibot_config/UAT2/uat2_tomcat_jks.pkibot.ini" \
        "UAT2 file still exists (no fat1 refs)"

    # ---- mtime assertions ----
    assert_mtime_epoch "${setenv}" "${TS_A_EPOCH}" \
        "setenv.sh mtime preserved (TS_A)"
    assert_mtime_epoch "${opc}/bin/env/bld.proxy.FAT2" "${TS_B_EPOCH}" \
        "bld.proxy.FAT2 mtime preserved (TS_B)"
    assert_mtime_epoch "${opc}/security/pkibot_config/fat2_mq_jks.pkibot.ini" "${TS_B_EPOCH}" \
        "fat2_mq_jks.pkibot.ini mtime preserved (TS_B)"
    assert_mtime_epoch "${opc}/tools/pkibot_working/mq-opcsvcf2" "${TS_C_EPOCH}" \
        "pkibot_working/mq-opcsvcf2 dir mtime preserved (TS_C)"
}

phase_execute() {
    info "==== EXECUTE ===="

    local mock_csv="${MOCK_ROOT}/mock_input.csv"
    [ -f "$mock_csv" ] || die "Mock CSV not found: $mock_csv. Run --mode prepare first."

    # This mirrors: bash bin/migrator.sh --mode execute --root ... --csv ... --workdir ...
    bash "${BIN_DIR}/migrator.sh" \
        --mode execute \
        --root "${MOCK_ROOT}" \
        --csv "$mock_csv" \
        --workdir "${WORKDIR}"

    assert_post_execute

    success "EXECUTE complete (${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed)"
    info ""
    info "Next: $0 --mode validate"
}

# =============================================================================
#                          PHASE: VALIDATE
# =============================================================================

phase_validate() {
    info "==== VALIDATE ===="

    # This mirrors: bash bin/validate.sh --root ... --workdir ...
    bash "${BIN_DIR}/validate.sh" \
        --root "${MOCK_ROOT}" \
        --workdir "${WORKDIR}"

    success "VALIDATE complete"
    info ""
    info "Next: $0 --mode resume   (or skip to --mode rollback)"
}

# =============================================================================
#                          PHASE: RESUME
# =============================================================================

phase_resume() {
    info "==== RESUME (re-run execute, expect no-op) ===="

    local mock_csv="${MOCK_ROOT}/mock_input.csv"
    [ -f "$mock_csv" ] || die "Mock CSV not found: $mock_csv"

    bash "${BIN_DIR}/migrator.sh" \
        --mode execute \
        --root "${MOCK_ROOT}" \
        --csv "$mock_csv" \
        --workdir "${WORKDIR}"

    assert_post_execute

    success "RESUME complete — state unchanged (${PASS_COUNT} passed, ${FAIL_COUNT} failed)"
    info ""
    info "Next: $0 --mode rollback"
}

# =============================================================================
#                          PHASE: ROLLBACK
# =============================================================================

assert_post_rollback() {
    info "---- Post-rollback assertions ----"

    local opc="${MOPC}"

    # ---- Security: pkibot_config filenames restored ----
    assert_path_exists "${opc}/security/pkibot_config/fat1_mq_jks.pkibot.ini" \
        "fat1_mq_jks.pkibot.ini restored"
    assert_path_absent "${opc}/security/pkibot_config/fat2_mq_jks.pkibot.ini" \
        "fat2_mq_jks.pkibot.ini absent"

    assert_path_exists "${opc}/security/pkibot_config/fat1_tomcat_jks.pkibot.ini" \
        "fat1_tomcat_jks.pkibot.ini restored"
    assert_path_absent "${opc}/security/pkibot_config/fat2_tomcat_jks.pkibot.ini" \
        "fat2_tomcat_jks.pkibot.ini absent"

    assert_path_exists "${opc}/security/pkibot_config/tmp_fat1_mq.jks.pkibot.ini" \
        "tmp_fat1_mq.jks.pkibot.ini restored"
    assert_path_absent "${opc}/security/pkibot_config/tmp_fat2_mq.jks.pkibot.ini" \
        "tmp_fat2_mq.jks.pkibot.ini absent"

    assert_path_exists "${opc}/security/pkibot_config/tmp_fat1_tomcat_jks.pkibot.ini" \
        "tmp_fat1_tomcat_jks.pkibot.ini restored"
    assert_path_absent "${opc}/security/pkibot_config/tmp_fat2_tomcat_jks.pkibot.ini" \
        "tmp_fat2_tomcat_jks.pkibot.ini absent"

    # ---- setenv.sh content restored ----
    local setenv="${opc}/application/Server_8_FAT2/bin/setenv.sh"
    assert_file_contains "${setenv}" "FAT1"     "setenv.sh: FAT1 restored"
    assert_file_contains "${setenv}" "opc_d1"   "setenv.sh: opc_d1 restored"
    assert_file_contains "${setenv}" "opcsvcf1" "setenv.sh: opcsvcf1 restored"
    assert_file_contains "${setenv}" "xbapp_d1" "setenv.sh: xbapp_d1 restored"

    # ---- tools/pkibot_working dirs restored ----
    assert_path_exists "${opc}/tools/pkibot_working/mq-opcsvcf1" \
        "mq-opcsvcf1 dir restored"
    assert_path_absent "${opc}/tools/pkibot_working/mq-opcsvcf2" \
        "mq-opcsvcf2 dir absent"

    assert_path_exists "${opc}/tools/pkibot_working/tc-opcsvcf1" \
        "tc-opcsvcf1 dir restored"
    assert_path_absent "${opc}/tools/pkibot_working/tc-opcsvcf2" \
        "tc-opcsvcf2 dir absent"

    # ---- bin/env/bld.proxy.FAT1 symlink restored ----
    assert_path_exists "${opc}/bin/env/bld.proxy.FAT1" \
        "bld.proxy.FAT1 symlink restored"
    assert_path_absent "${opc}/bin/env/bld.proxy.FAT2" \
        "bld.proxy.FAT2 symlink absent"
    assert_symlink_target "${opc}/bin/env/bld.proxy.FAT1" "bld.proxy" \
        "bld.proxy.FAT1 target still bld.proxy"

    # ---- opcsvcf1.xml restored ----
    assert_path_exists "${opc}/tools/sftpserver/configs/opcsvcf1.xml" \
        "opcsvcf1.xml restored"
    assert_path_absent "${opc}/tools/sftpserver/configs/opcsvcf2.xml" \
        "opcsvcf2.xml absent"

    # ---- certnanny mq state files restored ----
    assert_path_exists "${opc}/tools/certnanny/mq-opcsvcf2/dbcertnanny/state/mq_opcsvcf1_getNextCA.cnf" \
        "mq_opcsvcf1_getNextCA.cnf restored"
    assert_path_absent "${opc}/tools/certnanny/mq-opcsvcf2/dbcertnanny/state/mq_opcsvcf2_getNextCA.cnf" \
        "mq_opcsvcf2_getNextCA.cnf absent"

    assert_path_exists "${opc}/tools/certnanny/mq-opcsvcf2/dbcertnanny/state/mq_opcsvcf1-tmpkeystore" \
        "mq_opcsvcf1-tmpkeystore restored"
    assert_path_absent "${opc}/tools/certnanny/mq-opcsvcf2/dbcertnanny/state/mq_opcsvcf2-tmpkeystore" \
        "mq_opcsvcf2-tmpkeystore absent"

    # ---- certnanny mq kst files restored ----
    assert_path_exists "${opc}/tools/certnanny/mq-opcsvcf2/kst/opcsvcf1.de.db.com_mqofat1.jks" \
        "opcsvcf1.de.db.com_mqofat1.jks restored"
    assert_path_absent "${opc}/tools/certnanny/mq-opcsvcf2/kst/opcsvcf2.de.db.com_mqofat2.jks" \
        "opcsvcf2.de.db.com_mqofat2.jks absent"

    # ---- certnanny tc state/kst files restored ----
    assert_path_exists "${opc}/tools/certnanny/tc-opcsvcf2/dbcertnanny/state/tc_opcsvcf1_getCA.cnf" \
        "tc_opcsvcf1_getCA.cnf restored"
    assert_path_absent "${opc}/tools/certnanny/tc-opcsvcf2/dbcertnanny/state/tc_opcsvcf2_getCA.cnf" \
        "tc_opcsvcf2_getCA.cnf absent"

    assert_path_exists "${opc}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat1.jks" \
        "tcfat1.jks restored"
    assert_path_absent "${opc}/tools/certnanny/tc-opcsvcf2/kst/fragtseppltu3a.de.db.com_tcfat2.jks" \
        "tcfat2.jks absent"

    # ---- mtime assertions post-rollback ----
    assert_mtime_epoch "${setenv}" "${TS_A_EPOCH}" \
        "setenv.sh mtime preserved after rollback (TS_A)"
    assert_mtime_epoch "${opc}/bin/env/bld.proxy.FAT1" "${TS_B_EPOCH}" \
        "bld.proxy.FAT1 mtime preserved after rollback (TS_B)"
    assert_mtime_epoch "${opc}/security/pkibot_config/fat1_mq_jks.pkibot.ini" "${TS_B_EPOCH}" \
        "fat1_mq_jks.pkibot.ini mtime preserved after rollback (TS_B)"
    assert_mtime_epoch "${opc}/tools/pkibot_working/mq-opcsvcf1" "${TS_C_EPOCH}" \
        "pkibot_working/mq-opcsvcf1 dir mtime preserved after rollback (TS_C)"
}

phase_rollback() {
    info "==== ROLLBACK ===="

    # This mirrors: bash bin/migrator.sh --mode rollback --root ... --workdir ...
    bash "${BIN_DIR}/migrator.sh" \
        --mode rollback \
        --root "${MOCK_ROOT}" \
        --workdir "${WORKDIR}"

    assert_post_rollback

    success "ROLLBACK complete (${PASS_COUNT} passed, ${FAIL_COUNT} failed)"
    info ""
    info "Next: $0 --mode cleanup"
}

# =============================================================================
#                          PHASE: CLEANUP
# =============================================================================

phase_cleanup() {
    info "==== CLEANUP ===="

    # This mirrors: bash bin/migrator.sh --mode cleanup --root ... --workdir ...
    if [ -d "$WORKDIR" ]; then
        bash "${BIN_DIR}/migrator.sh" \
            --mode cleanup \
            --root "${MOCK_ROOT}" \
            --workdir "${WORKDIR}"
    fi

    if [ -d "$TEST_BASE" ]; then
        info "Removing test base: $TEST_BASE"
        rm -rf "$TEST_BASE"
    fi

    success "CLEANUP complete — $TEST_BASE removed"
}

# =============================================================================
#                          SUMMARY
# =============================================================================

print_summary() {
    local total=$((PASS_COUNT + FAIL_COUNT))
    if [ "$total" -eq 0 ]; then return 0; fi
    echo ""
    echo "========================================"
    echo " Assertion summary"
    echo "========================================"
    echo " Total  : ${total}"
    echo " Passed : ${PASS_COUNT}"
    echo " Failed : ${FAIL_COUNT}"
    echo "========================================"
    if [ "${FAIL_COUNT}" -gt 0 ]; then
        echo " RESULT: FAIL"
        echo "========================================"
        return 1
    else
        echo " RESULT: PASS"
        echo "========================================"
        return 0
    fi
}

# =============================================================================
#                              MAIN
# =============================================================================

main() {
    parse_args "$@"
    init_paths
    init_epochs

    info "run_local_test.sh --mode ${MODE}"
    info "  test_base: ${TEST_BASE}"

    case "$MODE" in
        prepare)  phase_prepare ;;
        execute)  phase_execute ;;
        validate) phase_validate ;;
        resume)   phase_resume ;;
        rollback) phase_rollback ;;
        cleanup)  phase_cleanup ;;
        all)
            phase_prepare
            phase_execute
            phase_validate
            phase_resume
            phase_rollback
            phase_cleanup
            ;;
        *) echo "Error: invalid --mode '$MODE'" >&2; usage ;;
    esac

    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
