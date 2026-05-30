#!/bin/bash
# =============================================================================
#
# Script:      tests/run_mock_env_test.sh
#
# Description:
#   End-to-end test of the UNIFIED realistic mock env (tests/setup_mock_env.sh).
#   Builds the mock source (fat2 dataset + E1-E7 edges, realistic content),
#   then runs the full pipeline via setup_migrator_test phases:
#     prepare (mock_build) -> execute (migrator) -> [edge + content assertions]
#     -> validate -> [E7 fix_dir_mtimes] -> rollback -> validate-rollback.
#
#   Run inside centos:7 (bash 4.2.46 + GNU coreutils):
#     docker run --rm -v "$PWD":/work -w /work centos:7 bash tests/run_mock_env_test.sh
#
# =============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/bin"
SMT="$BIN/setup_migrator_test.sh"
ROOT=/tmp/mock_src
MOCK=/tmp/mock_f2
WD=/tmp/migration_f2_test
CSV="$ROOT/mock_env.csv"
EDGE_MOCK="${MOCK}${ROOT}/applications/opc_d2/_edge"
EDGE_TS_EPOCH=$(date -d "2020-06-15 12:00:00 +0000" +%s)

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
banner(){ echo; echo "================ $* ================"; }

rm -rf "$MOCK" "$WD"

banner "SETUP — realistic mock source + combined CSV"
bash "$REPO/tests/setup_mock_env.sh" --root "$ROOT" --out "$CSV" --reset 2>&1 | sed 's/^/  /'

banner "PREPARE + EXECUTE"
NONINTERACTIVE=1 bash "$SMT" --mode prepare --csv "$CSV" --source-root "$ROOT" \
    --mock-root "$MOCK" --workdir "$WD" >/tmp/mb.log 2>&1
echo "  prepare exit=$?"; grep -E 'copied:|missing:|failed:' /tmp/mb.log | sed 's/^/    /'
NONINTERACTIVE=1 bash "$SMT" --mode execute --mock-root "$MOCK" --workdir "$WD" >/tmp/mg.log 2>&1
echo "  execute exit=$?"; grep -E 'EXECUTE finished|ERROR' /tmp/mg.log | tail -2 | sed 's/^/    /'

banner "EDGE + CONTENT ASSERTIONS (migrated mock)"
# E2 — spaces in path renamed
[ -f "${EDGE_MOCK}/dir with space/fat2 file.cfg" ] && ok "E2 spaced path renamed" || no "E2 spaced path not renamed"
# E3 — dir + descendant both renamed
[ -d "${EDGE_MOCK}/svc/mq-opcsvcf2" ] && ok "E3 dir renamed (mq-opcsvcf2)" || no "E3 dir not renamed"
[ -f "${EDGE_MOCK}/svc/mq-opcsvcf2/fat2_child.cnf" ] && ok "E3 descendant renamed (fat2_child.cnf)" || no "E3 descendant NOT renamed (silent skip?)"
# E4 — fat2_X content rewritten, fat1_X left
if [ -f "${EDGE_MOCK}/coexist/fat2_mq.pkibot.ini" ] && \
   ! grep -qiE 'fat1|opc_d1|opcsvcf1|xbapp_d1' "${EDGE_MOCK}/coexist/fat2_mq.pkibot.ini"; then
    ok "E4 fat2_mq content fully rewritten (no fat1-family tokens)"
else
    no "E4 fat2_mq missing or still has fat1-family tokens"
fi
[ -f "${EDGE_MOCK}/coexist/fat1_mq.pkibot.ini" ] && ok "E4 fat1_mq left in place (documented redirect)" || no "E4 fat1_mq unexpectedly gone"
# E5 — symlink renamed + target remapped
if [ -L "${EDGE_MOCK}/links/fat2_link" ]; then
    ok "E5 symlink renamed (fat2_link)"
    tgt=$(readlink "${EDGE_MOCK}/links/fat2_link")
    [ "$tgt" = "/applications/opc_d2/security/fat2_mq_jks" ] && ok "E5 target remapped ($tgt)" || no "E5 target NOT remapped ($tgt)"
else
    no "E5 symlink not renamed to fat2_link"
fi
# Realistic CONTENT rewrite — a Tomcat server.xml must be fully rewritten and well-formed-ish
SX=$(find "$MOCK" -name 'server.xml' 2>/dev/null | head -1)
if [ -n "$SX" ]; then
    if ! grep -qiE 'opc_d1|opcsvcf1|xbapp_d1|fat1' "$SX"; then
        ok "realistic XML fully rewritten — no residual fat1-family tokens: ${SX#$MOCK}"
    else
        no "server.xml residual tokens: $(grep -oiE 'opc_d1|opcsvcf1|xbapp_d1|fat1' "$SX" | sort -u | tr '\n' ' ')"
    fi
    grep -q 'opc_d2' "$SX" && ok "realistic XML now carries opc_d2" || no "XML missing opc_d2 post-rewrite"
    grep -q '&amp;' "$SX" && ok "XML entity (&amp;) preserved by sed rewrite" || no "XML &amp; entity mangled"
else
    no "no server.xml found in migrated mock"
fi
# E1 — edge rows live AFTER the blank/whitespace CSV lines; if they migrated, blank-line skip worked end-to-end
[ -d "${EDGE_MOCK}/svc/mq-opcsvcf2" ] && ok "E1 rows after blank/whitespace lines processed (no abort)" || no "E1 blank lines aborted the run"

banner "VALIDATE"
NONINTERACTIVE=1 bash "$SMT" --mode validate --mock-root "$MOCK" --workdir "$WD" >/tmp/val.log 2>&1
vrc=$?
grep -E 'VALIDATE PASSED|VALIDATE FAILED|Rows checked|Passed|Failed|Residual' /tmp/val.log | sed 's/^/    /'
[ "$vrc" -eq 0 ] && ok "validate passed (per-row consistency)" || no "validate failed (exit $vrc)"

banner "E7 — fix_dir_mtimes repairs drifted parent-dir mtimes"
before=$(stat -c '%Y' "${EDGE_MOCK}/mtime" 2>/dev/null || echo 0)
bash "$BIN/fix_dir_mtimes.sh" --root "$EDGE_MOCK" --cutoff "2020-12-31 00:00:00 +0000" >/tmp/fix.log 2>&1
after=$(stat -c '%Y' "${EDGE_MOCK}/mtime" 2>/dev/null || echo 0)
if [ "$before" -gt "$EDGE_TS_EPOCH" ] && [ "$after" = "$EDGE_TS_EPOCH" ]; then
    ok "E7 dir mtime drifted ($before) then repaired to child-max ($after)"
elif [ "$after" = "$EDGE_TS_EPOCH" ]; then
    ok "E7 dir mtime correct after fix ($after)"
else
    no "E7 dir mtime not repaired (before=$before after=$after want=$EDGE_TS_EPOCH)"
fi

banner "ROLLBACK + VALIDATE-ROLLBACK"
NONINTERACTIVE=1 bash "$SMT" --mode rollback --mock-root "$MOCK" --workdir "$WD" >/tmp/rb.log 2>&1
echo "  rollback exit=$?"; grep -E 'Restored [0-9]+ paths|ROLLBACK finished' /tmp/rb.log | tail -1 | sed 's/^/    /'
NONINTERACTIVE=1 bash "$SMT" --mode validate-rollback --source-root "$ROOT" \
    --mock-root "$MOCK" --workdir "$WD" >/tmp/vrb.log 2>&1
vrbrc=$?
grep -E 'rollback validation: pass=|restored mock to source-equivalent|ROLLBACK FAIL' /tmp/vrb.log | tail -3 | sed 's/^/    /'
[ "$vrbrc" -eq 0 ] && ok "validate-rollback passed (mock restored to source-equivalent)" || no "validate-rollback failed (exit $vrbrc)"

banner "SUMMARY"
echo "  PASS: $PASS    FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  RESULT: UNIFIED MOCK ENV TEST PASSED" || echo "  RESULT: FAILED ($FAIL)"
[ "$FAIL" -eq 0 ]
