#!/bin/bash
# =============================================================================
#
# Script:      finder.sh
#
# Description:
#   Searches a directory tree for files, directories, and symlinks whose
#   names OR contents match patterns from the migration map. Emits a CSV
#   suitable for migrator.sh (when --minimal is passed) or for diagnostics
#   (default 5-column form with match-type/match-value).
#
#   Search is case-insensitive throughout (names via -iname, contents via
#   grep -i). Follows symbolic links (-L) so a single tree with a symlink
#   into another part of the FS is fully covered.
#
#   PATTERNS COME FROM migration_map.sh's MIGRATION_MAP — the shared data
#   module migrator also reads. This guarantees finder searches for exactly
#   the things migrator can rewrite (no risk of finder finding a pattern
#   migrator won't handle, or vice versa) WITHOUT finder depending on
#   migrator.sh itself.
#
# Modes:
#   --mode name     Match by basename only.
#   --mode content  Match by file content only (skips binaries and
#                   CONTENT_SEARCH_EXCLUDE_FILES). One multi-pattern grep
#                   per file.
#   --mode both     Run name pass then content pass. Two tree walks.
#
# Path keys / symlink handling:
#   - Regular files and directories are keyed by their canonical realpath
#     for stable deduplication.
#   - Symlinks are keyed by the symlink path itself, NOT by realpath of
#     the target. A symlink and its target are intentionally kept as
#     separate rows so migrator.sh can retarget the symlink AND rewrite
#     the target.
#
# Output (stdout, CSV):
#   Default: Name,Absolute_Path,Match_Filter_Type,Filter_Value,Last_Modified
#   --minimal: Name,Absolute_Path,Last_Modified
#
#   Default always dedupes by match key; if the same path matches by
#   both name and content, the row is emitted once with Match_Filter_Type
#   = "Both" and Filter_Value listing both. Fields containing literal
#   double-quotes are CSV-escaped (RFC-4180 style: `"` -> `""`).
#
# =============================================================================

# --- Script Safety and Rigor -------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# MIGRATION_MAP comes from the shared passive data module — NOT from
# migrator.sh. finder runs UPSTREAM of migrator; sourcing the migrator
# executable just to borrow its map inverted the pipeline dependency and
# pulled every migrator function into finder's namespace.
# shellcheck source=migration_map.sh
source "${SCRIPT_DIR}/migration_map.sh"
# Floor is 4.2: migration_map.sh's `declare -Ar` requires 4.2, and finder
# uses `${var,,}` lower-casing which requires 4.0.
require_bash_version 4 2
set -euo pipefail

# =============================================================================
#                                 CONFIGURATION
# =============================================================================
#
# Patterns are the KEYS of MIGRATION_MAP (from migration_map.sh). Both name and
# content searches use the same set — anything finder finds is something
# migrator can rewrite, by construction.

readonly NAME_SEARCH_PATTERNS=( "${!MIGRATION_MAP[@]}" )
readonly CONTENT_SEARCH_PATTERNS=( "${!MIGRATION_MAP[@]}" )

# Files NOT to scan for content (still searchable by name). Binary/archive
# formats and large log files where a grep match would be expensive or
# meaningless.
readonly CONTENT_SEARCH_EXCLUDE_FILES=(
    "*.log"
    "*.log.*"
    "*.gz"
    "*.tgz"
    "*.tar"
    "*.tar.*"
    "*.jar"
    "*.class"
)

# Directories pruned from ALL searches. -iname is used in build_prune_args
# so case mismatches (Log vs log) are handled.
readonly EXCLUDE_DIRS=(
    "log"
    "docs"
    "logs"
    "arq"
    "lib"
    "examples"
    "classes"
    "apache-tomcat-10.1.34"
    "jvm"
    "data_*"
    "data"
    "webapps"
    "plugins"
    "baftrans"
)

# =============================================================================
#                              GLOBAL STATE
# =============================================================================

MODE=""
SEARCH_DIR=""
OUTPUT_FILE=""
MINIMAL=0

# Per-path match accumulators (assoc array, key = absolute path).
declare -A MATCH_NAME_VALUES   # path -> "fat1,opc_d1"
declare -A MATCH_CONTENT_VALUES
declare -A MATCH_LSTAT_TS      # path -> stat -c %y output

# =============================================================================
#                              ARGUMENT PARSING
# =============================================================================

usage() {
    cat >&2 <<EOF
Usage: $0 --mode <name|content|both> --dir <path> [--output <file>] [--minimal]

Arguments:
  --mode      name | content | both
  --dir       Top-level directory to search (follows symlinks)
  --output    Write CSV to file instead of stdout
  --minimal   Emit 3-column CSV (Name,Absolute_Path,Last_Modified) suitable
              for migrator.sh, instead of the default 5-column diagnostic form.

Patterns are taken from migration_map.sh's MIGRATION_MAP keys.
EOF
    exit 1
}

parse_args() {
    if [ "$#" -eq 0 ]; then usage; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)     MODE="$2"; shift 2 ;;
            --dir)      SEARCH_DIR="$2"; shift 2 ;;
            --output)   OUTPUT_FILE="$2"; shift 2 ;;
            --minimal)  MINIMAL=1; shift ;;
            -h|--help)  usage ;;
            *) echo "Error: Unknown argument '$1'" >&2; usage ;;
        esac
    done

    [ -n "$MODE" ]       || { echo "Error: --mode required" >&2; usage; }
    [ -n "$SEARCH_DIR" ] || { echo "Error: --dir required"  >&2; usage; }
    [ -d "$SEARCH_DIR" ] || die "Search directory does not exist: $SEARCH_DIR"

    case "$MODE" in name|content|both) ;; *) usage ;; esac
}

# =============================================================================
#                              FIND HELPERS
# =============================================================================

# build_prune_args
# Echoes the find(1) prune expression for EXCLUDE_DIRS, one argument per
# line. Empty if EXCLUDE_DIRS is empty. -type d restricts the prune to
# DIRECTORIES — without it, a regular file named "log" would also be
# pruned, which silently dropped legitimate name-match candidates.
# -iname is used so case differences don't slip past the prune.
build_prune_args() {
    [ ${#EXCLUDE_DIRS[@]} -eq 0 ] && return 0
    local prune_paths=()
    local dir
    for dir in "${EXCLUDE_DIRS[@]}"; do
        prune_paths+=(-o -type d -iname "$dir")
    done
    printf '%s\n' "("
    local arg
    for arg in "${prune_paths[@]:1}"; do
        printf '%s\n' "$arg"
    done
    printf '%s\n' ")"
    printf '%s\n' "-prune"
}

# match_key_for <path>
# Returns a stable key for accumulating matches against <path>.
#   - Symlinks: the symlink path itself (preserves it as a distinct row
#     from its realpath target).
#   - Everything else: realpath, falling back to the input on failure.
# Symlinks need their own row so migrator can retarget them in addition
# to rewriting the file behind them.
match_key_for() {
    local path="$1"
    if [ -L "$path" ]; then
        printf '%s' "$path"
        return
    fi
    local rp
    if rp=$(realpath "$path" 2>/dev/null); then
        printf '%s' "$rp"
    else
        printf '%s' "$path"
    fi
}

# csv_escape <field>
# Echoes the field with embedded double-quotes doubled (RFC-4180). Caller
# is responsible for wrapping the result in `"..."`. Newlines are not
# expected in our paths or timestamps so we don't quote them.
csv_escape() {
    local s="$1"
    printf '%s' "${s//\"/\"\"}"
}

# =============================================================================
#                              MATCH ACCUMULATION
# =============================================================================
#
# When a path matches, we append the matching pattern to either
# MATCH_NAME_VALUES[$path] or MATCH_CONTENT_VALUES[$path]. At emit time we
# combine these into a single CSV row per path.

record_name_match() {
    local path="$1" pattern="$2"
    local cur="${MATCH_NAME_VALUES[$path]:-}"
    if [ -z "$cur" ]; then
        MATCH_NAME_VALUES["$path"]="$pattern"
    elif [[ ",$cur," != *",$pattern,"* ]]; then
        MATCH_NAME_VALUES["$path"]="${cur},${pattern}"
    fi
    [ -n "${MATCH_LSTAT_TS[$path]:-}" ] || MATCH_LSTAT_TS["$path"]="$(lstat_mtime_human "$path")"
}

record_content_match() {
    local path="$1" pattern="$2"
    local cur="${MATCH_CONTENT_VALUES[$path]:-}"
    if [ -z "$cur" ]; then
        MATCH_CONTENT_VALUES["$path"]="$pattern"
    elif [[ ",$cur," != *",$pattern,"* ]]; then
        MATCH_CONTENT_VALUES["$path"]="${cur},${pattern}"
    fi
    [ -n "${MATCH_LSTAT_TS[$path]:-}" ] || MATCH_LSTAT_TS["$path"]="$(lstat_mtime_human "$path")"
}

# =============================================================================
#                              SEARCH PASSES
# =============================================================================

search_by_name() {
    info "Searching by name in $SEARCH_DIR"

    local find_prune_args=()
    mapfile -t find_prune_args < <(build_prune_args)

    local pattern path
    for pattern in "${NAME_SEARCH_PATTERNS[@]}"; do
        while IFS= read -r -d '' path; do
            record_name_match "$(match_key_for "$path")" "$pattern"
        done < <(find -L "$SEARCH_DIR" "${find_prune_args[@]}" -o -iname "*$pattern*" -print0)
    done

    info "Name search done"
}

search_by_content() {
    info "Searching by content in $SEARCH_DIR"

    local find_prune_args=()
    mapfile -t find_prune_args < <(build_prune_args)

    local find_file_exclude_args=()
    local pattern
    for pattern in "${CONTENT_SEARCH_EXCLUDE_FILES[@]}"; do
        find_file_exclude_args+=(-not -iname "$pattern")
    done

    # Build a single -e arg list once; one grep invocation per file
    # instead of one-per-pattern-per-file.
    local grep_pattern_args=()
    for pattern in "${CONTENT_SEARCH_PATTERNS[@]}"; do
        grep_pattern_args+=(-e "$pattern")
    done

    local path matches m m_lc key
    while IFS= read -r -d '' path; do
        # -o: print each match on its own line. -I: skip binary. -i:
        # case-insensitive. -F: fixed strings. sort -u dedupes across
        # repeated occurrences in the same file.
        matches=$(grep -o -I -i -F "${grep_pattern_args[@]}" "$path" 2>/dev/null | sort -u) || true
        [ -z "$matches" ] && continue

        key="$(match_key_for "$path")"
        # grep -o emits the matched substring with the file's original
        # case (not the pattern's case). Lowercase-compare back to the
        # source patterns so we record the canonical pattern token.
        while IFS= read -r m; do
            [ -z "$m" ] && continue
            m_lc="${m,,}"
            for pattern in "${CONTENT_SEARCH_PATTERNS[@]}"; do
                if [ "${pattern,,}" = "$m_lc" ]; then
                    record_content_match "$key" "$pattern"
                fi
            done
        done <<< "$matches"
    done < <(find -L "$SEARCH_DIR" "${find_prune_args[@]}" -o -type f "${find_file_exclude_args[@]}" -print0)

    info "Content search done"
}

# =============================================================================
#                              OUTPUT EMITTER
# =============================================================================
#
# Emits one CSV row per unique absolute path. The set of paths is the
# UNION of MATCH_NAME_VALUES keys and MATCH_CONTENT_VALUES keys.

emit_results() {
    # Collect union of keys.
    declare -A union
    local p
    for p in "${!MATCH_NAME_VALUES[@]}";    do union["$p"]=1; done
    for p in "${!MATCH_CONTENT_VALUES[@]}"; do union["$p"]=1; done

    # Header
    if [ "$MINIMAL" -eq 1 ]; then
        echo "Name,Absolute_Path,Last_Modified"
    else
        echo "Name,Absolute_Path,Match_Filter_Type,Filter_Value,Last_Modified"
    fi

    # Sort paths for deterministic output.
    local sorted_paths
    sorted_paths=$(printf '%s\n' "${!union[@]}" | sort)

    while IFS= read -r p; do
        [ -z "$p" ] && continue
        local name; name=$(basename "$p")
        local ts="${MATCH_LSTAT_TS[$p]}"
        local nv="${MATCH_NAME_VALUES[$p]:-}"
        local cv="${MATCH_CONTENT_VALUES[$p]:-}"

        # CSV-escape every field. Paths almost never contain literal
        # double-quotes, but a stray one would corrupt every downstream
        # tool that parses this file.
        local e_name e_p e_ts
        e_name="$(csv_escape "$name")"
        e_p="$(csv_escape "$p")"
        e_ts="$(csv_escape "$ts")"

        if [ "$MINIMAL" -eq 1 ]; then
            printf '"%s","%s","%s"\n' "$e_name" "$e_p" "$e_ts"
            continue
        fi

        local match_type filter_value
        if [ -n "$nv" ] && [ -n "$cv" ]; then
            match_type="Both"
            filter_value="name:${nv};content:${cv}"
        elif [ -n "$nv" ]; then
            match_type="Name"
            filter_value="$nv"
        else
            match_type="Content"
            filter_value="$cv"
        fi
        local e_filter; e_filter="$(csv_escape "$filter_value")"
        printf '"%s","%s","%s","%s","%s"\n' \
            "$e_name" "$e_p" "$match_type" "$e_filter" "$e_ts"
    done <<< "$sorted_paths"
}

# =============================================================================
#                                MAIN
# =============================================================================

main() {
    parse_args "$@"

    case "$MODE" in
        name)    search_by_name ;;
        content) search_by_content ;;
        both)    search_by_name; search_by_content ;;
    esac

    if [ -n "$OUTPUT_FILE" ]; then
        emit_results > "$OUTPUT_FILE"
        info "Results written to: $OUTPUT_FILE"
    else
        emit_results
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
