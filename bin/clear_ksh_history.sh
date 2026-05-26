#!/bin/bash
# =============================================================================
#
# Script:      clear_ksh_history.sh
#
# Description:
#   Clears ksh shell history with validation. Two modes:
#
#     --mode all                     Wipe everything.
#     --mode time --window <window>  Remove entries newer than <window> ago.
#                                    <window> is N + suffix:
#                                       s seconds, m minutes,
#                                       h hours,   d days.
#                                    e.g. --window 4d (last 4 days).
#
#   Both modes:
#     - Take a BEFORE snapshot (file size, format, record count).
#     - Apply the change.
#     - Take an AFTER snapshot.
#     - VALIDATE that the operation succeeded; emit evidence either way.
#
# About ksh history files:
#   - ksh93's HISTFILE (default ~/.sh_history) is a BINARY format: 2-byte
#     magic header 0x83 0xFB, then variable-length records each prefixed
#     by a 0x81 marker byte. There is NO per-record timestamp in the
#     standard on-disk format.
#   - Timestamps shown by `fc -lt` are tracked in the running shell's
#     in-memory history table, not the file. So the time-based mode is
#     best-effort: it can only filter entries that have timestamps in
#     the in-memory representation we read via a spawned ksh.
#   - pdksh / mksh use a different (often plain text) format. The script
#     detects format and adapts.
#
# Important limitations:
#   - The script edits the HISTFILE on disk. Your CURRENT interactive shell
#     still has its in-memory history. To drop that too: run
#       HISTSIZE=0; HISTSIZE=1000
#     in your interactive shell, or `exec ksh` for a fresh process.
#   - Multi-line commands (e.g. multi-line for-loops) may not survive
#     the rebuild in time mode due to single-line replay semantics.
#   - If your ksh's `fc -lt` does not emit timestamps, time mode fails
#     with a clear diagnostic instead of silently keeping bad entries.
#
# Linux/GNU only (stat -c, date -d, od, head -c).
#
# =============================================================================

set -euo pipefail

MODE=""
WINDOW=""
HISTFILE_PATH=""
DRY_RUN=0
VERBOSE=0

usage() {
    cat >&2 <<EOF
Usage:
  $0 --mode all  [--histfile PATH] [--dry-run] [--verbose]
  $0 --mode time --window <N{s|m|h|d}> [--histfile PATH] [--dry-run] [--verbose]

REQUIRED:
  --mode all                  Wipe the entire ksh history file.
  --mode time --window WINDOW Remove entries newer than WINDOW ago.
                              WINDOW is a positive integer + suffix:
                                 30s  (seconds)
                                 15m  (minutes)
                                 12h  (hours)
                                 4d   (days)

OPTIONAL:
  --histfile PATH             Path to the ksh history file.
                              Default: \$HISTFILE if set, else \$HOME/.sh_history.
  --dry-run                   Compute and report; no writes.
  --verbose                   Show samples of kept/dropped entries.

EXAMPLES:
  $0 --mode all
  $0 --mode all --dry-run
  $0 --mode time --window 4d
  $0 --mode time --window 12h --verbose
  $0 --mode time --window 30m --dry-run

EXIT CODES:
  0 — operation succeeded and validation passed.
  1 — operation failed, validation failed, or argument error.

NOTE:
  Edits the HISTFILE on disk only. Your current interactive shell's
  in-memory history is unchanged. Run 'HISTSIZE=0; HISTSIZE=1000' in
  your shell to drop it, or 'exec ksh' for a fresh shell.
EOF
    exit 1
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

if [ "$#" -eq 0 ]; then usage; fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)     MODE="$2"; shift 2 ;;
        --window)   WINDOW="$2"; shift 2 ;;
        --histfile) HISTFILE_PATH="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --verbose)  VERBOSE=1; shift ;;
        -h|--help)  usage ;;
        *) echo "Error: unknown argument '$1'" >&2; usage ;;
    esac
done

case "$MODE" in
    all)  ;;
    time) [ -n "$WINDOW" ] || { echo "Error: --mode time requires --window" >&2; usage; } ;;
    *)    echo "Error: --mode must be 'all' or 'time'" >&2; usage ;;
esac

if [ -z "$HISTFILE_PATH" ]; then
    HISTFILE_PATH="${HISTFILE:-$HOME/.sh_history}"
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# parse_window_to_seconds <N{s|m|h|d}>
# Echoes the equivalent number of seconds. Fails loudly on bad format.
parse_window_to_seconds() {
    local w="$1"
    local num="${w%[smhd]}"
    local suffix="${w#$num}"
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ -z "$suffix" ]; then
        echo "Error: bad window '$w' (expected N + s/m/h/d, e.g. 4d)" >&2
        return 1
    fi
    case "$suffix" in
        s) printf '%s\n' "$num" ;;
        m) printf '%s\n' "$((num * 60))" ;;
        h) printf '%s\n' "$((num * 3600))" ;;
        d) printf '%s\n' "$((num * 86400))" ;;
        *) echo "Error: window suffix must be s/m/h/d: '$w'" >&2; return 1 ;;
    esac
}

# detect_format <file>
# Echoes "empty" | "binary" (ksh93) | "text" (mksh/pdksh) | "missing".
detect_format() {
    local f="$1"
    [ -e "$f" ] || { echo "missing"; return; }
    [ -s "$f" ] || { echo "empty"; return; }
    local magic
    magic=$(head -c 2 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' ')
    if [ "$magic" = "83fb" ]; then
        echo "binary"
    else
        echo "text"
    fi
}

# count_records <file>
# Echoes record count. Detects format and uses appropriate method.
#   binary: count 0x81 marker bytes.
#   text  : count non-blank lines.
count_records() {
    local f="$1"
    local fmt; fmt=$(detect_format "$f")
    case "$fmt" in
        empty|missing) echo 0 ;;
        binary)
            od -An -tx1 "$f" 2>/dev/null \
                | tr -s ' \n' '\n' \
                | grep -c '^81$' \
                || echo 0
            ;;
        text)
            grep -cv '^[[:space:]]*$' "$f" 2>/dev/null || echo 0
            ;;
    esac
}

# snapshot <file> <label>
# Prints a 4-line summary of the current state.
snapshot() {
    local f="$1" label="$2"
    local size records fmt
    if [ -e "$f" ]; then
        size=$(stat -c '%s' "$f" 2>/dev/null || echo "?")
        fmt=$(detect_format "$f")
        records=$(count_records "$f")
    else
        size=0; fmt="missing"; records=0
    fi
    printf '  [%s] file=%s exists=%s format=%s size=%sB records=%s\n' \
        "$label" "$f" "$([ -e "$f" ] && echo yes || echo no)" "$fmt" "$size" "$records"
}

# dump_entries_with_ts <histfile> <out_file>
# Spawns ksh, asks for timestamped history listing, writes to out_file.
# Each line: "EPOCH|||COMMAND" (commands may have leading whitespace
# from fc -ln output — caller should strip).
dump_entries_with_ts() {
    local f="$1" out="$2"
    if ! command -v ksh >/dev/null 2>&1; then
        echo "Error: ksh not found in PATH; cannot use time mode" >&2
        return 1
    fi
    # HISTSIZE huge so ksh loads as many existing entries as possible.
    # -i to enable history; -c to run our fc command and exit.
    HISTSIZE=999999 HISTFILE="$f" ksh -i -c "fc -lnt '%s|||'" 2>/dev/null > "$out" || true
}

# -----------------------------------------------------------------------------
# Header + initial snapshot
# -----------------------------------------------------------------------------

echo "clear_ksh_history.sh"
echo "  mode     : $MODE"
[ "$MODE" = "time" ] && echo "  window   : $WINDOW"
echo "  histfile : $HISTFILE_PATH"
[ "$DRY_RUN" -eq 1 ] && echo "  dry-run  : yes"
echo ""

echo "BEFORE"
snapshot "$HISTFILE_PATH" "before"
echo ""

# Graceful exit if file is missing or empty.
if [ ! -e "$HISTFILE_PATH" ]; then
    echo "History file does not exist. Nothing to do."
    exit 0
fi
if [ ! -s "$HISTFILE_PATH" ]; then
    echo "History file already empty. Nothing to do."
    exit 0
fi

records_before=$(count_records "$HISTFILE_PATH")
size_before=$(stat -c '%s' "$HISTFILE_PATH")

# -----------------------------------------------------------------------------
# Mode: all
# -----------------------------------------------------------------------------

if [ "$MODE" = "all" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY-RUN: would truncate $HISTFILE_PATH ($size_before bytes, $records_before records) to 0 bytes."
        exit 0
    fi

    : > "$HISTFILE_PATH"

    echo "AFTER"
    snapshot "$HISTFILE_PATH" "after"
    echo ""

    size_after=$(stat -c '%s' "$HISTFILE_PATH")
    records_after=$(count_records "$HISTFILE_PATH")

    echo "VALIDATION"
    printf '  records:  %s -> %s   (expected after: 0)\n' "$records_before" "$records_after"
    printf '  size:     %sB -> %sB  (expected after: 0)\n' "$size_before" "$size_after"

    if [ "$size_after" -eq 0 ] && [ "$records_after" -eq 0 ]; then
        echo ""
        echo "RESULT: PASS — history file is now empty."
        echo ""
        echo "Note: your current shell's IN-MEMORY history is unchanged."
        echo "  In your shell, run:  HISTSIZE=0; HISTSIZE=1000"
        echo "  Or to start fresh:   exec ksh"
        exit 0
    else
        echo ""
        echo "RESULT: FAIL — file is not empty after truncation."
        echo ""
        echo "Evidence (first 200 bytes, hex):"
        head -c 200 "$HISTFILE_PATH" | od -An -c | head -20 | sed 's/^/  /'
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Mode: time
# -----------------------------------------------------------------------------

if [ "$MODE" = "time" ]; then
    window_seconds=$(parse_window_to_seconds "$WINDOW") || exit 1
    now_epoch=$(date +%s)
    cutoff_epoch=$((now_epoch - window_seconds))
    cutoff_human=$(date -d "@$cutoff_epoch" '+%Y-%m-%d %H:%M:%S')

    echo "Time filter"
    echo "  now      : $(date -d "@$now_epoch" '+%Y-%m-%d %H:%M:%S')  (epoch $now_epoch)"
    echo "  cutoff   : $cutoff_human  (epoch $cutoff_epoch)"
    echo "  policy   : DROP entries with epoch >= $cutoff_epoch"
    echo ""

    # ---- Dump entries with timestamps ----
    dump_file=$(mktemp)
    survivors_file=$(mktemp)
    replay_file=$(mktemp)
    after_dump=$(mktemp)
    trap 'rm -f "$dump_file" "$survivors_file" "$replay_file" "$after_dump"' EXIT

    if ! dump_entries_with_ts "$HISTFILE_PATH" "$dump_file"; then
        exit 1
    fi

    dump_lines=$(wc -l < "$dump_file" | tr -d ' ')
    if [ "$dump_lines" -eq 0 ]; then
        echo "Could not read any entries via 'ksh -c fc -lnt'."
        echo ""
        echo "Possible reasons:"
        echo "  - Your ksh build does not expose timestamps via fc -lt."
        echo "  - HISTFILE is in a format ksh doesn't recognize."
        echo "  - HISTSIZE constraint loaded zero entries."
        echo ""
        echo "Diagnostic:"
        echo "  - history file format : $(detect_format "$HISTFILE_PATH")"
        echo "  - history file size   : $size_before bytes"
        echo "  - records (by parser) : $records_before"
        echo ""
        echo "Try running interactively in your ksh:"
        echo "  fc -lnt '%s|||' | head -3"
        echo "If that returns nothing, time mode is not viable on your ksh."
        echo "Use --mode all instead."
        exit 1
    fi

    echo "Read $dump_lines entries from in-memory ksh history dump."

    # ---- Filter ----
    # Each input line is "EPOCH|||COMMAND_WITH_POSSIBLE_LEADING_TAB".
    kept=0
    dropped=0
    : > "$survivors_file"
    while IFS= read -r line; do
        epoch="${line%%|||*}"
        cmd="${line#*|||}"
        # Strip leading whitespace from cmd
        cmd="${cmd#"${cmd%%[![:space:]]*}"}"
        # Skip malformed lines (no epoch)
        if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
            continue
        fi
        if [ "$epoch" -lt "$cutoff_epoch" ]; then
            printf '%s\n' "$cmd" >> "$survivors_file"
            kept=$((kept + 1))
        else
            dropped=$((dropped + 1))
        fi
    done < "$dump_file"

    echo "Filter: keep $kept, drop $dropped"
    echo ""

    if [ "$VERBOSE" -eq 1 ]; then
        echo "Sample of entries being dropped (up to 5):"
        awk -F'\\|\\|\\|' -v c="$cutoff_epoch" '
            $1+0 >= c { print; n++; if (n>=5) exit }
        ' "$dump_file" | sed 's/^/  /'
        echo ""
        echo "Sample of entries being kept (up to 5, newest first):"
        awk -F'\\|\\|\\|' -v c="$cutoff_epoch" '
            $1+0 < c { print }
        ' "$dump_file" | tail -5 | sed 's/^/  /'
        echo ""
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY-RUN: would rebuild $HISTFILE_PATH with $kept survivor(s)."
        exit 0
    fi

    if [ "$dropped" -eq 0 ]; then
        echo "No entries matched the drop window; leaving file unchanged."
        exit 0
    fi

    # ---- Rebuild ----
    # Truncate, then replay survivors into a fresh ksh subshell via print -s,
    # which writes them to the new HISTFILE.
    : > "$HISTFILE_PATH"

    # Build a script of `print -s -- '...'` lines with single-quote escaping.
    {
        while IFS= read -r cmd; do
            # Escape single quotes: ' -> '\''
            esc=$(printf '%s' "$cmd" | sed "s/'/'\\\\''/g")
            printf "print -s -- '%s'\n" "$esc"
        done < "$survivors_file"
    } > "$replay_file"

    HISTSIZE=999999 HISTFILE="$HISTFILE_PATH" ksh -i < "$replay_file" >/dev/null 2>&1 || true

    echo "AFTER"
    snapshot "$HISTFILE_PATH" "after"
    echo ""

    records_after=$(count_records "$HISTFILE_PATH")
    size_after=$(stat -c '%s' "$HISTFILE_PATH")

    # ---- Validation: re-read and check no entry has epoch >= cutoff ----
    dump_entries_with_ts "$HISTFILE_PATH" "$after_dump" || true

    bad=0
    bad_samples=()
    while IFS= read -r line; do
        epoch="${line%%|||*}"
        if [[ "$epoch" =~ ^[0-9]+$ ]] && [ "$epoch" -ge "$cutoff_epoch" ]; then
            bad=$((bad + 1))
            if [ ${#bad_samples[@]} -lt 5 ]; then
                bad_samples+=("$line")
            fi
        fi
    done < "$after_dump"

    echo "VALIDATION"
    printf '  records:  %s -> %s   (expected ~%s)\n' "$records_before" "$records_after" "$kept"
    printf '  size:     %sB -> %sB\n' "$size_before" "$size_after"
    printf '  entries newer than cutoff after rebuild: %s\n' "$bad"

    if [ "$bad" -eq 0 ]; then
        echo ""
        echo "RESULT: PASS — no entries newer than cutoff remain."
        echo ""
        echo "Note: your current shell's IN-MEMORY history is unchanged."
        echo "  In your shell, run:  HISTSIZE=0; HISTSIZE=1000"
        echo "  Or to start fresh:   exec ksh"
        exit 0
    else
        echo ""
        echo "RESULT: FAIL — $bad entries newer than the cutoff are still present."
        echo ""
        echo "Evidence (sample, up to 5 offending entries from rebuilt file):"
        for s in "${bad_samples[@]}"; do
            epoch="${s%%|||*}"
            cmd="${s#*|||}"
            cmd="${cmd#"${cmd%%[![:space:]]*}"}"
            ts=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "?")
            printf '  %s  (epoch %s)  %s\n' "$ts" "$epoch" "$cmd"
        done
        exit 1
    fi
fi
