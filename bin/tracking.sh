#!/bin/bash
# =============================================================================
#
# Module:      tracking.sh
#
# Description:
#   The migration tracking-file contract: how migrator records progress and
#   how readers load it back.
#
#   The tracking file is an append-only CSV at <workdir>/progress.log:
#       Original_Path,New_Path,Backup_Path,Original_Timestamp,Status
#   Status is one of BACKED_UP, COMPLETED, ROLLED_BACK. The LATEST row for a
#   given Original_Path wins; the file is never rewritten in place (that was
#   the old O(n^2) design).
#
# Why this is its own module:
#   The "read the file, keep the latest status per path" loop was copy-pasted
#   in five places (migrator rollback, migrator validate_rollback, migrator
#   --mode validate, and validate.sh). tracking_load_latest() below collapses
#   them into one tested implementation. The writer helpers moved here too so
#   the whole tracking contract lives in one file rather than inside
#   migrator.sh — which let validate.sh stop sourcing migrator entirely.
#
# Contract / where it fits:
#   - Requires common.sh (csv_strip_field) sourced first.
#   - The writer helpers (tracking_header/append/latest_status_for/field_for)
#     read the caller's $TRACKING_FILE global; only migrator sets and uses
#     those. tracking_load_latest() takes the file as an explicit ARGUMENT so
#     readers (validate.sh) don't need the global.
#
# Limitations:
#   - tracking_load_latest populates caller-named associative arrays via eval
#     indirection (bash 4.2 has no namerefs). Callers MUST `declare -A` the
#     four target arrays before calling. See the function header.
#
# Bash version floor: 4.2.
#
# =============================================================================

[ -n "${_TRACKING_SH:-}" ] && return 0
_TRACKING_SH=1

# tracking_header
# Echoes the CSV header line. Written once when a fresh tracking file is made.
tracking_header() {
    echo "Original_Path,New_Path,Backup_Path,Original_Timestamp,Status"
}

# tracking_append <orig> <new> <backup> <timestamp> <status>
# Appends one fully-quoted row to $TRACKING_FILE (caller's global).
tracking_append() {
    local orig="$1" newp="$2" bkp="$3" ts="$4" status="$5"
    printf '"%s","%s","%s","%s","%s"\n' \
        "$orig" "$newp" "$bkp" "$ts" "$status" >> "$TRACKING_FILE"
}

# tracking_latest_status_for <path>
# Echoes the latest status for <path>, or empty string if never recorded.
# Reads $TRACKING_FILE (caller's global).
tracking_latest_status_for() {
    local target="$1"
    [ -f "$TRACKING_FILE" ] || { echo ""; return; }
    # Reverse-walk to find the most recent entry first. tac is widely
    # available on Linux; we don't need the macOS shim here.
    local status
    status=$(tac "$TRACKING_FILE" 2>/dev/null \
        | awk -F'","' -v target="\"$target" '
            $1 == target { gsub(/"$/, "", $5); print $5; exit }
        ') || true
    echo "$status"
}

# tracking_field_for <path> <field_number>
# Returns field N (1-based) from the latest tracking entry for <path>.
# Fields: 1=Original_Path 2=New_Path 3=Backup_Path 4=Timestamp 5=Status
# Reads $TRACKING_FILE (caller's global).
tracking_field_for() {
    local target="$1"
    local fieldnum="$2"
    [ -f "$TRACKING_FILE" ] || { echo ""; return; }
    local val
    val=$(tac "$TRACKING_FILE" 2>/dev/null \
        | awk -F'","' -v target="\"$target" -v fn="$fieldnum" '
            $1 == target { gsub(/(^"|"$)/, "", $fn); print $fn; exit }
        ') || true
    echo "$val"
}

# tracking_load_latest <tracking_file> <status_arr> <new_arr> <bkp_arr> <ts_arr>
# Reads <tracking_file> (skipping its header) and, for every Original_Path,
# keeps the LATEST row's fields. Populates the four caller-declared
# associative arrays (passed BY NAME) keyed on Original_Path.
#
# Replaces the five hand-rolled "tail -n +2 | while IFS=, read ..." loops that
# previously lived in migrator.sh and validate.sh.
#
# Caller contract:
#   declare -A st nw bk ts
#   tracking_load_latest "$TRACKING_FILE" st nw bk ts
#
# Uses eval indirection because bash 4.2 lacks namerefs. Locals are
# `_tll_`-prefixed so they cannot collide with the caller's array names.
tracking_load_latest() {
    local _tll_tf="$1" _tll_sa="$2" _tll_na="$3" _tll_ba="$4" _tll_ta="$5"
    [ -f "$_tll_tf" ] || return 0
    local _tll_orig _tll_newp _tll_bkp _tll_ts _tll_status _tll_tmp
    _tll_tmp=$(mktemp)
    tail -n +2 "$_tll_tf" > "$_tll_tmp"
    while IFS=, read -r _tll_orig _tll_newp _tll_bkp _tll_ts _tll_status; do
        _tll_orig=$(csv_strip_field "$_tll_orig")
        _tll_newp=$(csv_strip_field "$_tll_newp")
        _tll_bkp=$(csv_strip_field "$_tll_bkp")
        _tll_ts=$(csv_strip_field "$_tll_ts")
        _tll_status=$(csv_strip_field "$_tll_status")
        [ -z "$_tll_orig" ] && continue
        eval "${_tll_sa}[\"\$_tll_orig\"]=\"\$_tll_status\""
        eval "${_tll_na}[\"\$_tll_orig\"]=\"\$_tll_newp\""
        eval "${_tll_ba}[\"\$_tll_orig\"]=\"\$_tll_bkp\""
        eval "${_tll_ta}[\"\$_tll_orig\"]=\"\$_tll_ts\""
    done < "$_tll_tmp"
    rm -f "$_tll_tmp"
}
