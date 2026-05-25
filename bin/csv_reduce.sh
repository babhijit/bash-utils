#!/bin/bash
# =============================================================================
#
# Script:      csv_reduce.sh
#
# Description:
#   Reduces finder.sh's 5-column diagnostic CSV to migrator.sh's 3-column
#   format. Drops the Match_Filter_Type and Filter_Value columns; keeps
#   Name, Absolute_Path, Last_Modified. Output is deduplicated by
#   Absolute_Path (the last seen row for each path wins on Name/Timestamp
#   tie, but those should be stable).
#
#   This script exists because finder and migrator have intentionally
#   different CSV contracts: finder's extra columns are diagnostic
#   (useful for the operator to know WHY a path was matched), while
#   migrator only needs the path and its original timestamp.
#
#   Idempotent: a 3-column CSV passed in is emitted unchanged (modulo
#   dedupe). Use this as a normalization step whenever the column count
#   is uncertain.
#
# Usage:
#   bash csv_reduce.sh --input <5-col.csv> --output <3-col.csv>
#   bash csv_reduce.sh --input <csv> > <3-col.csv>     # stdout if no --output
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_bash_version 4 2
set -euo pipefail

INPUT=""
OUTPUT=""

usage() {
    cat >&2 <<EOF
Usage: $0 --input <csv> [--output <csv>]

Reduces a CSV from finder's 5-column format to migrator's 3-column format.
3-column input is passed through (with dedupe).

OPTIONS:
  --input  PATH   Input CSV (required)
  --output PATH   Output CSV (default: stdout)
EOF
    exit 1
}

parse_args() {
    if [ "$#" -eq 0 ]; then usage; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --input)   INPUT="$2"; shift 2 ;;
            --output)  OUTPUT="$2"; shift 2 ;;
            -h|--help) usage ;;
            *) echo "Error: Unknown argument '$1'" >&2; usage ;;
        esac
    done
    [ -n "$INPUT" ]   || { echo "Error: --input required" >&2; usage; }
    [ -f "$INPUT" ]   || die "Input file not found: $INPUT"
}

reduce() {
    # Awk pipeline that:
    #   1. Skips blank lines.
    #   2. Detects column count from the header (first non-blank line).
    #   3. For 5-col, emits cols 1, 2, 5. For 3-col, emits 1, 2, 3.
    #   4. Dedupes by Absolute_Path (col 2), keeping the first row seen.
    #
    # Quote-aware splitter — same approach as common.sh's csv_read_3col.
    awk '
        function parse_line(line, fields,    n, i, c, field, in_q) {
            sub(/\r$/, "", line)
            n = length(line)
            field = ""; in_q = 0; idx = 1
            delete fields
            for (i = 1; i <= n; i++) {
                c = substr(line, i, 1)
                if (c == "\"") { in_q = 1 - in_q; continue }
                if (c == "," && !in_q) { fields[idx++] = field; field = ""; continue }
                field = field c
            }
            fields[idx] = field
            return idx
        }

        NR == 1 {
            col_count = parse_line($0, hdr)
            if (col_count != 3 && col_count != 5) {
                print "csv_reduce: unexpected header column count " col_count > "/dev/stderr"
                exit 2
            }
            print "Name,Absolute_Path,Last_Modified"
            next
        }

        {
            count = parse_line($0, f)
            if (count < col_count) next
            name = f[1]
            path = f[2]
            ts   = (col_count == 5) ? f[5] : f[3]
            if (path in seen) next
            seen[path] = 1
            printf "\"%s\",\"%s\",\"%s\"\n", name, path, ts
        }
    ' "$INPUT"
}

main() {
    parse_args "$@"
    if [ -n "$OUTPUT" ]; then
        reduce > "$OUTPUT"
        info "Wrote: $OUTPUT"
    else
        reduce
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
