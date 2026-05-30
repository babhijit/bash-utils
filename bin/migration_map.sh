#!/bin/bash
# =============================================================================
#
# Module:      migration_map.sh
#
# Description:
#   The single source of truth for the FAT1 -> FAT2 migration mapping. This
#   module is PASSIVE DATA: it declares ONE associative array and nothing
#   else — no functions, no main, no side effects beyond the declaration.
#
# Why this exists (and why it is its own file):
#   The mapping is consumed by three tools that sit at different points in
#   the pipeline:
#     - migrator.sh  applies the map (path rename + in-file content rewrite)
#     - finder.sh    derives its search patterns from the map's keys
#     - validate.sh  recomputes the expected rewrite from the map
#   Because all three read the SAME array, the invariant "anything finder
#   finds, migrator can rewrite" holds BY CONSTRUCTION.
#
#   Previously the array lived inside migrator.sh and finder/validate did
#   `source migrator.sh` just to borrow it. That inverted the pipeline
#   dependency (the upstream finder depended on the downstream migrator) and,
#   worse, dragged ALL of migrator's functions (process_row, run_execute,
#   main, parse_args, a second run_validate, ...) into the consumer's shell,
#   where they shadowed/were-shadowed-by the consumer's own functions purely
#   by source order. Extracting the data here removes both problems: every
#   tool depends only on this passive module, never on a sibling executable.
#
#   Source idiom (flat layout — all scripts live in one directory):
#       source "$(dirname "${BASH_SOURCE[0]}")/migration_map.sh"
#
# Where it fits:
#   Upstream:   none (leaf data module; depends on nothing).
#   Downstream: migrator.sh, finder.sh, validate.sh.
#
# Limitations / future evolution:
#   - SAFE EXTENSION: add a new pattern by adding one key/value pair below.
#     finder will search for it and migrator will rewrite it automatically.
#   - There is intentionally NO reverse (fat2 -> fat1) map: nothing consumes
#     that direction today (YAGNI). If a reverse migration is ever needed,
#     derive it at the point of use rather than maintaining a second
#     hand-written array (drift risk).
#   - REGRESSION TO AVOID: do not write `declare -A readonly MIGRATION_MAP`.
#     bash parses `readonly` as a separate word and the array is NOT made
#     readonly. The `-Ar` shorthand below is the correct, tested form.
#
# Bash version floor: 4.2 (`declare -Ar`).
#
# =============================================================================

# Idempotent-source guard. Re-sourcing would re-run `declare -Ar` against an
# already-readonly variable, which aborts the shell. No tool sources this
# twice today, but the guard makes the module safe to compose freely.
[ -n "${_MIGRATION_MAP_SH:-}" ] && return 0
_MIGRATION_MAP_SH=1

# Forward mapping ONLY (fat1 -> fat2). Associative + readonly (`-Ar`).
declare -Ar MIGRATION_MAP=(
    ["FAT1"]="FAT2"
    ["fat1"]="fat2"
    ["opc_d1"]="opc_d2"
    ["xbapp_d1"]="xbapp_d2"
    ["opcsvcf1"]="opcsvcf2"
)
