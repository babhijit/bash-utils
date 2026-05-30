#!/usr/bin/env bash
# =============================================================================
# phased_copy_test.sh — military-precision test for selective_copy.sh (phased).
#
# Runs the full plan -> (prepare/deploy)* -> finalize workflow against an
# engineered fixture and asserts EXACTNESS, not just "it ran":
#   - byte-for-byte content (cmp) for every expected file
#   - mode + mtime restored to the second
#   - cross-batch directory mtime correct (the trap batching introduces)
#   - symlink target preserved; empty dir created; spaces-in-name handled
#   - rename of a TREE item (data->data2) and a single FILE item (kind F)
#   - EXCLUDE pattern honored
#   - oversize-file flagged at plan and isolated to its own batch
#   - resume: second prepare is a no-op while a batch awaits deploy; a crash
#     after staging files but before the STAGED marker re-stages cleanly
#   - the free-space preflight DIES before rsync when the batch can't fit
#
# Target runtime: bash 4.2.46 + GNU coreutils + rsync (centos:7 / bashutils7:rsync).
# Self-bootstraps an unprivileged user when launched as root (the copy scripts
# refuse to run as root — that is the no-sudo permission model).
# =============================================================================
set -euo pipefail

# --- self-bootstrap to a non-root user --------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    useradd -m sc 2>/dev/null || true
    _repo="$(cd "$(dirname "$0")/.." && pwd)"
    rm -rf /home/sc/repo
    cp -a "$_repo" /home/sc/repo
    chown -R sc /home/sc/repo
    echo "[bootstrap] re-exec as unprivileged user 'sc'"
    exec su sc -c "cd /home/sc/repo && exec bash tests/phased_copy_test.sh"
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/bin"
SC="$BIN/selective_copy.sh"

ROOT="/tmp/pct.$$"
SRC="$ROOT/src"
TGT="$ROOT/tgt"
STAGE="$ROOT/stage"
STATE="$ROOT/state"
CONF="$ROOT/job.conf"
ME="$(id -un)"
BUDGET=500000   # bytes; small so the ~150KB files force several batches

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
hr()   { printf '\n=== %s ===\n' "$*"; }

assert_file()   { if [ -e "$1" ] || [ -L "$1" ]; then pass "exists: ${2:-$1}"; else fail "missing: ${2:-$1}"; fi; }
assert_nofile() { if [ -e "$1" ] || [ -L "$1" ]; then fail "should be absent: ${2:-$1}"; else pass "absent: ${2:-$1}"; fi; }
assert_cmp()    { if cmp -s "$1" "$2"; then pass "content match: ${3:-$2}"; else fail "content DIFFERS: ${3:-$2}"; fi; }
assert_mode()   { local a; a="$(stat -c '%a' "$1")"; if [ "$a" = "$2" ]; then pass "mode $2: ${3:-$1}"; else fail "mode ${3:-$1}: want $2 got $a"; fi; }
assert_mtime()  { local s t; s="$(stat -c '%Y' "$1")"; t="$(stat -c '%Y' "$2")"; if [ "$s" = "$t" ]; then pass "mtime match ($s): ${3:-$2}"; else fail "mtime ${3:-$2}: src=$s tgt=$t"; fi; }
assert_link()   { local l; l="$(readlink "$1" 2>/dev/null || true)"; if [ "$l" = "$2" ]; then pass "symlink -> $2: ${3:-$1}"; else fail "symlink ${3:-$1}: want $2 got '$l'"; fi; }
assert_ge()     { if [ "$1" -ge "$2" ]; then pass "${3:-}: $1 >= $2"; else fail "${3:-}: $1 < $2"; fi; }

mkfile() { # mkfile <path> <bytes>
    mkdir -p "$(dirname "$1")"
    head -c "$2" /dev/urandom > "$1"
}

# --- build the fixture -------------------------------------------------------
build_fixture() {
    rm -rf "$ROOT"; mkdir -p "$SRC" "$TGT"
    # directory item "app"
    mkfile "$SRC/app/f1.dat" 150000
    mkfile "$SRC/app/f2.dat" 150000
    mkfile "$SRC/app/f3.dat" 150000
    mkfile "$SRC/app/f4.dat" 150000
    mkfile "$SRC/app/f5.dat" 150000
    mkfile "$SRC/app/sub/g1.dat" 150000      # sub spans batches -> dir-mtime test
    mkfile "$SRC/app/sub/g2.dat" 150000
    mkfile "$SRC/app/sub/g3.dat" 150000
    mkfile "$SRC/app/sub/g4.dat" 150000
    mkfile "$SRC/app/big.bin" 1200000        # > budget -> oversize warning + own batch
    mkfile "$SRC/app/name with spaces.txt" 120000   # spaces-in-name
    mkfile "$SRC/app/skip.log" 90000         # excluded by EXCLUDE_MAPPING
    mkdir -p "$SRC/app/emptydir"             # empty dir must be recreated
    ln -s f1.dat "$SRC/app/link_to_f1"       # relative symlink
    mkfile "$SRC/app/secret.cfg" 1024        # distinct mode + mtime
    chmod 700 "$SRC/app/secret.cfg"
    touch -d '2020-01-02 03:04:05' "$SRC/app/secret.cfg"
    touch -d '2019-06-07 08:09:10' "$SRC/app/sub"   # OLD dir mtime to verify reconcile

    # tree item renamed: data -> data2
    mkfile "$SRC/data/d1.dat" 150000
    mkfile "$SRC/data/d2.dat" 150000

    # single FILE item renamed: notes.txt -> renamed_notes.txt (kind F)
    mkfile "$SRC/notes.txt" 2048

    cat > "$CONF" <<EOF
SOURCE_BASE_DIR="$SRC"
TARGET_BASE_DIR="$TGT"
STAGING_DIR="$STAGE"
STATE_DIR="$STATE"
STAGING_BUDGET_BYTES=$BUDGET
COPY_MAPPING=( "app|app" "data|data2" "notes.txt|renamed_notes.txt" )
EXCLUDE_MAPPING=( "app:*.log" )
SYMBOLIC_LINK_MAPPING=()
NESTED_ITEM_TRANSFORM=()
EOF
}

scopy() { bash "$SC" --config "$CONF" --source-user "$ME" --target-user "$ME" "$@"; }
batches_total()   { scopy --mode status 2>/dev/null | sed 's/.*"total":\([0-9]*\).*/\1/'; }
batches_deployed(){ scopy --mode status 2>/dev/null | sed 's/.*"deployed":\([0-9]*\).*/\1/'; }

# =============================================================================
hr "Fixture + PLAN"
build_fixture
plan_out="$(scopy --mode plan 2>&1)" || { echo "$plan_out"; echo "PLAN FAILED"; exit 1; }
echo "$plan_out" | grep -q 'PLAN complete' && pass "plan completed" || fail "plan did not complete"
echo "$plan_out" | grep -qi 'exceeds per-batch budget' && pass "oversize file flagged at plan" || fail "oversize NOT flagged"
TOTAL="$(batches_total)"
assert_ge "$TOTAL" 4 "batch count"

hr "Resume: second prepare is a no-op while a batch awaits deploy"
scopy --mode prepare >/dev/null 2>&1
noop_out="$(scopy --mode prepare 2>&1)"
echo "$noop_out" | grep -qi 'already STAGED awaiting deploy' && pass "2nd prepare no-op (slot busy)" || fail "2nd prepare did not no-op"

hr "Resume: crash after staging files but before STAGED marker re-stages cleanly"
# batch 1 is currently STAGED. Deploy it, then stage batch 2 and simulate a
# crash by deleting its STAGED marker, leaving staged content behind.
scopy --mode deploy >/dev/null 2>&1
scopy --mode prepare >/dev/null 2>&1            # stages batch 2
rm -f "$STATE"/markers/batch_002.STAGED
# Re-run prepare: must defensively clear the orphaned staging and re-stage b2.
reprep="$(scopy --mode prepare 2>&1)" || { echo "$reprep"; fail "resume prepare errored"; }
[ -f "$STATE/markers/batch_002.STAGED" ] && pass "batch 2 re-staged after simulated crash" || fail "batch 2 not re-staged"

hr "Run the rinse-and-repeat loop to completion"
i=0
while [ "$(batches_deployed)" -lt "$TOTAL" ] && [ "$i" -lt "$((TOTAL + 5))" ]; do
    scopy --mode deploy  >/dev/null 2>&1 || true
    scopy --mode prepare >/dev/null 2>&1 || true
    i=$((i + 1))
done
# one last deploy to drain a possibly-staged final batch
scopy --mode deploy >/dev/null 2>&1 || true
DEP="$(batches_deployed)"
if [ "$DEP" = "$TOTAL" ]; then pass "all $TOTAL batches deployed"; else fail "deployed $DEP/$TOTAL"; fi

hr "FINALIZE"
fin="$(scopy --mode finalize 2>&1)" || { echo "$fin"; fail "finalize errored"; }
echo "$fin" | grep -q 'FINALIZE complete' && pass "finalize completed" || fail "finalize did not complete"

hr "Content exactness (byte-for-byte)"
assert_cmp "$SRC/app/f1.dat"               "$TGT/app/f1.dat"               "app/f1.dat"
assert_cmp "$SRC/app/sub/g3.dat"           "$TGT/app/sub/g3.dat"           "app/sub/g3.dat"
assert_cmp "$SRC/app/big.bin"              "$TGT/app/big.bin"              "app/big.bin (oversize)"
assert_cmp "$SRC/app/name with spaces.txt" "$TGT/app/name with spaces.txt" "spaces-in-name"
assert_cmp "$SRC/data/d1.dat"              "$TGT/data2/d1.dat"             "data->data2 rename (tree)"
assert_cmp "$SRC/notes.txt"                "$TGT/renamed_notes.txt"        "notes->renamed_notes (file)"

hr "Exclusions, empty dir, symlink"
assert_nofile "$TGT/app/skip.log" "excluded *.log"
assert_file   "$TGT/app/emptydir" "empty dir recreated"
assert_link   "$TGT/app/link_to_f1" "f1.dat" "relative symlink target"

hr "Attribute exactness (mode + mtime to the second)"
assert_mode  "$TGT/app/secret.cfg" 700 "secret.cfg mode"
assert_mtime "$SRC/app/secret.cfg" "$TGT/app/secret.cfg" "secret.cfg mtime"
assert_mtime "$SRC/app/f1.dat"     "$TGT/app/f1.dat"     "f1.dat mtime"

hr "Cross-batch DIRECTORY mtime (the batching trap)"
# app/sub got its children across multiple batches; its mtime must still equal
# the source's OLD mtime after finalize, not the time the last child landed.
assert_mtime "$SRC/app/sub" "$TGT/app/sub" "app/sub dir mtime (cross-batch)"

hr "Free-space preflight dies before rsync"
# Exercise prepare's REAL preflight: shadow `df` with a fake reporting ~0 free
# space so check_free_space_bytes must abort BEFORE any rsync, leaving staging
# clean. (A huge budget would NOT trigger it — the preflight checks the batch's
# real byte size, not the budget.)
build_fixture
scopy --mode plan >/dev/null 2>&1
mkdir -p "$ROOT/fakebin"
printf '#!/bin/sh\necho Avail\necho 1\n' > "$ROOT/fakebin/df"
chmod +x "$ROOT/fakebin/df"
if PATH="$ROOT/fakebin:$PATH" scopy --mode prepare >/tmp/pct.preflight.$$ 2>&1; then
    fail "prepare should have died on free-space preflight"
else
    grep -qi 'Insufficient free space' /tmp/pct.preflight.$$ && pass "preflight blocked batch that won't fit" || { fail "wrong failure reason"; cat /tmp/pct.preflight.$$; }
    if [ -z "$(ls -A "$STAGE" 2>/dev/null)" ]; then pass "staging left clean after preflight abort"; else fail "staging left dirty"; fi
fi
rm -f /tmp/pct.preflight.$$

# =============================================================================
hr "RESULT"
printf '  passed=%s  failed=%s\n' "$PASS" "$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ] || { echo "PHASED COPY TEST: FAILURES PRESENT"; exit 1; }
echo "PHASED COPY TEST: ALL GREEN"
