# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A small collection of standalone Bash utilities for an in-place data/path migration workflow on Linux servers (no Python, no package manager, no build system). Every script is self-contained and executed with `bash <script>.sh --mode <...>`.

The three production scripts in `bin/` form a loose pipeline; the three `setup_*_test.sh` scripts are companion harnesses that build mock environments and (for migrator) drive multi-phase validation.

`lib/` and `tests/{cases,fixtures,mocks}/` are placeholder directories — only `.gitkeep` files. There is no shared library or test runner yet; tests are bash harnesses invoked manually.

## The pipeline (and a deliberate gap in it)

```
finder.sh  →  (manual CSV reduction)  →  migrator.sh  →  selective_copy.sh
  (discover)         (operator)          (mutate +     (cross-user
                                          rollback)     deploy, no sudo)
```

**Important schema mismatch:** [bin/finder.sh](bin/finder.sh) emits a **5-column** CSV — `Name,Absolute_Path,Match_Filter_Type,Filter_Value,Last_Modified`. [bin/migrator.sh](bin/migrator.sh) reads a **3-column** CSV — `Name,Absolute_Path,Last_Modified`. Finder output is **not** fed directly into migrator; there is an implicit operator step to reduce columns 3–4 out. [bin/setup_migrator_test.sh](bin/setup_migrator_test.sh) generates its own 3-column CSV for testing and never invokes finder. Treat the CSV contract as belonging to migrator; finder's extra columns are diagnostic.

## What each script does

### [bin/finder.sh](bin/finder.sh) — read-only discovery
Walks a tree (`-L`, case-insensitive) matching basenames against `NAME_SEARCH_PATTERNS` and/or file contents against `CONTENT_SEARCH_PATTERNS`. Three modes: `name`, `content`, `both`. `both` is a single-pass combined walk (~2x faster than running the other two sequentially). Skips directories named in `EXCLUDE_DIRS` and (for content) files matching `CONTENT_SEARCH_EXCLUDE_FILES`. Progress prints to stderr; CSV results to stdout (or `--output`).

### [bin/migrator.sh](bin/migrator.sh) — stateful in-place mutator
Three modes:
- `execute` — for each CSV row: back up to `/tmp/migrator_backups_<ts>/`, rename the path per `PATH_REPLACE_MAPPING`, rewrite file contents per `CONTENT_REPLACE_MAPPING` (or retarget symlinks), then restore the original mtime. Each step is logged to `migration_progress.log` as `BACKED_UP` → `COMPLETED`. Re-runs **resume**: previously `COMPLETED` paths are skipped.
- `rollback` — replays `migration_progress.log` in reverse, restoring each path from its backup.
- `cleanup` — deletes the backup files referenced in the tracking log, then `rmdir`s the backup directory if empty.

Forward and reverse mappings are both declared at the top of the file because `setup_migrator_test.sh validate_integrity` sources this script to access `REVERSE_*_MAPPING` and `replace_content_in_file`. **The `main "$@"` call at the bottom is intentionally guarded with `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` — do not remove this guard, or sourcing will execute migrator's main with the caller's argv.**

### [bin/selective_copy.sh](bin/selective_copy.sh) — two-stage cross-user copy
Designed for environments with **split user permissions and no sudo**. User A (read-side, e.g. `xbapp_d1`) runs `--mode prepare`, which rsyncs files + symlinks into a shared `/tmp/selective_copy_stage/`, records original perms/mtimes in `permissions.state`, and chmods the staging area open. User B (write-side, e.g. `xbapp_d2`) runs `--mode deploy`, which rsyncs staging → `TARGET_BASE_DIR`, creates the configured symlinks at their **new** targets, applies `NESTED_ITEM_TRANSFORM` renames/retargets, and restores perms+mtimes from `permissions.state`.

Refuses to run as root by design — running as root would defeat the split-permission model the script is built for.

## Configuration model

All three scripts are **configuration-as-code**: search patterns, replacement mappings, base paths, and exclusion lists are declared as `readonly` arrays/maps at the top of each script. There are no config files and no CLI flags for these values. To change what gets searched, migrated, or copied, **edit the constants in the script file itself**. The current values (`fat1`→`fat2`, `opc_d1`→`opc_d2`, `xbapp_d1`→`xbapp_d2`, etc.) reflect a specific environment migration; treat them as user-supplied data, not as canonical.

## Running

```bash
# Discover candidates
bash bin/finder.sh --mode both --dir /path/to/root --output found.csv

# Reduce finder's 5-col CSV to migrator's 3-col CSV (operator step — no tool yet)
# Keep columns: Name, Absolute_Path, Last_Modified  (columns 1, 2, 5)

# Apply migration (resumable; safe to re-run)
bash bin/migrator.sh --mode execute --csv reduced.csv

# Revert
bash bin/migrator.sh --mode rollback

# Delete backups after validation
bash bin/migrator.sh --mode cleanup

# Cross-user copy (run prepare as source-user, deploy as target-user)
bash bin/selective_copy.sh --mode prepare    # as user A
bash bin/selective_copy.sh --mode deploy     # as user B
```

## Testing

There is no test runner. The `setup_*_test.sh` scripts build mock filesystem environments under `/tmp/` and either run assertions directly (migrator) or print operator instructions (finder, selective_copy).

```bash
# Finder: builds /tmp/finder_test/ with case-mixed names + a symlink, then prints
# the exact finder.sh commands to run and their expected output.
bash bin/setup_finder_test.sh

# Migrator: full multi-phase harness. Takes a real CSV, replicates the listed
# files into /tmp/test_f2/migration_test/environment_to_migrate/, then runs
# migrator against the mock and validates results.
bash bin/setup_migrator_test.sh --mode all --csv real_input.csv

# Individual phases:
bash bin/setup_migrator_test.sh --mode prepare --csv real_input.csv
bash bin/setup_migrator_test.sh --mode execute
bash bin/setup_migrator_test.sh --mode validate              # path/content/mtime checks
bash bin/setup_migrator_test.sh --mode rollback              # rollback + auto-diff vs originals
bash bin/setup_migrator_test.sh --mode cleanup               # verifies backup dir removed
bash bin/setup_migrator_test.sh --mode validate_integrity    # round-trip: apply REVERSE_* mappings and diff against backups

# Selective copy: builds a complex mock source tree, then prints sed commands to
# rewrite selective_copy.sh's hardcoded paths/mappings for the test.
bash bin/setup_linux_test.sh
```

`validate_integrity` is the strongest correctness check: it copies each migrated artefact, applies the reverse mappings, and diffs against the original backup. Any divergence means the forward transformation was lossy.

## Platform and Bash version constraints

- **Linux-only by default.** Scripts use GNU coreutils flags directly: `stat -c %y`, `touch -d "@epoch"`, `touch -h -d "$timestamp"`. None of these work on stock macOS BSD coreutils. Migrator does detect `tac` vs `tail -r` for log reversal, but the `stat`/`touch` calls are not gated.
- **Bash version floors enforced at startup:** finder requires 4.0+ (uses `${var,,}` case-folding), migrator requires 4.2+ (uses `declare -Ar` and eval-based array indirection because `declare -n` namerefs need 4.3+).
- All scripts run under `set -euo pipefail`. Several non-obvious patterns in the code exist specifically to survive this discipline — see "Conventions to preserve" below.

## Conventions to preserve when editing

These show up across files and have inline comments explaining why; respect them when modifying:

- **Process substitution, not pipes, around `while read` loops.** `find ... -print0 | while read ...` runs the loop body in a subshell and silently loses any state set inside. Both finder and migrator use `done < <(find ... -print0)` for this reason.
- **Arithmetic assignment, not `((count++))`.** `((count++))` evaluates to the *old* value (0 on first call), returns exit-status 1, and is killed by `set -e`. Use `count=$((count + 1))`. Called out explicitly in [bin/setup_migrator_test.sh](bin/setup_migrator_test.sh) `validate_log`.
- **`grep -v ... || true`** when filtering tracking files. If every line matches, grep exits 1 and `pipefail` kills the script — the `|| true` is load-bearing, not paranoia.
- **`declare -Ar NAME=(...)`**, never `declare -A readonly NAME=(...)`. The second form is a latent bug — bash parses `readonly` as a separate identifier and `NAME` is not actually readonly. The comment above the mappings in [bin/migrator.sh](bin/migrator.sh) documents this.
- **`eval` for named-array indirection** in `replace_content_in_file` is intentional — bash 4.2 has no namerefs. Don't "modernize" it to `declare -n` without bumping the version floor and updating the version check.
- **Sourcing guard at the bottom of migrator.sh** (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`) is required by `setup_migrator_test.sh`'s `validate_integrity` mode. Removing it breaks the round-trip test.
- **`if ! main "$@"; then ...`** at the bottom of selective_copy.sh disables `set -e` for the main invocation so the FATAL handler can run. Don't replace it with a bare `main "$@"`.

## Author conventions (from global directives)

- Commits: no `Co-Authored-By: Claude` trailer. Author is Abhijit Bandyopadhyay <abhijitb@gmail.com>.
- Commit style: `<type>: <description>` with types `feat|fix|docs|refactor|test|chore`.
