#!/bin/bash
# =============================================================================
#
# Script:      fix_dir_mtimes.sh
#
# Description:
#   Repairs directory mtimes that were bumped by the migration. For every
#   directory under --root whose own mtime is later than --cutoff:
#     1. Recursively compute the max mtime of all entries inside it.
#     2. If that max is strictly older than the directory's current mtime,
#        set the directory's mtime to that max.
#
#   Processed deepest-first so that when a parent directory is repaired,
#   any of its child directories that were also impacted have already been
#   corrected — the parent's "max content mtime" then reflects the
#   corrected child mtimes, and the fix propagates up the tree.
#
# Why directory mtimes drift during migration:
#   A directory's mtime changes when its DIRECTORY ENTRIES change — i.e.,
#   when something inside is CREATED, DELETED, or RENAMED. Modifying a
#   file's CONTENTS in place does NOT bump the parent dir's mtime.
#   migrator.sh renames files (fat1_X -> fat2_X) and creates rewritten
#   directories, both of which bump the parent's mtime to "now". File
#   mtimes are restored by migrator from the CSV; this script does the
#   same job for the directories the renames touched.
#
# Safety:
#   - --root REQUIRED. Touch operations are scoped under --root by
#     construction (find emits paths under it).
#   - --cutoff REQUIRED. Must parse via GNU `date -d`.
#   - --dry-run prints what would change and touches nothing.
#   - Never bumps a directory's mtime forward — only sets it strictly
#     earlier. If a directory's contents are already at or after the
#     dir's current mtime, the row is skipped (already correct).
#
# Linux/GNU only: stat -c, touch -d "@epoch", find -printf, GNU awk/sort.
#
# =============================================================================

set -euo pipefail

ROOT=""
CUTOFF=""
DRY_RUN=0
VERBOSE=0

usage() {
    cat >&2 <<EOF
Usage: $0 --root PATH --cutoff "DATE" [--dry-run] [--verbose]

REQUIRED:
  --root    PATH    Top of the tree to repair (e.g. /applications/opc_d2).
                    Operations are confined under this directory.
  --cutoff  "DATE"  Anything dated AFTER this is considered "bumped".
                    Any string accepted by GNU date -d works:
                      "2026-05-25 18:00:00"
                      "2026-05-22"
                      "4 days ago"
                    Typically: the timestamp just before the migration ran.

OPTIONAL:
  --dry-run         Print what would change; touch nothing.
  --verbose         Show every directory considered, not just fixed ones.

PHASE 1 (detection):
  Walk --root, list every directory whose own mtime > --cutoff.
  These are the "impacted" directories.

PHASE 2 (repair, deepest first):
  For each impacted directory, compute max(mtime) across ALL its entries
  recursively. If that max is strictly older than the directory's
  current mtime, set the directory's mtime to that max. Deepest first
  means children are corrected before their parents are computed.

EXIT CODES:
  0 — finished cleanly (regardless of whether anything was changed)
  1 — argument or runtime error
EOF
    exit 1
}

# --- Argument parsing --------------------------------------------------------

if [ "$#" -eq 0 ]; then usage; fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)    ROOT="$2"; shift 2 ;;
        --cutoff)  CUTOFF="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        -h|--help) usage ;;
        *) echo "Error: unknown argument '$1'" >&2; usage ;;
    esac
done

[ -n "$ROOT" ]   || { echo "Error: --root is required"   >&2; usage; }
[ -n "$CUTOFF" ] || { echo "Error: --cutoff is required" >&2; usage; }
[ -d "$ROOT" ]   || { echo "Error: --root is not a directory: $ROOT" >&2; exit 1; }

CUTOFF_EPOCH=$(date -d "$CUTOFF" +%s 2>/dev/null) || {
    echo "Error: could not parse --cutoff '$CUTOFF'." >&2
    echo "       Try a format like '2026-05-25 18:00:00' or '4 days ago'." >&2
    exit 1
}
CUTOFF_HUMAN=$(date -d "@$CUTOFF_EPOCH" '+%Y-%m-%d %H:%M:%S')

# Normalize root (trailing slash removed) so identity comparisons later work.
ROOT="${ROOT%/}"
[ -z "$ROOT" ] && ROOT="/"

echo "root   : $ROOT"
echo "cutoff : $CUTOFF_HUMAN  (epoch $CUTOFF_EPOCH)"
[ "$DRY_RUN" -eq 1 ] && echo "mode   : DRY-RUN (no writes)"
echo ""

# --- Phase 1: collect impacted directories -----------------------------------
#
# Emit "<depth>\t<path>\0" for every directory whose own mtime > cutoff.
# Depth = number of slashes in the path; deepest-first sort by depth lets
# children get corrected before their parents are computed.

impacted=$(mktemp)
sorted=$(mktemp)
trap 'rm -f "$impacted" "$sorted"' EXIT

find "$ROOT" -type d -printf '%T@\t%p\0' 2>/dev/null \
    | awk -v RS='\0' -v c="$CUTOFF_EPOCH" -F'\t' '
        {
            n = int($1)
            if (n > c) {
                depth = gsub("/", "/", $2)
                printf "%d\t%s%c", depth, $2, 0
            }
        }
    ' > "$impacted"

# Count NUL-delimited records.
impacted_count=$(tr -cd '\0' < "$impacted" | wc -c | tr -d ' ')
echo "Phase 1: $impacted_count directories with mtime > cutoff"

if [ "$impacted_count" -eq 0 ]; then
    echo "Nothing to do."
    exit 0
fi

# Sort by depth descending (deepest first), then strip the depth field.
sort -z -rn -t$'\t' -k1,1 "$impacted" \
    | awk -v RS='\0' -F'\t' '{ printf "%s%c", $2, 0 }' > "$sorted"

# --- Phase 2: per-directory repair ------------------------------------------

fixed=0
skipped_empty=0
skipped_correct=0
errors=0

while IFS= read -r -d '' dir; do
    # Current mtime of the directory.
    if ! cur=$(stat -c '%Y' "$dir" 2>/dev/null); then
        echo "  ERROR    cannot stat: $dir" >&2
        errors=$((errors + 1))
        continue
    fi

    # Max mtime across every entry inside dir, recursively (lstat semantics).
    # awk reduces the stream to a single integer.
    max_content=$(
        find "$dir" -mindepth 1 -printf '%T@\n' 2>/dev/null \
        | awk '{ x = int($1); if (x > max) max = x } END { print max+0 }'
    )

    if [ -z "$max_content" ] || [ "$max_content" -eq 0 ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            echo "  SKIP     empty dir              : $dir"
        fi
        skipped_empty=$((skipped_empty + 1))
        continue
    fi

    if [ "$max_content" -ge "$cur" ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            cur_h=$(date -d "@$cur" '+%Y-%m-%d %H:%M:%S')
            max_h=$(date -d "@$max_content" '+%Y-%m-%d %H:%M:%S')
            echo "  SKIP     already correct        : $dir  cur=$cur_h  max=$max_h"
        fi
        skipped_correct=$((skipped_correct + 1))
        continue
    fi

    cur_h=$(date -d "@$cur" '+%Y-%m-%d %H:%M:%S')
    new_h=$(date -d "@$max_content" '+%Y-%m-%d %H:%M:%S')

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  DRY-RUN  $dir"
        echo "           was: $cur_h"
        echo "           new: $new_h"
        fixed=$((fixed + 1))
    else
        if touch -d "@$max_content" "$dir" 2>/dev/null; then
            echo "  FIXED    $dir  ($cur_h -> $new_h)"
            fixed=$((fixed + 1))
        else
            echo "  ERROR    touch failed: $dir" >&2
            errors=$((errors + 1))
        fi
    fi
done < "$sorted"

# --- Summary ----------------------------------------------------------------

echo ""
echo "Summary:"
printf "  %-26s : %d\n" "directories impacted"     "$impacted_count"
printf "  %-26s : %d\n" "fixed"                    "$fixed"
printf "  %-26s : %d\n" "skipped (empty)"          "$skipped_empty"
printf "  %-26s : %d\n" "skipped (already correct)" "$skipped_correct"
[ "$errors" -gt 0 ] && printf "  %-26s : %d\n" "errors" "$errors"
[ "$DRY_RUN" -eq 1 ] && echo "  (dry-run; no writes performed)"

[ "$errors" -eq 0 ]
