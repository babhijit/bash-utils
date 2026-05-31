#!/bin/bash
# =============================================================================
#
# Library:     common.sh
#
# Description:
#   Shared utilities for the migration suite (finder, migrator, mock_build,
#   selective_copy, validate, csv_reduce, and their test orchestrators).
#   Source this file at the top of any consumer; do not execute it directly.
#
#   Source idiom (flat hierarchy — all scripts live in the same directory):
#       source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
#   Functions are organized by concern:
#     - Versioning       : require_bash_version
#     - Logging          : log, die, warn, info, success
#     - CSV              : csv_strip_field, csv_read_3col
#     - Path safety      : normalize_path, assert_under_root
#     - Mapping helpers  : apply_path_mapping
#     - Sed safety       : sed_escape_literal, sed_escape_replacement,
#                          replace_content_in_file
#     - Lstat            : lstat_mtime_epoch, lstat_mtime_human, lstat_type,
#                          verify_lstat_match, restore_mtime_from_human
#     - Filesystem       : safe_mkdir_p, ensure_dir_writable,
#                          check_tmpfs_warning, check_free_space_bytes
#     - Confirmation     : confirm_with_countdown
#     - Run id           : new_run_id
#
# Bash version floor: 4.2
#   - Uses `declare -Ar` (4.2+) in consumers.
#   - Uses `eval` for associative-array indirection because namerefs
#     (`declare -n`) require 4.3+ and the target hosts run 4.2.
#
# Conventions consumers MUST follow:
#   - Source this file BEFORE `set -euo pipefail`. The library defines
#     functions only; no side effects at source time.
#   - Treat every function as failing-fast: errors call `die`, which exits.
#   - Logging respects the LOG_FILE env var if set (appended to);
#     stderr always receives the same line.
#   - Logging NEVER writes to stdout. Stdout is reserved for tool output
#     (CSV rows, paths, etc.) so consumers can pipe cleanly.
#
# =============================================================================

# -----------------------------------------------------------------------------
# Versioning
# -----------------------------------------------------------------------------

# require_bash_version <major> <minor>
# Aborts with a clear message if running bash is older than the requirement.
require_bash_version() {
    local req_major="$1"
    local req_minor="$2"
    local cur_major="${BASH_VERSINFO[0]}"
    local cur_minor="${BASH_VERSINFO[1]}"

    if (( cur_major < req_major )) || \
       (( cur_major == req_major && cur_minor < req_minor )); then
        echo "Error: This script requires Bash ${req_major}.${req_minor} or higher. Found: ${BASH_VERSION}." >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
#
# log <level> <message...>
# Writes "<timestamp> - <level> - <message>" to stderr. If LOG_FILE is set,
# also appends to that path. Never writes to stdout.

log() {
    local level="$1"
    shift
    local message="$*"
    local line
    line="$(date +'%Y-%m-%d %H:%M:%S') - ${level} - ${message}"
    if [ -n "${LOG_FILE:-}" ]; then
        # `|| true` so a log-write failure (e.g. disk full, or a file owned by
        # another user) does not kill the caller via set -e / pipefail. The
        # braces are load-bearing: a simple `>> file 2>/dev/null` still lets the
        # *open-for-append* failure print to the real stderr (the redirect is
        # attempted before 2>/dev/null binds); grouping suppresses that too.
        { echo "$line" >> "$LOG_FILE"; } 2>/dev/null || true
    fi
    echo "$line" >&2
}

info()    { log "INFO"    "$@"; }
warn()    { log "WARN"    "$@"; }
success() { log "SUCCESS" "$@"; }

# die <message> [exit_code]
# Logs an ERROR-level message and exits. Default exit code 1.
die() {
    local message="$1"
    local code="${2:-1}"
    log "ERROR" "$message"
    exit "$code"
}

# -----------------------------------------------------------------------------
# Liveness heartbeat (TTY-only; never pollutes logs/reports/output)
# -----------------------------------------------------------------------------
#
# Long find-walks and per-file loops on deep trees run silent for minutes and
# look hung. These print a SINGLE rewriting line to the TERMINAL so the operator
# sees it is alive. They emit ONLY when stderr is a TTY (a complete no-op under
# redirect / pipe / cron, so log files and captured output stay clean) and ONLY
# to stderr — never stdout, never LOG_FILE, never a report. Cost is a modulo test
# per loop iteration — negligible vs the work it wraps. Tune via PROGRESS_EVERY
# (default 200); set PROGRESS_EVERY=0 to disable entirely.
#
# Usage in a loop:   local _n=0
#                    while ...; do _n=$((_n+1)); tick "$_n" "phase: $_n"; ...; done
#                    progress_done
# Usage on a NEWLINE-delimited walk:   find ... | count_filter "label" > file
#   (NEVER insert count_filter into a NUL/-print0 pipeline — use tick in the loop.)
_PROGRESS_TTY="$([ -t 2 ] && echo 1 || true)"
PROGRESS_EVERY="${PROGRESS_EVERY:-200}"
progress()      { { [ -n "$_PROGRESS_TTY" ] && [ "$PROGRESS_EVERY" != 0 ]; } && printf '\r  .. %-72s' "$*" >&2 || true; }
progress_done() { [ -n "$_PROGRESS_TTY" ] && printf '\r%-78s\r' '' >&2 || true; }
tick()          { [ "$PROGRESS_EVERY" = 0 ] && return 0; [ $(( $1 % PROGRESS_EVERY )) -eq 0 ] && progress "$2"; return 0; }
count_filter() {
    if [ -z "$_PROGRESS_TTY" ] || [ "$PROGRESS_EVERY" = 0 ]; then cat; return; fi
    awk -v every="$PROGRESS_EVERY" -v lbl="$1" '
        { print; n++; if (n % every == 0) printf "\r  .. %s: %d", lbl, n > "/dev/stderr" }
        END { printf "\r%-78s\r", "" > "/dev/stderr" }'
}

# -----------------------------------------------------------------------------
# CSV parsing
# -----------------------------------------------------------------------------
#
# csv_strip_field <field>
# Removes surrounding double quotes, leading/trailing whitespace, and a
# trailing carriage return from a single CSV field. Echoes the cleaned value.

csv_strip_field() {
    local field="$1"
    field="${field#"${field%%[![:space:]]*}"}"   # leading whitespace
    field="${field%"${field##*[![:space:]]}"}"   # trailing whitespace
    field="${field%$'\r'}"                       # trailing CR
    field="${field#\"}"                          # leading "
    field="${field%\"}"                          # trailing "
    printf '%s' "$field"
}

# csv_read_3col <csv_file> <callback_function>
# Reads a 3-column CSV (Name,Absolute_Path,Last_Modified), skips the header,
# calls <callback_function> once per row with three arguments: name, path, ts.
#
# Uses awk to split fields with quote awareness, so a "field,with,commas"
# field stays intact. The callback runs in this shell (no subshell) so any
# state mutated inside the callback persists across rows.

csv_read_3col() {
    local csv_file="$1"
    local callback="$2"

    [ -f "$csv_file" ] || die "csv_read_3col: file not found: $csv_file"

    local parsed_file
    parsed_file=$(mktemp)
    # Awk emits tab-separated fields. Walking character by character makes
    # the parser quote-aware without needing a full CSV grammar.
    awk '
        NR == 1 { next }
        {
            line = $0
            sub(/\r$/, "", line)
            n = length(line)
            field = ""; in_quote = 0; out = ""
            for (i = 1; i <= n; i++) {
                c = substr(line, i, 1)
                if (c == "\"") { in_quote = 1 - in_quote; continue }
                if (c == "," && !in_quote) { out = out field "\t"; field = ""; continue }
                field = field c
            }
            out = out field
            print out
        }
    ' "$csv_file" > "$parsed_file"

    local name path ts
    local _row=0
    while IFS=$'\t' read -r name path ts; do
        _row=$((_row + 1)); tick "$_row" "${CSV_PROGRESS_LABEL:-processing CSV rows}: $_row"
        name="$(csv_strip_field "$name")"
        path="$(csv_strip_field "$path")"
        ts="$(csv_strip_field "$ts")"
        # Skip blank / whitespace-only / path-less rows. A stray empty line or
        # a trailing blank line would otherwise hand the callback an empty
        # path, which migrator/mock_build reject via assert_under_root —
        # aborting the entire run mid-way. A row with no Absolute_Path has
        # nothing to act on; warn only if other columns were present (so a
        # genuinely blank line stays silent, a malformed row is surfaced).
        if [ -z "$path" ]; then
            [ -n "$name$ts" ] && warn "csv_read_3col: skipping row with empty Absolute_Path (name='$name')"
            continue
        fi
        "$callback" "$name" "$path" "$ts"
    done < "$parsed_file"
    progress_done
    rm -f "$parsed_file"
}

# -----------------------------------------------------------------------------
# Path safety
# -----------------------------------------------------------------------------
#
# normalize_path <path>
# Echoes the path with duplicate slashes collapsed and trailing slash
# removed. Does NOT resolve symlinks. Used by assert_under_root for prefix
# checks that can't be fooled by `//` or trailing slashes.

normalize_path() {
    local p="$1"
    while [[ "$p" == *//* ]]; do
        p="${p//\/\//\/}"
    done
    if [ "$p" != "/" ]; then
        p="${p%/}"
    fi
    printf '%s' "$p"
}

# assert_under_root <path> <root>
# Dies if <path> is not lexically under <root>. Both are normalized first.
# Migrator's --root guard depends on this: a CSV row pointing outside --root
# in live mode would be a catastrophic operator error.

assert_under_root() {
    local path; path="$(normalize_path "$1")"
    local root; root="$(normalize_path "$2")"
    if [ "$path" != "$root" ] && [[ "$path" != "$root"/* ]]; then
        die "Path '$path' is not under --root '$root'. Refusing to operate." 2
    fi
}

# -----------------------------------------------------------------------------
# Associative-array mapping helpers (bash 4.2 compatible)
# -----------------------------------------------------------------------------
#
# These helpers exist because bash 4.2 lacks namerefs (`declare -n`). They
# use eval-based indirection; callers pass the NAME of an associative array.
# The eval'd contents are array keys/values declared in trusted source
# files, not user input, so the usual eval injection concerns don't apply.
# (tracking.sh's tracking_load_latest() uses the same idiom to populate
# caller-named result arrays.)

# apply_path_mapping <path> <map_name>
# Echoes <path> with all keys of <map_name> substituted by their values.
# Substitution is LITERAL (bash parameter expansion), not regex.
apply_path_mapping() {
    local path="$1"
    local map_name="$2"

    local keys
    eval "keys=( \"\${!${map_name}[@]}\" )"
    local key value
    for key in "${keys[@]}"; do
        eval "value=\${${map_name}[\"\$key\"]}"
        path="${path//$key/$value}"
    done
    printf '%s' "$path"
}

# -----------------------------------------------------------------------------
# Sed-safe content replacement
# -----------------------------------------------------------------------------
#
# sed_escape_literal <string>
# Escapes characters that sed's BRE engine treats as metacharacters in the
# PATTERN side of s|||. The earlier `sed "s|$key|$value|g"` form was unsafe:
# keys containing `.` `*` `[` `^` `$` `\` `|` would be interpreted as regex.

sed_escape_literal() {
    local s="$1"
    s="${s//\\/\\\\}"   # backslash first to avoid escaping the escapes below
    s="${s//./\\.}"
    s="${s//\*/\\*}"
    s="${s//\[/\\[}"
    s="${s//^/\\^}"
    s="${s//\$/\\$}"
    s="${s//|/\\|}"
    s="${s//\//\\/}"
    printf '%s' "$s"
}

# sed_escape_replacement <string>
# Escapes characters that sed treats as special in the REPLACEMENT side
# of s|||: & \ | (delimiter). Newlines are not supported and abort.
sed_escape_replacement() {
    local s="$1"
    if [[ "$s" == *$'\n'* ]]; then
        die "sed_escape_replacement: newline in replacement is not supported"
    fi
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//|/\\|}"
    printf '%s' "$s"
}

# replace_content_in_file <target_file> <map_name>
# Replaces every occurrence of each key in <map_name> with its value, in
# <target_file>. Treats keys as LITERAL strings (regex-safe).
#
# Preserves the original file's inode and lstat metadata: writes the new
# content via `cat > file` (truncate-and-rewrite of the existing inode),
# NOT via `mv tmp file` (which would replace the inode with tmp's).
# Caller must restore mtime separately since the rewrite bumps it.
#
# Skips symlinks and non-regular files. Returns 0 on no-op or success,
# 1 on sed failure (with the file left untouched).
replace_content_in_file() {
    local target_file="$1"
    local map_name="$2"

    [ -L "$target_file" ] && return 0
    [ -f "$target_file" ] || return 0

    local keys
    eval "keys=( \"\${!${map_name}[@]}\" )"
    [ ${#keys[@]} -eq 0 ] && return 0

    local sed_exprs=()
    local key value esc_key esc_val
    for key in "${keys[@]}"; do
        eval "value=\${${map_name}[\"\$key\"]}"
        esc_key="$(sed_escape_literal "$key")"
        esc_val="$(sed_escape_replacement "$value")"
        sed_exprs+=(-e "s|${esc_key}|${esc_val}|g")
    done

    local tmp_file
    tmp_file=$(mktemp)
    if ! sed "${sed_exprs[@]}" "$target_file" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    # Truncate-rewrite preserves inode, perms, owner, ACLs. Only mtime
    # is bumped and must be restored by the caller if preservation is required.
    cat "$tmp_file" > "$target_file"
    rm -f "$tmp_file"
    return 0
}

# -----------------------------------------------------------------------------
# Lstat helpers
# -----------------------------------------------------------------------------
#
# These use GNU `stat -c` which is Linux-only. macOS/BSD use `stat -f`.
# This entire script suite is Linux-only by design (see CLAUDE.md).

# lstat_mtime_epoch <path>
# Echoes mtime as integer seconds since epoch (lstat semantics; no deref).
lstat_mtime_epoch() {
    stat -c '%Y' "$1"
}

# lstat_mtime_human <path>
# Echoes mtime in GNU stat's %y format (sub-second precision, timezone aware).
lstat_mtime_human() {
    stat -c '%y' "$1"
}

# lstat_type <path>
# Echoes one of: file, dir, symlink, other.
lstat_type() {
    if [ -L "$1" ]; then printf 'symlink'
    elif [ -d "$1" ]; then printf 'dir'
    elif [ -f "$1" ]; then printf 'file'
    else printf 'other'
    fi
}

# verify_lstat_match <path_a> <path_b>
# Returns 0 if the two paths have matching type and mtime (epoch-equal).
# Returns 1 with a stderr diff line otherwise. Does NOT compare content.
verify_lstat_match() {
    local a="$1"
    local b="$2"
    local ta tb ma mb
    ta="$(lstat_type "$a")"
    tb="$(lstat_type "$b")"
    if [ "$ta" != "$tb" ]; then
        echo "verify_lstat_match: type mismatch  a=$ta  b=$tb  for $a vs $b" >&2
        return 1
    fi
    ma="$(lstat_mtime_epoch "$a")"
    mb="$(lstat_mtime_epoch "$b")"
    if [ "$ma" != "$mb" ]; then
        echo "verify_lstat_match: mtime mismatch  a=$ma  b=$mb  for $a vs $b" >&2
        return 1
    fi
    return 0
}

# restore_mtime_from_human <path> <human_timestamp>
# Restores mtime on <path> from GNU stat's %y format. Uses -h so symlinks
# are touched in place rather than dereferenced.
restore_mtime_from_human() {
    local path="$1"
    local ts="$2"
    touch -h -d "$ts" "$path"
}

# -----------------------------------------------------------------------------
# Filesystem helpers
# -----------------------------------------------------------------------------

# safe_mkdir_p <dir>
# mkdir -p with a clearer error message on failure.
safe_mkdir_p() {
    local dir="$1"
    if ! mkdir -p "$dir" 2>/dev/null; then
        die "Cannot create directory '$dir' (check permissions and parent existence)"
    fi
}

# ensure_dir_writable <dir>
# Dies if <dir> doesn't exist or isn't writable+executable by the current user.
ensure_dir_writable() {
    local dir="$1"
    [ -d "$dir" ] || die "Directory does not exist: $dir"
    [ -w "$dir" ] || die "Directory not writable: $dir"
    [ -x "$dir" ] || die "Directory not traversable: $dir"
}

# check_tmpfs_warning <dir>
# Warns (does not die) if <dir> appears to live on tmpfs. Backups stored on
# tmpfs are lost across reboots and may be swept by systemd-tmpfiles.
check_tmpfs_warning() {
    local dir="$1"
    local fs_type
    fs_type=$(df --output=fstype "$dir" 2>/dev/null | tail -n1 | tr -d '[:space:]') || true
    if [ "$fs_type" = "tmpfs" ]; then
        warn "Directory '$dir' is on tmpfs. Backups will be LOST on reboot."
        warn "Recommendation: run the full migration in one continuous session and validate before logging out."
    fi
}

# check_free_space_bytes <dir> <required_bytes>
# Dies if available bytes under <dir>'s filesystem are below <required_bytes>.
# Warns and returns 0 if free space cannot be determined.
check_free_space_bytes() {
    local dir="$1"
    local required="$2"
    local available_kb available_bytes
    available_kb=$(df --output=avail "$dir" 2>/dev/null | tail -n1 | tr -d '[:space:]') || true
    if [ -z "$available_kb" ]; then
        warn "Could not determine free space under '$dir'; proceeding without check"
        return 0
    fi
    available_bytes=$(( available_kb * 1024 ))
    if (( available_bytes < required )); then
        die "Insufficient free space under '$dir': have ${available_bytes}B, need ${required}B"
    fi
}

# -----------------------------------------------------------------------------
# Confirmation gate
# -----------------------------------------------------------------------------
#
# confirm_with_countdown <message>
# Prints <message> + a 5-second countdown to stderr. Operator can Ctrl-C
# during the countdown to abort. Live-mode safety gate.
#
# Skipped silently if NONINTERACTIVE=1 — test harnesses set this so they
# don't have to wait for the countdown.

confirm_with_countdown() {
    local message="$1"
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
        info "NONINTERACTIVE=1; skipping countdown gate"
        return 0
    fi
    echo "" >&2
    echo "==============================================================================" >&2
    echo "  $message" >&2
    echo "==============================================================================" >&2
    echo "  Press Ctrl-C within 5 seconds to abort." >&2
    local i
    for i in 5 4 3 2 1; do
        printf "  Starting in %s...\n" "$i" >&2
        sleep 1
    done
    echo "  Proceeding." >&2
    echo "" >&2
}

# -----------------------------------------------------------------------------
# Run id
# -----------------------------------------------------------------------------
#
# new_run_id
# Echoes a sortable, collision-resistant identifier suitable for log file
# names: YYYYMMDD_HHMMSS_<6-hex>. Not used for the workdir path itself —
# the workdir is canonical so that re-runs can resume.

new_run_id() {
    local ts hex
    ts="$(date +'%Y%m%d_%H%M%S')"
    hex="$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s_%s' "$ts" "$hex"
}

# -----------------------------------------------------------------------------
# CSV writing (path-safe complement to csv_strip_field)
# -----------------------------------------------------------------------------
#
# csv_quote_field <value>
# Returns <value> as a quoted CSV field: always wrapped in double quotes, with
# any internal double quote doubled ("" per RFC 4180). Always-quoting keeps the
# writer trivial and the output uniform, and lets a value containing commas,
# spaces, quotes, or leading/trailing whitespace round-trip safely back through
# csv_strip_field on read. Use this whenever emitting a path into a CSV — unix
# paths may legally contain commas and spaces, which an unquoted field corrupts.
#
# Example:
#   csv_quote_field 'a,b "c"'   ->   "a,b ""c"""
csv_quote_field() {
    local field="${1-}"
    field="${field//\"/\"\"}"
    printf '"%s"' "$field"
}

# -----------------------------------------------------------------------------
# Human-readable sizes
# -----------------------------------------------------------------------------
#
# human_bytes <n>
# Formats a byte count as a short human string (e.g. "948.5 MB"). Integer-only
# math — bash has no floating point, and these scripts target bash 4.2 with no
# dependency on bc/python. One decimal digit of precision. Non-numeric or empty
# input is treated as 0. Caps at PB (ample for a multi-GB migration).
human_bytes() {
    local b="${1:-0}"
    case "$b" in *[!0-9]*|'') b=0 ;; esac
    local units=(B KB MB GB TB PB)
    local i=0 v="$b"
    while [ "$v" -ge 1024 ] && [ "$i" -lt 5 ]; do
        v=$(( v / 1024 )); i=$(( i + 1 ))
    done
    if [ "$i" -eq 0 ]; then
        printf '%s %s' "$b" "${units[0]}"
        return 0
    fi
    local divisor=1 k=0
    while [ "$k" -lt "$i" ]; do divisor=$(( divisor * 1024 )); k=$(( k + 1 )); done
    printf '%s.%s %s' "$(( b / divisor ))" "$(( (b % divisor) * 10 / divisor ))" "${units[$i]}"
}

# -----------------------------------------------------------------------------
# Machine-readable event log (JSONL)
# -----------------------------------------------------------------------------
#
# Two logging channels run in parallel through these scripts:
#   - HUMAN  : log()/info()/warn()/success() -> stderr (+ LOG_FILE), timestamped
#   - MACHINE: emit_event()                  -> a .jsonl file, one object/line
# The machine channel exists so a long, batched, multi-session copy can be
# watched/parsed with jq (progress, which batch, failures) without scraping
# human prose. It is intentionally schema-light: every event is a flat object
# of string values with an auto "ts" (epoch seconds); consumers coerce types.

# _json_escape <string>  (module-private)
# Minimal JSON string escaper: backslash, double-quote, tab, newline, CR.
_json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# emit_event <jsonl_file> <key=value> [<key=value> ...]
# Appends ONE JSON object (JSONL) describing an event. A leading "ts" (epoch
# seconds) is added automatically. Keys and values are JSON-escaped; values are
# always emitted as strings (jq numeric coercion handles the rest). Best-effort:
# a logging failure must NEVER abort the copy, so the append is guarded with
# `|| true`. A "key=value" with extra '=' keeps everything after the first '='
# as the value (so paths/URLs survive).
emit_event() {
    local file="${1-}"; shift || true
    [ -n "$file" ] || return 0
    local out ts kv k v
    ts="$(date +%s)"
    out="$(printf '{"ts":"%s"' "$ts")"
    for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        out+="$(printf ',"%s":"%s"' "$(_json_escape "$k")" "$(_json_escape "$v")")"
    done
    out+='}'
    # Braces required so an open-for-append failure (e.g. a file another user
    # owns) is suppressed too, not just printf's stderr. Best-effort by design.
    { printf '%s\n' "$out" >> "$file"; } 2>/dev/null || true
}
