#!/bin/bash
# =============================================================================
#
# Script:      tests/run_container_tests.sh
#
# Description:
#   End-to-end harness intended to run INSIDE a bash-4.2 + GNU-coreutils
#   container (e.g. centos:7), with the repo bind-mounted at the CWD. It:
#     1. Materializes a synthetic SOURCE tree from a CSV (default fat2.csv)
#        at the literal absolute paths the CSV names — the container is
#        disposable, so we can own /applications/opc_d2 outright.
#     2. Syntax-gates every bin/*.sh with `bash -n` on real bash 4.2.
#     3. Runs the full mock pipeline (setup_migrator_test.sh --mode all):
#        mock_build -> migrator execute -> validate -> rollback ->
#        validate-rollback.
#
#   This is the "recreate the mock filesystem from fat2.csv and exercise the
#   pipeline" check. Edge-case injection is layered on in PHASE B (added in a
#   later iteration); PHASE A here establishes the baseline on real data.
#
#   Run from the host:
#     docker run --rm -v "$PWD":/work -w /work centos:7 \
#         bash tests/run_container_tests.sh
#
# NOT set -e: we want every phase to run and report, even if an earlier one
# fails, so a single run shows the full picture.
#
# =============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/bin"
CSV="${CSV:-$REPO/tests/cases/fat2.csv}"
SRC_ROOT="${SRC_ROOT:-/applications/opc_d2}"

banner() {
    echo
    echo "############################################################"
    echo "## $*"
    echo "############################################################"
}

# materialize_from_csv <csv>
# Create a synthetic source tree at the literal absolute paths in column 2.
# A path is a DIRECTORY iff some other path is strictly under it ("$p"/*);
# otherwise it is a regular file seeded with content that contains every
# migration token (so the content rewrite has work to do and validate can
# confirm it). mtimes are set in a SECOND pass so creating later files does
# not re-bump an already-stamped directory.
materialize_from_csv() {
    local csv="$1"
    local -a allpaths=()
    local p ts q isdir

    while IFS=$'\t' read -r p ts; do
        [ -z "$p" ] && continue
        allpaths+=("$p")
    done < <(awk -F, 'NR>1 && $2!="" {print $2"\t"$3}' "$csv" | sort -u)

    # Pass 1: create files and directories.
    for p in "${allpaths[@]}"; do
        isdir=0
        for q in "${allpaths[@]}"; do
            case "$q" in "$p"/*) isdir=1; break ;; esac
        done
        if [ "$isdir" -eq 1 ]; then
            mkdir -p "$p"
        else
            mkdir -p "$(dirname "$p")"
            printf 'config for %s\nhost=opcsvcf1.example.com\nuser=xbapp_d1\nenv=FAT1 fat1\nsvc=opc_d1\n' \
                "$(basename "$p")" > "$p"
        fi
    done

    # Pass 2: stamp mtimes (touch does not bump a parent dir's mtime).
    while IFS=$'\t' read -r p ts; do
        [ -z "$p" ] && continue
        ts="${ts#"${ts%%[![:space:]]*}"}"
        ts="${ts%"${ts##*[![:space:]]}"}"
        touch -h -d "$ts" "$p" 2>/dev/null || echo "  WARN: touch failed: $p (ts=$ts)" >&2
    done < <(awk -F, 'NR>1 && $2!="" {print $2"\t"$3}' "$csv")
}

banner "ENVIRONMENT"
bash --version | head -1
stat --version | head -1
echo "repo : $REPO"
echo "csv  : $CSV"
echo "src  : $SRC_ROOT"

banner "SYNTAX GATE (bash -n) — all bin/*.sh on bash $BASH_VERSION"
syntax_fail=0
for f in "$BIN"/*.sh; do
    if bash -n "$f" 2>/tmp/nerr; then
        echo "  ok   : $(basename "$f")"
    else
        echo "  FAIL : $(basename "$f")"; cat /tmp/nerr; syntax_fail=$((syntax_fail + 1))
    fi
done
echo "syntax failures: $syntax_fail"

banner "MATERIALIZE source tree from CSV at $SRC_ROOT"
rm -rf "$SRC_ROOT"
materialize_from_csv "$CSV"
echo "entries created under $SRC_ROOT: $(find "$SRC_ROOT" | wc -l)"
echo "directories: $(find "$SRC_ROOT" -type d | wc -l)   files: $(find "$SRC_ROOT" -type f | wc -l)"
echo "sample (depth<=5):"; find "$SRC_ROOT" -maxdepth 5 | sort | head -25

banner "FULL MOCK PIPELINE (CURRENT scripts) — setup_migrator_test --mode all"
NONINTERACTIVE=1 bash "$BIN/setup_migrator_test.sh" \
    --mode all --csv "$CSV" --source-root "$SRC_ROOT"
echo "==> setup_migrator_test exit code: $?"

banner "DONE (PHASE A baseline)"
