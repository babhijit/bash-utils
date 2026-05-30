#!/usr/bin/env bash
# =============================================================================
# migrator_preflight_test.sh — verify migrator's backup free-space preflight.
#
#   - FIRE path: when WORKDIR can't hold the estimated backup footprint, execute
#     aborts in the preflight BEFORE any backup/mutation (no partial state, the
#     source tree untouched). Forced with a fake `df` reporting ~0 free space.
#   - POSITIVE path: a normal execute (real df, ample space) still runs, logs
#     the footprint estimate, and rewrites content — i.e. the guard doesn't
#     break the happy path.
#
# Target runtime: bash 4.2.46 + GNU coreutils (centos:7 / bashutils7:rsync).
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$REPO/bin/migrator.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

R=/tmp/mpf.$$; ROOT=$R/root; WORK=$R/work; CSV=$R/in.csv
rm -rf "$R"; mkdir -p "$ROOT/sub"
echo "uses fat1 and opc_d1 here" > "$ROOT/app.cfg"
echo "another fat1 reference"    > "$ROOT/sub/x.cfg"
printf 'Name,Absolute_Path,Last_Modified\n'                 > "$CSV"
printf 'app.cfg,%s,2021-01-01 00:00:00\n' "$ROOT/app.cfg"  >> "$CSV"
printf 'x.cfg,%s,2021-01-01 00:00:00\n' "$ROOT/sub/x.cfg"  >> "$CSV"

# fake df reporting ~0 free space (only df is shadowed; du stays real)
mkdir -p "$R/fakebin"; printf '#!/bin/sh\necho Avail\necho 1\n' > "$R/fakebin/df"; chmod +x "$R/fakebin/df"

echo "=== FIRE: execute under fake-df must abort on preflight (no backups) ==="
out="$(PATH="$R/fakebin:$PATH" NONINTERACTIVE=1 bash "$M" --mode execute --root "$ROOT" --csv "$CSV" --workdir "$WORK" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    /'
[ "$rc" -ne 0 ] && ok "execute exited non-zero" || no "execute did NOT fail under low space"
echo "$out" | grep -qi 'Insufficient free space' && ok "aborted on free-space preflight" || no "wrong/missing failure reason"
[ -z "$(find "$WORK/backups" -type f 2>/dev/null)" ] && ok "no backups created (aborted before mutation)" || no "backups created despite preflight"
grep -q 'fat1' "$ROOT/app.cfg" && ok "source app.cfg untouched (not rewritten)" || no "source was mutated despite abort"

echo "=== POSITIVE: normal execute (real df) still works with preflight present ==="
rm -rf "$WORK"
out2="$(NONINTERACTIVE=1 bash "$M" --mode execute --root "$ROOT" --csv "$CSV" --workdir "$WORK" 2>&1)"; rc2=$?
echo "$out2" | grep -q 'Estimated backup footprint' && ok "preflight ran + logged footprint" || no "footprint not logged"
[ "$rc2" -eq 0 ] && ok "normal execute succeeded" || { no "normal execute failed (rc=$rc2)"; echo "$out2" | tail -6 | sed 's/^/    /'; }
grep -q 'fat2' "$ROOT/app.cfg" && ok "app.cfg rewritten fat1->fat2" || no "app.cfg not rewritten"

rm -rf "$R"
echo "  PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && echo "MIGRATOR PREFLIGHT TEST: ALL GREEN" || { echo "MIGRATOR PREFLIGHT TEST: FAILED"; exit 1; }
