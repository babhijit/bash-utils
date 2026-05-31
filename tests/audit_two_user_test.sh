#!/bin/bash
# =============================================================================
# audit_two_user_test.sh — two-login (opc_d1/opc_d2) end-to-end test of the
# ROLE=fat1 -> ROLE=fat2 manifest handoff in bin/audit_env.sh.
#
# WHY THIS EXISTS:
#   audit_env.sh's correctness hinges on a property a single-user run cannot
#   exercise: when the FAT2 user (opc_d2) cannot read parts of FAT1, the FAT1
#   ground truth must still be COMPLETE (supplied by the opc_d1 manifest pass)
#   and the readability GAP must be measured precisely. This test creates two
#   real unix users, injects files opc_d2 genuinely cannot read/traverse, runs
#   each pass as the correct user, and asserts the exact counts.
#
# RUN (from repo root, on a box with Docker):
#   docker run --rm -v "$PWD":/repo:ro bashutils7:rsync bash /repo/tests/audit_two_user_test.sh
#   (centos:7 base => bash 4.2.46 + GNU coreutils + OpenSSL 1.0.2k, the target runtime)
#
# Must run as root inside the container (it chowns files to two users, then
# `su -`s into each). Read-only on the mounted /repo; all writes go to
# /applications/* (the mock trees) and /tmp/*.
# =============================================================================
set -uo pipefail

# --- locations ---------------------------------------------------------------
BIN=/tmp/bin                       # world-readable copy of the script under test
F1=/applications/opc_d1            # FAT1 (source, owned by opc_d1)
F2=/applications/opc_d2            # FAT2 (target, owned by opc_d2)
HANDOFF=/tmp/fat2_audit_handoff    # FAT1 manifest handoff (shared)
RPT=/tmp/fat2_audit                # LEVEL 2 full, EXCLUDE _backup
RPT_L1=/tmp/fat2_audit_l1          # LEVEL 1 snapshot, EXCLUDE _backup
RPT_SCOPE=/tmp/fat2_audit_scope    # LEVEL 2 SCOPE=security, EXCLUDE _backup
RPT_NOEXCL=/tmp/fat2_audit_noexcl  # LEVEL 2, WITHOUT EXCLUDE

PASSED=0; FAILED=0
pass(){ echo "  PASS: $*"; PASSED=$((PASSED + 1)); }
fail(){ echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
assert_count(){ # file expected label
    local n; n="$(wc -l < "$1" 2>/dev/null || echo -1)"; n="${n// /}"
    if [ "$n" = "$2" ]; then pass "$3 (=$n)"; else fail "$3: expected $2 got $n  [$1]"; fi
}
assert_grep(){ # file pattern label
    if grep -qE -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3: /$2/ not in $1"; fi
}
assert_no_grep(){ # file pattern label
    if grep -qE -- "$2" "$1" 2>/dev/null; then fail "$3: /$2/ unexpectedly in $1"; else pass "$3"; fi
}

echo "=============================================================="
echo " audit_env.sh two-user handoff test   (bash $BASH_VERSION)"
echo "=============================================================="

# --- 0. users + shared group (idempotent) ------------------------------------
getent group  fatshare >/dev/null 2>&1 || groupadd fatshare
getent passwd opc_d1   >/dev/null 2>&1 || useradd -m -G fatshare opc_d1
getent passwd opc_d2   >/dev/null 2>&1 || useradd -m -G fatshare opc_d2

# --- world-readable copy of the script + its sourced data module --------------
# audit_env.sh sources migration_map.sh (the authoritative rewrite map) for the
# fat1 LEVEL=2 expected-rewrite hashing, so both files must sit together.
mkdir -p "$BIN"; cp /repo/bin/audit_env.sh /repo/bin/migration_map.sh "$BIN/"; chmod -R a+rX "$BIN"

# openssl CLI is needed to exercise the cert-decode path. The bashutils7:audit
# image bakes it in; on a vanilla centos:7 it is absent (only libssl ships), so
# cert generation + cert assertions are guarded and SKIP cleanly.
HAVE_OPENSSL=0; command -v openssl >/dev/null 2>&1 && HAVE_OPENSSL=1
[ "$HAVE_OPENSSL" = 1 ] || echo "NOTE: openssl CLI absent — cert-decode assertions will be skipped."

# --- clean slate -------------------------------------------------------------
rm -rf "$F1" "$F2" "$HANDOFF" "$RPT" "$RPT_L1" "$RPT_SCOPE" "$RPT_NOEXCL"
mkdir -p "$F1" "$F2"

# =============================================================================
# 1. Build FAT1 (the known-good source, owned by opc_d1)
# =============================================================================
mkdir -p "$F1/bin" "$F1/conf" "$F1/lib" "$F1/security/private" "$F1/_backup"

# plain-text configs (FAT1 references opc_d1 — that's correct for FAT1)
echo 'export CATALINA_BASE=/applications/opc_d1' > "$F1/bin/setenv.sh"
echo '<Server port="8005" shutdown="SHUTDOWN"><Connector port="8080"/></Server>' > "$F1/conf/server.xml"
echo 'OPCDB=(DESCRIPTION=(ADDRESS=(HOST=db1)))' > "$F1/conf/tnsnames.ora"
echo 'WALLET_LOCATION=/applications/opc_d1/security/wallet' > "$F1/conf/sqlnet.ora"

# REWRITE-AWARE fixtures: three FAT1 configs that all carry the opc_d1 token, so
# the migration SHOULD rewrite each to opc_d2. FAT2 will copy them in three
# different states to exercise MIGRATED_OK / NOT_REWRITTEN / DRIFT.
echo 'server=opc_d1.internal' > "$F1/conf/migrated_ok.properties"
echo 'server=opc_d1.internal' > "$F1/conf/not_rewritten.properties"
echo 'server=opc_d1.internal' > "$F1/conf/drifted.properties"

# binaries (NUL => grep -I skips them => binary-integrity set, not rewrite):
# app.jar will be MISSING in FAT2; common.jar IDENTICAL in FAT2.
printf 'JAR\x00APP-ALPHA'  > "$F1/lib/app.jar"
printf 'JAR\x00COMMON-XYZ' > "$F1/lib/common.jar"

# a real cert (proves decode path) + a keystore that will DIFFER in FAT2
if [ "$HAVE_OPENSSL" = 1 ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/k.tmp \
        -out "$F1/security/server.pem" -days 365 -subj '/CN=fat1.example.com' >/dev/null 2>&1
    rm -f /tmp/k.tmp
fi
printf 'JKS\x00\x01\x02\x03ALPHA' > "$F1/security/keystore.jks"   # binary (NUL) + token-free

# STALE-symlink fixture: the FAT2 'logs' link points at this REAL FAT1 dir, so it
# resolves INTO FAT1 (stale) rather than dangling (broken). Same relpath in both
# trees => not a missing/extra diff.
mkdir -p "$F1/logs"

# PERMISSION INJECTION #1: a secret opc_d2 can SEE but NOT read (0600, opc_d1)
echo 'super-secret-key-material' > "$F1/security/secret.key"
# PERMISSION INJECTION #2: a subtree opc_d2 cannot TRAVERSE (0700 dir, opc_d1)
echo 'hidden-from-opc_d2' > "$F1/security/private/hidden.txt"

# an intentional SHARED symlink to a location outside both trees
mkdir -p /opt/shared
ln -s /opt/shared "$F1/shared"

# _backup: holds OLD config with the FAT1 token + a stale cert. Present in BOTH
# trees so it does NOT create missing/extra — its only effect is pollution that
# EXCLUDE_DIRS must remove (unrewritten count, cert decode).
echo 'CATALINA_BASE=/applications/opc_d1   # stale opc_d1 reference' > "$F1/_backup/old_server.xml"
[ "$HAVE_OPENSSL" = 1 ] && cp "$F1/security/server.pem" "$F1/_backup/old.pem"

# ownership: all of FAT1 -> opc_d1, then lock the two injected items down
chown -R opc_d1:fatshare "$F1"
chmod -R a+rX "$F1"                                   # generally world-readable...
chmod 0600 "$F1/security/secret.key"                  # ...except the secret
chmod 0700 "$F1/security/private"                     # ...and the private subtree

# =============================================================================
# 2. Build FAT2 (the partially-migrated copy, owned by opc_d2)
# =============================================================================
mkdir -p "$F2/bin" "$F2/conf" "$F2/lib" "$F2/security/private" "$F2/_backup"

# UNREWRITTEN: setenv.sh still carries the opc_d1 token (incomplete rewrite)
echo 'export CATALINA_BASE=/applications/opc_d1' > "$F2/bin/setenv.sh"
# conf files correctly rewritten (no opc_d1 token) -> must NOT count as unrewritten
echo '<Server port="9005" shutdown="SHUTDOWN"><Connector port="9080"/></Server>' > "$F2/conf/server.xml"
echo 'OPCDB=(DESCRIPTION=(ADDRESS=(HOST=db2)))' > "$F2/conf/tnsnames.ora"
echo 'WALLET_LOCATION=/applications/opc_d2/security/wallet' > "$F2/conf/sqlnet.ora"
# REWRITE-AWARE fixtures (FAT2 side), one per outcome:
echo 'server=opc_d2.internal'             > "$F2/conf/migrated_ok.properties"   # == expected rewrite -> MIGRATED_OK
echo 'server=opc_d1.internal'             > "$F2/conf/not_rewritten.properties" # == raw FAT1 (token left) -> NOT_REWRITTEN
echo 'server=opc_d2.internal extra=hand'  > "$F2/conf/drifted.properties"       # rewritten + manual edit -> DRIFT
# EXTRA (in FAT2, not FAT1)
echo 'fat2 only' > "$F2/conf/extra_fat2_only.conf"
# lib: common.jar IDENTICAL; app.jar deliberately ABSENT (=> MISSING)
printf 'JAR\x00COMMON-XYZ' > "$F2/lib/common.jar"
# security: keystore DIFFERS; server.pem copied; secret.key + private present
#           as opc_d2-OWNED readable copies (so they are NOT missing; the GAP is
#           strictly about reading the FAT1 side).
printf 'JKS\x00\x01\x02\x03BETA' > "$F2/security/keystore.jks"   # binary, differs => CORRUPT
[ "$HAVE_OPENSSL" = 1 ] && cp "$F1/security/server.pem" "$F2/security/server.pem"
echo 'fat2 own secret' > "$F2/security/secret.key"
echo 'fat2 own hidden' > "$F2/security/private/hidden.txt"
# symlinks: STALE into FAT1, BROKEN, and the intentional SHARED (same as FAT1)
ln -s /applications/opc_d1/logs        "$F2/logs"     # STALE into FAT1
ln -s /applications/opc_d2/nonexistent "$F2/data"     # BROKEN
ln -s /opt/shared                      "$F2/shared"   # SHARED intentional
# _backup mirror (same pollution as FAT1)
echo 'CATALINA_BASE=/applications/opc_d1   # stale opc_d1 reference' > "$F2/_backup/old_server.xml"
[ "$HAVE_OPENSSL" = 1 ] && cp "$F1/security/server.pem" "$F2/_backup/old.pem"

chown -R opc_d2:fatshare "$F2"
chmod -R a+rX "$F2"
# OWNERSHIP BREAKAGE: one FAT2 file left owned by opc_d1
chown opc_d1:fatshare "$F2/conf/server.xml"

# both tree roots traversable by all (read-both, write-own)
chmod 0755 "$F1" "$F2"

ENVCOMMON="FAT1_ROOT=$F1 FAT2_ROOT=$F2 FAT1_USER=opc_d1 FAT2_USER=opc_d2 MANIFEST_DIR=$HANDOFF"
# helper: run the fat1 (opc_d1) then fat2 (opc_d2) pass with matching flags.
run_pass() { # <extra-env-for-both> <report-dir>
    su - opc_d1 -c "$ENVCOMMON $1 ROLE=fat1 bash $BIN/audit_env.sh" || true
    su - opc_d2 -c "$ENVCOMMON $1 ROLE=fat2 REPORT_DIR=$2 bash $BIN/audit_env.sh" || true
}

# =============================================================================
# 3. PHASE FULL — LEVEL=2, EXCLUDE _backup. The exhaustive drill-down.
# =============================================================================
echo; echo "--- PHASE FULL: ROLE=fat1->fat2, LEVEL=2, EXCLUDE _backup ----"
run_pass "LEVEL=2 EXCLUDE_DIRS='_backup'" "$RPT"

echo "[manifest assertions]"
assert_grep "$HANDOFF/fat1_manifest.tsv" 'security/secret\.key'         "manifest captures opc_d2-unreadable secret.key (opc_d1 read it)"
assert_grep "$HANDOFF/fat1_manifest.tsv" 'security/private/hidden\.txt' "manifest captures opc_d2-untraversable private/hidden.txt"
assert_grep "$HANDOFF/fat1_hashes.tsv"   'lib/app\.jar'                 "LEVEL 2 manifest hashes app.jar"
assert_no_grep "$HANDOFF/fat1_manifest.tsv" '_backup'                   "EXCLUDE_DIRS pruned _backup from FAT1 manifest"
if [ "$HAVE_OPENSSL" = 1 ]; then
    assert_grep "$HANDOFF/fat1_certs.txt" 'CN ?= ?fat1.example.com'     "FAT1 cert decoded into manifest"
else
    echo "  SKIP: openssl absent — FAT1 cert decode not asserted"
fi
su - opc_d2 -c "test -r $HANDOFF/fat1_manifest.tsv" && pass "opc_d2 can read the handoff manifest" || fail "opc_d2 cannot read handoff manifest"

echo "[differential]"
assert_count "$RPT/missing_in_fat2.txt" 1 "missing_in_fat2 = {lib/app.jar}"
assert_grep  "$RPT/missing_in_fat2.txt" 'lib/app\.jar' "  -> it is app.jar"
assert_count "$RPT/extra_in_fat2.txt"   2 "extra_in_fat2 = {extra_fat2_only.conf, data}"
assert_count "$RPT/unrewritten.txt"     2 "unrewritten = {bin/setenv.sh, conf/not_rewritten.properties}"
assert_grep  "$RPT/unrewritten.txt"     'setenv\.sh'                "  -> setenv.sh still has token"
assert_grep  "$RPT/unrewritten.txt"     'not_rewritten\.properties' "  -> not_rewritten.properties still has token"

echo "[symlinks]"
assert_count "$RPT/symlinks_stale_into_fat1.txt"    1 "stale-into-FAT1 = {logs}"
assert_count "$RPT/symlinks_broken.txt"             1 "broken = {data}"
assert_count "$RPT/symlinks_shared_intentional.txt" 1 "shared-intentional = {shared}"

echo "[ownership + readability gap]"
assert_count "$RPT/not_owned_by_fat2.txt"           1 "not-owned-by-opc_d2 = {conf/server.xml}"
assert_count "$RPT/gap_unreadable_files.txt"        1 "GAP unreadable files = {security/secret.key}"
assert_grep  "$RPT/gap_unreadable_files.txt" 'security/secret\.key' "  -> it is secret.key"
assert_count "$RPT/gap_unreachable_subtrees.txt"    1 "GAP unreachable = {security/private/hidden.txt}"
assert_grep  "$RPT/gap_unreachable_subtrees.txt" 'security/private/hidden\.txt' "  -> it is private/hidden.txt"

echo "[rewrite-aware compare: text]"
assert_grep "$RPT/audit.txt" 'MIGRATED_OK +conf/migrated_ok\.properties'    "config rewritten correctly -> MIGRATED_OK"
assert_grep "$RPT/audit.txt" 'NOT_REWRITTEN +conf/not_rewritten\.properties' "config left raw -> NOT_REWRITTEN"
assert_grep "$RPT/audit.txt" 'DRIFT/PARTIAL +conf/drifted\.properties'      "config hand-edited -> DRIFT/PARTIAL"
assert_grep "$RPT/audit.txt" 'MIGRATED_OK +conf/sqlnet\.ora'                "wallet path rewritten correctly -> MIGRATED_OK"
echo "[rewrite-aware compare: binary]"
assert_grep "$RPT/audit.txt" 'CORRUPT\(bin\) +security/keystore\.jks'       "keystore differs (binary, never rewritten) -> CORRUPT"
assert_grep "$RPT/audit.txt" 'IDENTICAL +lib/common\.jar'                   "common.jar byte-identical -> IDENTICAL"

echo "[heartbeat stays OFF the report]"
# progress() / count_filter write only to a TTY stderr; in this (non-TTY) run they
# must be fully silent and must NEVER appear in the report file.
assert_no_grep "$RPT/audit.txt" '^  \.\. ' "heartbeat (\\r .. lines) never leaks into audit.txt"

echo "[scorecard + verdict present]"
assert_grep "$RPT/audit.txt" 'SUBSYSTEM SCORECARD'   "subsystem scorecard rendered"
assert_grep "$RPT/audit.txt" 'security'              "  -> security subsystem row present"
assert_grep "$RPT/audit.txt" 'VERDICT'               "heuristic verdict rendered"

echo "[exclude proven symmetric]"
assert_no_grep "$RPT/fat1.paths" '_backup' "FAT1 side: _backup pruned"
assert_no_grep "$RPT/fat2.paths" '_backup' "FAT2 side: _backup pruned"

# =============================================================================
# 4. PHASE SNAP — LEVEL=1 snapshot: structure yes, content NO.
# =============================================================================
echo; echo "--- PHASE SNAP: LEVEL=1 snapshot, EXCLUDE _backup -----------"
run_pass "LEVEL=1 EXCLUDE_DIRS='_backup'" "$RPT_L1"
echo "[structure still exact at LEVEL 1]"
assert_count "$RPT_L1/missing_in_fat2.txt"           1 "L1 missing = 1"
assert_count "$RPT_L1/extra_in_fat2.txt"             2 "L1 extra = 2"
assert_count "$RPT_L1/symlinks_stale_into_fat1.txt"  1 "L1 stale = 1"
assert_count "$RPT_L1/gap_unreadable_files.txt"      1 "L1 GAP unreadable = 1"
assert_grep  "$RPT_L1/audit.txt" 'SUBSYSTEM SCORECARD' "L1 renders the scorecard"
assert_grep  "$RPT_L1/audit.txt" 'VERDICT'             "L1 renders the verdict"
echo "[content SKIPPED at LEVEL 1]"
assert_count   "$RPT_L1/unrewritten.txt" 0              "L1 does NOT content-grep (unrewritten empty)"
assert_no_grep "$RPT_L1/audit.txt" 'REWRITE-AWARE'      "L1 does NOT run the rewrite-aware compare"
assert_no_grep "$RPT_L1/audit.txt" 'MIGRATED_OK'        "L1 emits no rewrite verdicts"
assert_grep    "$RPT_L1/audit.txt" 'n/a \(LEVEL 1'      "L1 summary marks content n/a"
if [ ! -s "$HANDOFF/fat1_hashes.tsv" ]; then pass "L1 manifest computes NO hashes (fast)"; else fail "L1 manifest unexpectedly has hashes"; fi

# =============================================================================
# 5. PHASE SCOPE — LEVEL=2 SCOPE=security: drill ONLY security/.
# =============================================================================
echo; echo "--- PHASE SCOPE: LEVEL=2 SCOPE=security, EXCLUDE _backup ----"
run_pass "LEVEL=2 SCOPE='security' EXCLUDE_DIRS='_backup'" "$RPT_SCOPE"
echo "[structural diff stays whole-tree; content is scoped]"
assert_count   "$RPT_SCOPE/missing_in_fat2.txt" 1     "SCOPE: full-tree differential still finds app.jar"
assert_count   "$RPT_SCOPE/unrewritten.txt"     0     "SCOPE=security: bin/setenv.sh + conf/*.properties OUT of scope (0)"
assert_grep    "$RPT_SCOPE/audit.txt" 'CORRUPT\(bin\) +security/keystore\.jks' "SCOPE: security keystore still compared"
assert_no_grep "$RPT_SCOPE/audit.txt" 'lib/common\.jar'                        "SCOPE=security: lib/common.jar NOT compared (out of scope)"
assert_no_grep "$RPT_SCOPE/audit.txt" 'conf/migrated_ok'                       "SCOPE=security: conf/* rewrite NOT compared (out of scope)"

# =============================================================================
# 6. PHASE NOEXCL — LEVEL=2 without exclude: prove _backup pollutes.
# =============================================================================
echo; echo "--- PHASE NOEXCL: LEVEL=2, NO exclude (negative control) ----"
run_pass "LEVEL=2" "$RPT_NOEXCL"
assert_count "$RPT_NOEXCL/unrewritten.txt" 3 "WITHOUT exclude: unrewritten = 3 (setenv.sh + not_rewritten.properties + _backup/old_server.xml)"
assert_grep  "$RPT_NOEXCL/fat1.paths" '_backup' "WITHOUT exclude: _backup present (pollution confirmed)"

# =============================================================================
echo
echo "=============================================================="
echo " RESULT: $PASSED passed, $FAILED failed"
echo "=============================================================="
[ "$FAILED" -eq 0 ]
