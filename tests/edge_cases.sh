#!/bin/bash
# =============================================================================
#
# Script:      tests/edge_cases.sh
#
# Description:
#   Deliberately adversarial edge-case battery for migrator.sh (+ fix_dir_mtimes).
#   Each case builds a tiny ISOLATED source tree under /tmp/edge/<case>, runs
#   the tool, and asserts post-conditions. Designed to be run inside a
#   bash-4.2 + GNU-coreutils container with the repo at CWD:
#
#     docker run --rm -v "$PWD":/work -w /work centos:7 bash tests/edge_cases.sh
#
#   Roots live under /tmp so migrator treats them as "mock" (no --yes/countdown).
#   NOT set -e: we run every case and tally, so one failure doesn't hide others.
#
#   Cases:
#     E1  blank / whitespace-only CSV lines
#     E2  path containing spaces
#     E3  directory-rename row + a descendant that is also a row (stale path)
#     E4  fat1_X and fat2_X coexisting (redirect — documented behavior)
#     E5  symlink: fat1 in name + dangling target needing remap
#     E6  rollback round-trip restores content + mtime exactly
#     E7  parent-dir mtime drift after a rename, repaired by fix_dir_mtimes.sh
#
# =============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/bin"
TS="2020-06-15 12:00:00 +0000"
TS_EPOCH=$(date -d "$TS" +%s)

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
exists(){ [ -e "$1" ] || [ -L "$1" ]; }
banner(){ echo; echo "==== $* ===="; }

run_migrator(){ # <root> <csv> <label>  -> prints "exit=N"; workdir kept OUTSIDE root
    local root="$1" csv="$2" label="$3" rc=0
    local wd="/tmp/edge_wd/$label"
    mkdir -p "$wd"
    NONINTERACTIVE=1 bash "$BIN/migrator.sh" --mode execute \
        --root "$root" --csv "$csv" --workdir "$wd" >"/tmp/edge_wd/$label.log" 2>&1 || rc=$?
    echo "exit=$rc"
}

rm -rf /tmp/edge /tmp/edge_wd; mkdir -p /tmp/edge /tmp/edge_wd

# -----------------------------------------------------------------------------
banner "E1  blank / whitespace-only CSV lines"
mkdir -p /tmp/edge/e1/d
printf 'opc_d1 fat1 line\n' > /tmp/edge/e1/d/fat1_a.cfg
printf 'opc_d1 fat1 line\n' > /tmp/edge/e1/d/fat1_b.cfg
touch -d "$TS" /tmp/edge/e1/d/fat1_a.cfg /tmp/edge/e1/d/fat1_b.cfg
{
  echo "Name,Absolute_Path,Last_Modified"
  echo "fat1_a.cfg,/tmp/edge/e1/d/fat1_a.cfg,$TS"
  echo ""                                  # blank line
  echo "   "                               # whitespace-only line
  echo "fat1_b.cfg,/tmp/edge/e1/d/fat1_b.cfg,$TS"
} > /tmp/edge/e1/in.csv
e1_rc=$(run_migrator /tmp/edge/e1 /tmp/edge/e1/in.csv e1)
echo "  migrator $e1_rc"
[ "$e1_rc" = "exit=0" ] && ok "E1 migrator survived blank lines (exit 0)" || no "E1 migrator aborted on blank lines ($e1_rc)"
exists /tmp/edge/e1/d/fat2_a.cfg && ok "E1 first row migrated (fat2_a.cfg)"  || no "E1 first row NOT migrated (fat2_a.cfg missing)"
exists /tmp/edge/e1/d/fat2_b.cfg && ok "E1 row AFTER blanks migrated (fat2_b.cfg)" || no "E1 row after blanks NOT migrated (fat2_b.cfg missing)"

# -----------------------------------------------------------------------------
banner "E2  path containing spaces"
mkdir -p "/tmp/edge/e2/dir with space"
printf 'fat1 opc_d1 content\n' > "/tmp/edge/e2/dir with space/fat1 file.cfg"
touch -d "$TS" "/tmp/edge/e2/dir with space/fat1 file.cfg"
{
  echo "Name,Absolute_Path,Last_Modified"
  echo "\"fat1 file.cfg\",\"/tmp/edge/e2/dir with space/fat1 file.cfg\",\"$TS\""
} > /tmp/edge/e2/in.csv
e2_rc=$(run_migrator /tmp/edge/e2 /tmp/edge/e2/in.csv e2)
echo "  migrator $e2_rc"
exists "/tmp/edge/e2/dir with space/fat2 file.cfg" && ok "E2 spaced path migrated (fat2 file.cfg)" || no "E2 spaced path NOT migrated"

# -----------------------------------------------------------------------------
banner "E3  dir-rename row + descendant row (stale path after parent rename)"
mkdir -p /tmp/edge/e3/svc/mq-opcsvcf1
printf 'opcsvcf1 fat1 inside child\n' > /tmp/edge/e3/svc/mq-opcsvcf1/fat1_child.cfg
touch -d "$TS" /tmp/edge/e3/svc/mq-opcsvcf1/fat1_child.cfg /tmp/edge/e3/svc/mq-opcsvcf1
{
  echo "Name,Absolute_Path,Last_Modified"
  echo "mq-opcsvcf1,/tmp/edge/e3/svc/mq-opcsvcf1,$TS"                       # dir FIRST
  echo "fat1_child.cfg,/tmp/edge/e3/svc/mq-opcsvcf1/fat1_child.cfg,$TS"      # child under OLD name
} > /tmp/edge/e3/in.csv
e3_rc=$(run_migrator /tmp/edge/e3 /tmp/edge/e3/in.csv e3)
echo "  migrator $e3_rc"
exists /tmp/edge/e3/svc/mq-opcsvcf2 && ok "E3 dir renamed (mq-opcsvcf2)" || no "E3 dir NOT renamed"
if exists /tmp/edge/e3/svc/mq-opcsvcf2/fat2_child.cfg; then
    ok "E3 descendant ALSO renamed (fat2_child.cfg)"
else
    no "E3 descendant NOT renamed — still fat1_child.cfg (silent SKIP of stale path)"
fi
# residual fat1 token anywhere under e3?
if grep -rIl -e fat1 -e opcsvcf1 /tmp/edge/e3/svc >/dev/null 2>&1; then
    no "E3 residual fat1/opcsvcf1 token remains in content/name under svc/"
else
    ok "E3 no residual fat1/opcsvcf1 token under svc/"
fi

# -----------------------------------------------------------------------------
banner "E4  fat1_X and fat2_X coexist (redirect; documented: rewrite fat2_X, leave fat1_X)"
mkdir -p /tmp/edge/e4/d
printf 'fat1 contents alpha\n' > /tmp/edge/e4/d/fat1_mq.ini
printf 'stray fat1 ref in fat2 file\n' > /tmp/edge/e4/d/fat2_mq.ini
touch -d "$TS" /tmp/edge/e4/d/fat1_mq.ini /tmp/edge/e4/d/fat2_mq.ini
{
  echo "Name,Absolute_Path,Last_Modified"
  echo "fat1_mq.ini,/tmp/edge/e4/d/fat1_mq.ini,$TS"
  echo "fat2_mq.ini,/tmp/edge/e4/d/fat2_mq.ini,$TS"
} > /tmp/edge/e4/in.csv
e4_rc=$(run_migrator /tmp/edge/e4 /tmp/edge/e4/in.csv e4)
echo "  migrator $e4_rc"
if exists /tmp/edge/e4/d/fat2_mq.ini && ! grep -q fat1 /tmp/edge/e4/d/fat2_mq.ini; then
    ok "E4 fat2_mq.ini content rewritten (no fat1)"
else
    no "E4 fat2_mq.ini missing or still has fat1"
fi
exists /tmp/edge/e4/d/fat1_mq.ini && ok "E4 fat1_mq.ini left in place (documented)" || no "E4 fat1_mq.ini unexpectedly gone"

# -----------------------------------------------------------------------------
banner "E5  symlink: fat1 in name + dangling target needing remap"
mkdir -p /tmp/edge/e5/d
ln -s /nowhere/fat1_target/opc_d1 /tmp/edge/e5/d/fat1_link
touch -h -d "$TS" /tmp/edge/e5/d/fat1_link
{
  echo "Name,Absolute_Path,Last_Modified"
  echo "fat1_link,/tmp/edge/e5/d/fat1_link,$TS"
} > /tmp/edge/e5/in.csv
e5_rc=$(run_migrator /tmp/edge/e5 /tmp/edge/e5/in.csv e5)
echo "  migrator $e5_rc"
if [ -L /tmp/edge/e5/d/fat2_link ]; then
    ok "E5 symlink renamed (fat2_link)"
    tgt=$(readlink /tmp/edge/e5/d/fat2_link)
    [ "$tgt" = "/nowhere/fat2_target/opc_d2" ] && ok "E5 target remapped ($tgt)" || no "E5 target NOT remapped ($tgt)"
else
    no "E5 symlink NOT renamed to fat2_link"
fi

# -----------------------------------------------------------------------------
banner "E6  rollback round-trip restores content + mtime exactly"
mkdir -p /tmp/edge/e6/d
printf 'opc_d1 fat1 original\n' > /tmp/edge/e6/d/fat1_r.cfg
touch -d "$TS" /tmp/edge/e6/d/fat1_r.cfg
pre_sum=$(md5sum /tmp/edge/e6/d/fat1_r.cfg | cut -d' ' -f1)
pre_mtime=$(stat -c '%Y' /tmp/edge/e6/d/fat1_r.cfg)
{
  echo "Name,Absolute_Path,Last_Modified"
  echo "fat1_r.cfg,/tmp/edge/e6/d/fat1_r.cfg,$TS"
} > /tmp/edge/e6/in.csv
run_migrator /tmp/edge/e6 /tmp/edge/e6/in.csv e6 >/dev/null
NONINTERACTIVE=1 bash "$BIN/migrator.sh" --mode rollback --root /tmp/edge/e6 --workdir /tmp/edge_wd/e6 >/tmp/edge_wd/e6.rb.log 2>&1 || true
if exists /tmp/edge/e6/d/fat1_r.cfg; then
    post_sum=$(md5sum /tmp/edge/e6/d/fat1_r.cfg | cut -d' ' -f1)
    post_mtime=$(stat -c '%Y' /tmp/edge/e6/d/fat1_r.cfg)
    [ "$pre_sum" = "$post_sum" ]   && ok "E6 content restored byte-identical" || no "E6 content differs after rollback"
    [ "$pre_mtime" = "$post_mtime" ] && ok "E6 mtime restored exactly ($post_mtime)" || no "E6 mtime drift ($pre_mtime -> $post_mtime)"
else
    no "E6 original path not restored after rollback"
fi

# -----------------------------------------------------------------------------
banner "E7  parent-dir mtime drift after rename, repaired by fix_dir_mtimes.sh"
mkdir -p /tmp/edge/e7/d
printf 'fat1 opc_d1\n' > /tmp/edge/e7/d/fat1_x.cfg
touch -d "$TS" /tmp/edge/e7/d/fat1_x.cfg
touch -d "$TS" /tmp/edge/e7/d            # parent dir at TS too
{
  echo "Name,Absolute_Path,Last_Modified"
  echo "fat1_x.cfg,/tmp/edge/e7/d/fat1_x.cfg,$TS"
} > /tmp/edge/e7/in.csv
run_migrator /tmp/edge/e7 /tmp/edge/e7/in.csv e7 >/dev/null
dir_mtime_after=$(stat -c '%Y' /tmp/edge/e7/d)
if [ "$dir_mtime_after" != "$TS_EPOCH" ]; then
    ok "E7 demonstrated: parent dir mtime drifted after rename ($TS_EPOCH -> $dir_mtime_after)"
else
    echo "  [note] E7 parent dir mtime did not drift (rename may not have bumped it)"
fi
bash "$BIN/fix_dir_mtimes.sh" --root /tmp/edge/e7 --cutoff "2020-06-15 11:00:00 +0000" >/tmp/edge/e7/fix.log 2>&1 || true
dir_mtime_fixed=$(stat -c '%Y' /tmp/edge/e7/d)
[ "$dir_mtime_fixed" = "$TS_EPOCH" ] && ok "E7 fix_dir_mtimes restored dir mtime to max-child ($TS_EPOCH)" || no "E7 fix_dir_mtimes did not restore dir mtime (got $dir_mtime_fixed)"

# -----------------------------------------------------------------------------
banner "SUMMARY"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  RESULT: ALL EDGE CASES PASS" || echo "  RESULT: $FAIL EDGE ASSERTION(S) FAILED (baseline = current scripts)"
