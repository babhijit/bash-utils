#!/bin/bash
# =============================================================================
#
# Script:      finder.sh
#
# Description:
#   Searches for files, directories, and symbolic links from a top-level
#   directory based on predefined lists of patterns. Can search by name,
#   by content, or perform both searches in a single, optimized pass.
#   Content search automatically skips binary files and user-defined patterns.
#   All searches are case-insensitive and follow symbolic links.
#   Provides real-time progress updates to the console (stderr).
#
# Outputs:
#   A CSV-formatted list of matches with the columns:
#   Name,Absolute_Path,Match_Filter_Type,Filter_Value,Last_Modified
#
# =============================================================================

# --- Script Safety and Rigor -------------------------------------------------
# Requires Bash 4.0+ for `${var,,}` case-folding parameter expansion.
if ((BASH_VERSINFO[0] < 4)); then
    echo "Error: This script requires Bash 4.0 or higher. Found: ${BASH_VERSION}." >&2
    exit 1
fi
set -euo pipefail

# =============================================================================
#                                 CONFIGURATION
# =============================================================================

# --- Filesystem Name Search Patterns -----------------------------------------
# A list of glob patterns to search for in file, directory, or symlink names.
readonly NAME_SEARCH_PATTERNS=(
    "fat1"
    "opcsvcf1"
    "opc_d1"
    "xbapp_d1"
    "FROPC2U"
)

# --- File Content Search Patterns --------------------------------------------
# A list of strings/regex patterns to search for within file contents.
readonly CONTENT_SEARCH_PATTERNS=(
    "fat1"
    "opcsvcf1"
    "opc_d1"
    "xbapp_d1"
    "FROPC2U"
)

# --- Content Search Exclusion Patterns ---------------------------------------
# A list of file name patterns to exclude from CONTENT searches.
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

# --- Directory Exclusion List ------------------------------------------------
# A list of directory names to completely exclude from ALL searches.
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
#                                  SCRIPT LOGIC
# =============================================================================

# -----------------------------------------------------------------------------
# usage
# -----------------------------------------------------------------------------
usage() {
    echo "Usage: $0 --mode [name|content|both] --dir <search_directory> [--output <output_file>]"
    echo ""
    echo "Arguments:"
    echo "  --mode    'name', 'content', or 'both' to perform both searches at once."
    echo "            (Patterns are configured inside the script)."
    echo "  --dir     The top-level directory to start the search from."
    echo "  --output  (Optional) The file to write CSV results to. Prints to console if omitted."
    exit 1
}

# -----------------------------------------------------------------------------
# build_prune_args
# Construct the find(1) prune expression from $EXCLUDE_DIRS. Echoes nothing
# if the list is empty; callers should handle that case so find's expression
# stays valid. The args are emitted one per line so the caller can read them
# safely with `mapfile -t` regardless of whitespace in any entry.
# -----------------------------------------------------------------------------
build_prune_args() {
    if [ ${#EXCLUDE_DIRS[@]} -eq 0 ]; then
        return 0
    fi
    local prune_paths=()
    local dir
    for dir in "${EXCLUDE_DIRS[@]}"; do
        prune_paths+=(-o -name "$dir")
    done
    # Strip the leading -o, wrap in ( ... ) -prune.
    local arg
    printf '%s\n' "("
    for arg in "${prune_paths[@]:1}"; do
        printf '%s\n' "$arg"
    done
    printf '%s\n' ")"
    printf '%s\n' "-prune"
}

# -----------------------------------------------------------------------------
# search_by_name <SEARCH_DIR>
# Find filesystem objects whose basename matches any NAME_SEARCH_PATTERNS
# entry. Emits one CSV line per match to stdout.
# -----------------------------------------------------------------------------
search_by_name() {
    local search_dir="$1"
    echo "Searching for names matching predefined patterns in '$search_dir' (case-insensitive, follows symlinks)..." >&2

    local find_prune_args=()
    mapfile -t find_prune_args < <(build_prune_args)

    local pattern path
    for pattern in "${NAME_SEARCH_PATTERNS[@]}"; do
        # Use process substitution (not a pipe) so the loop body runs in this
        # shell, not a subshell. Matches the pattern we settled on in
        # migrator.sh; preserves any future state we might accumulate here.
        while IFS= read -r -d '' path; do
            local is_excluded=false
            local excluded
            for excluded in "${EXCLUDE_DIRS[@]}"; do
                if [[ $(basename "$path") == $excluded ]]; then
                    is_excluded=true
                    break
                fi
            done
            if [ "$is_excluded" = true ]; then
                continue
            fi

            local name absolute_path last_modified
            name=$(basename "$path")
            absolute_path=$(realpath "$path")
            last_modified=$(stat -c %y "$path")
            echo -ne "\033[2K\r" >&2
            echo "\"$name\",\"$absolute_path\",\"Name\",\"$pattern\",\"$last_modified\""
        done < <(find -L "$search_dir" "${find_prune_args[@]}" -o -iname "*$pattern*" -print0)
    done
    echo -ne "\033[2K\r" >&2
    echo "Name search complete." >&2
}

# -----------------------------------------------------------------------------
# search_by_content <SEARCH_DIR>
# Find regular files whose content matches any CONTENT_SEARCH_PATTERNS entry,
# skipping the file-name patterns in $CONTENT_SEARCH_EXCLUDE_FILES.
# -----------------------------------------------------------------------------
search_by_content() {
    local search_dir="$1"
    echo "Searching for content matching predefined patterns in '$search_dir' (case-insensitive)..." >&2

    local find_prune_args=()
    mapfile -t find_prune_args < <(build_prune_args)

    local find_file_exclude_args=()
    if [ ${#CONTENT_SEARCH_EXCLUDE_FILES[@]} -gt 0 ]; then
        local pattern
        for pattern in "${CONTENT_SEARCH_EXCLUDE_FILES[@]}"; do
            find_file_exclude_args+=(-not -iname "$pattern")
        done
    fi

    local path
    while IFS= read -r -d '' path; do
        local is_excluded=false
        local excluded
        for excluded in "${EXCLUDE_DIRS[@]}"; do
            if [[ $(basename "$path") == $excluded ]]; then
                is_excluded=true
                break
            fi
        done
        if [ "$is_excluded" = true ]; then
            continue
        fi

        echo -ne "Scanning: $path\r" >&2
        local pattern
        for pattern in "${CONTENT_SEARCH_PATTERNS[@]}"; do
            if grep -I -i -q "$pattern" "$path" 2>/dev/null; then
                local name absolute_path last_modified
                name=$(basename "$path")
                absolute_path=$(realpath "$path")
                last_modified=$(stat -c %y "$path")
                echo -ne "\033[2K\r" >&2
                echo "\"$name\",\"$absolute_path\",\"Content\",\"$pattern\",\"$last_modified\""
                break
            fi
        done
    done < <(find -L "$search_dir" "${find_prune_args[@]}" -o -type f "${find_file_exclude_args[@]}" -print0)

    echo -ne "\033[2K\r" >&2
    echo "Content search complete." >&2
}

# -----------------------------------------------------------------------------
# search_both <SEARCH_DIR>
# Single-pass combined search: walk the tree once, evaluate every path against
# both NAME_SEARCH_PATTERNS and CONTENT_SEARCH_PATTERNS. ~2x faster than
# running name + content separately on large trees.
# -----------------------------------------------------------------------------
search_both() {
    local search_dir="$1"
    echo "Performing combined search for names and content in '$search_dir'..." >&2

    local find_prune_args=()
    mapfile -t find_prune_args < <(build_prune_args)

    local path
    while IFS= read -r -d '' path; do
        local is_excluded=false
        local excluded
        for excluded in "${EXCLUDE_DIRS[@]}"; do
            if [[ $(basename "$path") == $excluded ]]; then
                is_excluded=true
                break
            fi
        done
        if [ "$is_excluded" = true ]; then
            continue
        fi

        echo -ne "Scanning: $path\r" >&2
        local name lower_name
        name=$(basename "$path")
        lower_name="${name,,}"

        # --- Name pass ----------------------------------------------------
        local pattern lower_pattern
        for pattern in "${NAME_SEARCH_PATTERNS[@]}"; do
            lower_pattern="*${pattern,,}*"
            if [[ $lower_name == $lower_pattern ]]; then
                local absolute_path last_modified
                absolute_path=$(realpath "$path")
                last_modified=$(stat -c %y "$path")
                echo -ne "\033[2K\r" >&2
                echo "\"$name\",\"$absolute_path\",\"Name\",\"$pattern\",\"$last_modified\""
            fi
        done

        # --- Content pass (regular files only) ----------------------------
        if [ -f "$path" ]; then
            local should_exclude_file=false
            if [ ${#CONTENT_SEARCH_EXCLUDE_FILES[@]} -gt 0 ]; then
                local exclude_pattern
                for exclude_pattern in "${CONTENT_SEARCH_EXCLUDE_FILES[@]}"; do
                    if [[ $lower_name == ${exclude_pattern,,} ]]; then
                        should_exclude_file=true
                        break
                    fi
                done
            fi

            if [ "$should_exclude_file" = false ]; then
                for pattern in "${CONTENT_SEARCH_PATTERNS[@]}"; do
                    if grep -I -i -q "$pattern" "$path" 2>/dev/null; then
                        local absolute_path last_modified
                        absolute_path=$(realpath "$path")
                        last_modified=$(stat -c %y "$path")
                        echo -ne "\033[2K\r" >&2
                        echo "\"$name\",\"$absolute_path\",\"Content\",\"$pattern\",\"$last_modified\""
                        break
                    fi
                done
            fi
        fi
    done < <(find -L "$search_dir" "${find_prune_args[@]}" -o -print0)

    echo -ne "\033[2K\r" >&2
    echo "Combined search complete." >&2
}

# =============================================================================
#                                  Main Function
# =============================================================================
main() {
    local mode=""
    local search_dir=""
    local output_file=""

    if [ "$#" -eq 0 ]; then
        usage
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)
                mode="$2"
                shift 2
                ;;
            --dir)
                search_dir="$2"
                shift 2
                ;;
            --output)
                output_file="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown argument '$1'" >&2
                usage
                ;;
        esac
    done

    if [ -z "$mode" ] || [ -z "$search_dir" ]; then
        echo "Error: All primary arguments (--mode, --dir) are required." >&2
        usage
    fi

    if [ ! -d "$search_dir" ]; then
        echo "Error: Search directory '$search_dir' not found." >&2
        exit 1
    fi

    if [ -n "$output_file" ]; then
        if ! touch "$output_file"; then
            echo "Error: Cannot write to output file '$output_file'." >&2
            exit 1
        fi
        exec > "$output_file"
    fi

    echo "Name,Absolute_Path,Match_Filter_Type,Filter_Value,Last_Modified"

    case "$mode" in
        name)
            search_by_name "$search_dir"
            ;;
        content)
            search_by_content "$search_dir"
            ;;
        both)
            search_both "$search_dir"
            ;;
        *)
            echo "Error: Invalid mode '$mode'. Use 'name', 'content', or 'both'." >&2
            usage
            ;;
    esac
}

# --- Script Entry Point ------------------------------------------------------
main "$@"
