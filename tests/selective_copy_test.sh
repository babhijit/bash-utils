#!/bin/bash
# =============================================================================
#
# Script:      tests/selective_copy_test.sh
#
# Description:
#   Exercises the PHASED selective_copy.sh end-to-end with TWO real non-root
#   users, inside a bash-4.2 + GNU-coreutils container run AS ROOT (to create
#   the users). This is the companion to tests/phased_copy_test.sh: that one
#   proves the batching LOGIC exhaustively as a single user; THIS one proves the
#   CROSS-USER mechanics a single user cannot:
#     - srcu stages into world-writable /tmp; tgtu (a different user) reads it
#     - the deploy-side DRAIN deletes srcu-owned staged files (needs 0777, not
#       the sticky 1777 — the bug this test guards)
#     - the shared STATE_DIR carries markers written by BOTH users
#     - identity pinning (--source-user/--target-user) holds
#     - deployed files are owned by tgtu, with mode+mtime preserved
#     - directory mtimes are reconciled by finalize
#     - EXCLUDE_MAPPING is honored
#
#   Run from the host (needs rsync, so the bashutils7:rsync image):
#     docker run --rm -v "$PWD":/work -w /work bashutils7:rsync bash tests/selective_copy_test.sh
#
# =============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Copy bin/ to a world-readable location so both new users can read the scripts
# regardless of the bind-mount's ownership.
SCDIR=/opt/sc
rm -rf "$SCDIR"; mkdir -p "$SCDIR"
cp "$REPO"/bin/*.sh "$SCDIR"/ 2>/dev/null
chmod -R a+rX "$SCDIR"
SC="$SCDIR/selective_copy.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

echo "=== bash -n selective_copy.sh ==="
bash -n "$SC" && echo "  syntax OK" || { echo "  SYNTAX FAIL"; exit 1; }

# --- users ---
id srcu >/dev/null 2>&1 || useradd -m srcu
id tgtu >/dev/null 2>&1 || useradd -m tgtu

# --- source tree (owned by srcu), target base (owned by tgtu) ---
SRC=/srv/opc_d1
TGT=/srv/opc_d2
STAGING=/tmp/test_f2/migration
STATE=/tmp/test_f2/migration.state
TS="2021-10-01 14:03:58 +0000"; TS_EPOCH=$(date -d "$TS" +%s)
rm -rf "$SRC" "$TGT" /tmp/test_f2
mkdir -p "$SRC/bin" "$SRC/etc" "$SRC/security" "$TGT"
# ~5 KB files + a small per-batch budget => several batches => the cross-user
# stage/deploy/drain cycle runs multiple times (the point of this test).
head -c 5000 /dev/urandom > "$SRC/bin/bld.setenv"
echo "should be excluded"    > "$SRC/bin/debug.log"
head -c 5000 /dev/urandom > "$SRC/etc/rc_art"
head -c 5000 /dev/urandom > "$SRC/security/jks.tomc.inf"
chmod 640 "$SRC/security/jks.tomc.inf"        # distinct mode to verify restore
touch -d "$TS" "$SRC/bin/bld.setenv" "$SRC/etc/rc_art" "$SRC/security/jks.tomc.inf"
touch -d "$TS" "$SRC/bin" "$SRC/etc" "$SRC/security"   # dir mtimes (test reconcile)
chown -R srcu:srcu "$SRC"
chown -R tgtu:tgtu "$TGT"

# --- config: nothing hardcoded in the script; all of it comes from here ------
CONF=/tmp/sc.conf
cat > "$CONF" <<EOF
SOURCE_BASE_DIR="$SRC"
TARGET_BASE_DIR="$TGT"
STAGING_DIR="$STAGING"
STATE_DIR="$STATE"
STAGING_BUDGET_BYTES=6000
COPY_MAPPING=( "bin|bin" "etc|etc" "security|security" )
EXCLUDE_MAPPING=( "bin:*.log" )
EOF
chmod 644 "$CONF"

as_src(){ su srcu -c "bash '$SC' --config '$CONF' --source-user srcu --target-user tgtu $*"; }
as_tgt(){ su tgtu -c "bash '$SC' --config '$CONF' --target-user tgtu $*"; }
total_b(){ su srcu -c "bash '$SC' --config '$CONF' --mode status" 2>/dev/null | sed 's/.*\"total\":\([0-9]*\).*/\1/'; }
deployed_b(){ su srcu -c "bash '$SC' --config '$CONF' --mode status" 2>/dev/null | sed 's/.*\"deployed\":\([0-9]*\).*/\1/'; }

echo ""; echo "=== PLAN (as srcu) ==="
as_src --mode plan 2>&1 | sed 's/^/    /'
TOTAL="$(total_b)"
[ -n "$TOTAL" ] && [ "$TOTAL" -ge 2 ] && ok "plan produced multiple batches ($TOTAL)" || no "expected >=2 batches, got '$TOTAL'"

echo ""; echo "=== identity guard: deploy as WRONG user (srcu) must refuse ==="
if su srcu -c "bash '$SC' --config '$CONF' --target-user tgtu --mode deploy" >/dev/null 2>&1; then
    no "deploy as srcu was NOT refused (identity check broken)"
else
    ok "deploy as srcu refused (identity pinning holds)"
fi

echo ""; echo "=== rinse-and-repeat: prepare(srcu) / deploy(tgtu) across users ==="
i=0
while [ "$(deployed_b)" -lt "$TOTAL" ] && [ "$i" -lt "$((TOTAL + 5))" ]; do
    as_src --mode prepare >/dev/null 2>&1 || true
    as_tgt --mode deploy  >/dev/null 2>&1 || true
    i=$((i + 1))
done
DEP="$(deployed_b)"
[ "$DEP" = "$TOTAL" ] && ok "all $TOTAL batches deployed across two users" || no "deployed $DEP/$TOTAL"

# The drain must actually empty staging cross-user (0777, not sticky). After the
# loop the last batch may remain; assert that at most one batch's worth lingers
# and that earlier batches were drained (staging is not accumulating).
staged_files=$(find "$STAGING" -type f 2>/dev/null | wc -l)
[ "$staged_files" -le 1 ] && ok "cross-user drain works (staging holds <=1 file, not all)" || no "staging accumulated $staged_files files (drain failed)"

echo ""; echo "=== FINALIZE (as tgtu) ==="
as_tgt --mode finalize 2>&1 | sed 's/^/    /'

echo ""; echo "=== target tree exactness ==="
[ -f "$TGT/bin/bld.setenv" ]        && ok "bld.setenv at TARGET/bin/"        || no "bld.setenv missing"
[ ! -e "$TGT/bin/bin" ]             && ok "no double-nest (TARGET/bin/bin absent)" || no "NESTED: TARGET/bin/bin exists"
[ -f "$TGT/etc/rc_art" ]            && ok "rc_art at TARGET/etc/"            || no "rc_art missing"
[ -f "$TGT/security/jks.tomc.inf" ] && ok "jks.tomc.inf at TARGET/security/" || no "jks.tomc.inf missing"
[ -z "$(find "$TGT" -name 'debug.log' 2>/dev/null)" ] && ok "EXCLUDE honored (debug.log absent)" || no "EXCLUDE failed"
owner=$(stat -c '%U' "$TGT/bin/bld.setenv" 2>/dev/null)
[ "$owner" = "tgtu" ] && ok "deployed file owned by tgtu" || no "owner=$owner (expected tgtu)"
m=$(stat -c '%a' "$TGT/security/jks.tomc.inf" 2>/dev/null)
[ "$m" = "640" ] && ok "file mode restored (jks.tomc.inf=640)" || no "mode drift (have $m want 640)"
fm=$(stat -c '%Y' "$TGT/etc/rc_art" 2>/dev/null)
[ "$fm" = "$TS_EPOCH" ] && ok "file mtime preserved (rc_art=$fm)" || no "file mtime drift (have $fm want $TS_EPOCH)"
dm=$(stat -c '%Y' "$TGT/bin" 2>/dev/null)
[ "$dm" = "$TS_EPOCH" ] && ok "dir mtime reconciled by finalize (bin=$dm)" || no "dir mtime drift on bin (have $dm want $TS_EPOCH)"

echo ""; echo "=== CLEANUP (as srcu, owns staging) ==="
su srcu -c "bash '$SC' --config '$CONF' --mode cleanup --cleanup-state" 2>&1 | sed 's/^/    /' || echo "    (cleanup exit=$?)"
[ -d "$STAGING" ] && no "staging not removed by cleanup" || ok "staging removed by cleanup"

echo ""; echo "=== SUMMARY ==="
echo "  PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  RESULT: selective_copy two-user phased test PASSED" || { echo "  RESULT: FAILED ($FAIL)"; exit 1; }
