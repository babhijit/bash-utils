#!/bin/bash
# =============================================================================
#
# Script:      tests/selective_copy_test.sh
#
# Description:
#   Exercises the config-driven selective_copy.sh end-to-end with TWO real
#   non-root users, inside a bash-4.2 + GNU-coreutils container run AS ROOT
#   (to create the users). It verifies the parts this refactor changed:
#     - job config is read from --config (base dirs, item list, staging path)
#     - a fixed STAGING_DIR is honored by prepare (no mktemp)
#     - EXCLUDE_MAPPING is applied
#     - identity pinning (--source-user/--target-user) holds
#     - deploy lands files under TARGET_BASE_DIR, owned by the target user,
#       with mtimes preserved
#     - cleanup removes the staging dir
#
#   Assertions are find-based (not exact-path) so they don't depend on the
#   rsync nesting convention; both trees are printed for visual inspection.
#
#   Run from the host:
#     docker run --rm -v "$PWD":/work -w /work centos:7 bash tests/selective_copy_test.sh
#
# =============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Copy bin/ to a world-readable location so the new users can read+source the
# scripts regardless of the bind-mount's ownership/permissions.
SCDIR=/opt/sc
rm -rf "$SCDIR"; mkdir -p "$SCDIR"
cp "$REPO"/bin/*.sh "$SCDIR"/ 2>/dev/null
chmod -R a+rX "$SCDIR"
SC="$SCDIR/selective_copy.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
have(){ find "$1" -name "$2" 2>/dev/null | head -1; }

echo "=== bash -n selective_copy.sh ==="
bash -n "$SC" && echo "  syntax OK" || { echo "  SYNTAX FAIL"; exit 1; }

# --- users ---
id srcu >/dev/null 2>&1 || useradd -m srcu
id tgtu >/dev/null 2>&1 || useradd -m tgtu

# --- source tree (owned by srcu), target base (owned by tgtu) ---
SRC=/srv/opc_d1
TGT=/srv/opc_d2
TS="2021-10-01 14:03:58 +0000"; TS_EPOCH=$(date -d "$TS" +%s)
rm -rf "$SRC" "$TGT" /tmp/test_f2
mkdir -p "$SRC/bin" "$SRC/etc" "$SRC/security" "$TGT"
echo "bld script for opc_d1" > "$SRC/bin/bld.setenv"
echo "should be excluded"    > "$SRC/bin/debug.log"
echo "rc_art opc_d1"         > "$SRC/etc/rc_art"
echo "jks tomc"              > "$SRC/security/jks.tomc.inf"
touch -d "$TS" "$SRC/bin/bld.setenv" "$SRC/etc/rc_art" "$SRC/security/jks.tomc.inf"
chown -R srcu:srcu "$SRC"
chown -R tgtu:tgtu "$TGT"

# --- config (no hardcoded paths in the script; all of this comes from here) ---
CONF=/tmp/sc.conf
cat > "$CONF" <<EOF
SOURCE_BASE_DIR="$SRC"
TARGET_BASE_DIR="$TGT"
STAGING_DIR="/tmp/test_f2/migration"
COPY_MAPPING=( "bin|bin/" "etc|etc/" "security|security/" )
EXCLUDE_MAPPING=( "bin:*.log" )
EOF
chmod 644 "$CONF"

echo ""; echo "=== PREPARE (as srcu) ==="
su srcu -c "bash '$SC' --mode prepare --config '$CONF' --source-user srcu --target-user tgtu" 2>&1 | sed 's/^/    /' || echo "    (prepare exit=$?)"
[ -d /tmp/test_f2/migration ] && ok "fixed staging dir created from config (/tmp/test_f2/migration)" || no "fixed staging dir NOT created"
[ -n "$(have /tmp/test_f2/migration bld.setenv)" ] && ok "bin/bld.setenv staged" || no "bld.setenv not staged"
[ -z "$(have /tmp/test_f2/migration debug.log)" ] && ok "EXCLUDE_MAPPING worked (debug.log not staged)" || no "EXCLUDE_MAPPING failed (debug.log staged)"
echo "  staging tree:"; find /tmp/test_f2/migration -printf '    %y %p\n' 2>/dev/null | grep -v permissions.state | head -30

echo ""; echo "=== identity guard: deploy as WRONG user (srcu) must refuse ==="
if su srcu -c "bash '$SC' --mode deploy --config '$CONF' --target-user tgtu --staging-dir /tmp/test_f2/migration" >/dev/null 2>&1; then
    no "deploy as srcu was NOT refused (identity check broken)"
else
    ok "deploy as srcu refused (identity pinning holds)"
fi

echo ""; echo "=== DEPLOY (as tgtu) ==="
su tgtu -c "bash '$SC' --mode deploy --config '$CONF' --target-user tgtu --staging-dir /tmp/test_f2/migration" 2>&1 | sed 's/^/    /' || echo "    (deploy exit=$?)"
dep_bld=$(have "$TGT" bld.setenv)
dep_rc=$(have "$TGT" rc_art)
dep_jks=$(have "$TGT" jks.tomc.inf)
[ -n "$dep_bld" ] && ok "deployed bld.setenv -> $dep_bld" || no "bld.setenv not deployed"
[ -n "$dep_rc" ]  && ok "deployed rc_art -> $dep_rc"      || no "rc_art not deployed"
[ -n "$dep_jks" ] && ok "deployed jks.tomc.inf"           || no "jks.tomc.inf not deployed"
if [ -n "$dep_bld" ]; then
    owner=$(stat -c '%U' "$dep_bld")
    [ "$owner" = "tgtu" ] && ok "deployed file owned by tgtu" || no "deployed file owner=$owner (expected tgtu)"
fi
if [ -n "$dep_rc" ]; then
    m=$(stat -c '%Y' "$dep_rc")
    [ "$m" = "$TS_EPOCH" ] && ok "mtime preserved on rc_art ($m)" || no "mtime drift on rc_art (have $m want $TS_EPOCH)"
fi
echo "  target tree:"; find "$TGT" -printf '    %y %p\n' 2>/dev/null | head -30

echo ""; echo "=== CLEANUP (as srcu, owns staging) ==="
su srcu -c "bash '$SC' --mode cleanup --staging-dir /tmp/test_f2/migration" 2>&1 | sed 's/^/    /' || echo "    (cleanup exit=$?)"
[ -d /tmp/test_f2/migration ] && no "staging not removed by cleanup" || ok "staging removed by cleanup"

echo ""; echo "=== SUMMARY ==="
echo "  PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  RESULT: selective_copy config-driven test PASSED" || echo "  RESULT: FAILED ($FAIL)"
