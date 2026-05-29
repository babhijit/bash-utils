# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Bash utilities for a fat1 → fat2 dev-environment cloning workflow used as a DR exercise on a Linux host with **no sudo available**. The host has two unix accounts (fat1 user and fat2 user), each with read access to both trees but write access only to their own. `/tmp` is the only filesystem location both users can write to.

The whole suite assumes Linux + GNU coreutils + bash 4.2+. macOS will not run these scripts (`stat -c`, `touch -d "@epoch"` are GNU-only).

## Flat layout

All scripts live in `bin/`. There is no `bin/lib/` subdirectory because the operator deploys everything to a single working directory (`/tmp/migration_f2/` by convention). Sources resolve via `source "$(dirname "${BASH_SOURCE[0]}")/common.sh"` so any pair of scripts in the same directory composes.

```text
bin/
├── common.sh                  ← generic shared library (logging, CSV, lstat, path safety, sed-safe rewrite)
├── migration_map.sh           ← passive DATA: MIGRATION_MAP — sourced by migrator, finder, validate
├── tracking.sh                ← tracking-file contract + tracking_load_latest() reader
├── backup.sh                  ← backup-tree layout: backup_path_for() + backup_cp()
├── finder.sh                  ← discover fat1-style references in a tree
├── csv_reduce.sh              ← reduce finder's 5-col CSV to migrator's 3-col
├── selective_copy.sh          ← two-stage cross-user copy via /tmp (config-driven: --config)
├── selective_copy.conf.example ← sample job config for selective_copy.sh
├── mock_build.sh              ← build a sandbox from a CSV (smart selective copy)
├── migrator.sh                ← stateful path/content rewriter with backup/resume/rollback
├── validate.sh                ← post-migration consistency checker
├── fix_dir_mtimes.sh          ← repair directory mtimes bumped by renames (post-migration)
├── setup_migrator_test.sh     ← orchestrator: mock_build → migrator → validate → rollback
├── setup_finder_test.sh       ← (legacy) mock env for finder
├── setup_linux_test.sh        ← (legacy) mock env for selective_copy
├── diagnose_migrator_bug.sh   ← (legacy) read-only diagnostic; useful if a new bug appears
└── run_all_tests.sh           ← synthetic end-to-end smoke; no fat1/fat2 dependency
```

`migration_map.sh`, `tracking.sh`, and `backup.sh` are **library modules**, not executables — data and contracts shared by the tools so that **no tool sources another tool**. (finder/validate used to `source migrator.sh` just to borrow `MIGRATION_MAP` / `backup_path_for`, which inverted the pipeline dependency and pulled migrator's entire function set into their namespaces.) `lib/` and `tests/mocks/` are unused placeholders. `tests/cases/fat2.csv` is the real input CSV (canonical example); `tests/run_container_tests.sh` materializes a source tree from it and runs the full pipeline, and `tests/edge_cases.sh` is an adversarial edge battery — both run inside a bash-4.2.46 + GNU-coreutils container (`centos:7`), which is the only faithful way to exercise these GNU-only scripts off the target host.

## The two pipelines

### Production pipeline (live DR migration)

```text
  fat1 tree  (/applications/opc_d1)
       │
       │  (as fat1 user)
       ▼
  selective_copy.sh --mode prepare       ← stages into /tmp/scopy.XXXX
       │
       │  (as fat2 user)
       ▼
  selective_copy.sh --mode deploy        ← writes fat2 tree, restores lstat
       │
       ▼
  fat2 tree  (/applications/opc_d2, identical to fat1 at this point)
       │
       │  (as fat2 user)
       ▼
  finder.sh --mode both --dir /applications/opc_d2 --minimal
       │
       ▼
  fat2.csv   (3-col: Name, Absolute_Path, Last_Modified)
       │
       │  optional: hand-edit, or pipe through csv_reduce.sh if 5-col
       ▼
  migrator.sh --mode execute
              --root /applications/opc_d2
              --csv fat2.csv
              --workdir /tmp/migration_f2
              --yes                       ← + 5s countdown gate
       │
       ▼
  fat2 tree now has fat1-references rewritten to fat2 equivalents,
  lstat (especially mtime) preserved row-for-row.
       │
       ▼
  validate.sh --root /applications/opc_d2
              --workdir /tmp/migration_f2
              --scan-root /applications/opc_d2
```

`selective_copy.sh` was already used in this DR (the operator confirmed it ran successfully). The remaining steps run on the fat2 side. fat1 is read-only from here on.

### Mock test pipeline (rehearsal without touching fat2)

```text
  fat2.csv  (e.g. tests/cases/fat2.csv)
       │
       ▼
  mock_build.sh --csv fat2.csv
                --source-root /applications/opc_d2
                --mock-root /tmp/mock_f2
       │
       ▼
  /tmp/mock_f2/applications/opc_d2/...   ← real-fidelity copies of CSV-listed paths
  /tmp/mock_f2/mock_input.csv             ← CSV with paths under /tmp/mock_f2/
       │
       ▼
  migrator.sh --mode execute
              --root /tmp/mock_f2
              --csv /tmp/mock_f2/mock_input.csv
              --workdir /tmp/migration_f2_test
       │              ← /tmp/* root is "mock"; no countdown, no --yes needed
       ▼
  validate.sh --root /tmp/mock_f2 --workdir /tmp/migration_f2_test
              --scan-root /tmp/mock_f2
       │
       ▼
  migrator.sh --mode rollback ...        ← restores mock from backups
              (then re-validate: mock now matches what was copied from live)
       │
       ▼
  migrator.sh --mode cleanup ...         ← deletes backups + tracking
  rm -rf /tmp/mock_f2                     ← deletes the mock tree
```

`bin/setup_migrator_test.sh` orchestrates all of this via `--mode all`. `bin/run_all_tests.sh` does the same against a synthetic tree it builds itself (no fat1/fat2 dependency) — run this on any Linux box to smoke-test changes before deploying.

## The four hard requirements (and how they're satisfied)

These come from the DR brief; each script must respect them.

| Requirement | Implementation |
| --- | --- |
| **Backup before every change** | `migrator.sh` uses `cp -a` per row before any mutation. Backup tree mirrors original tree shape under `<workdir>/backups/` — no basename collisions possible. `selective_copy.sh` stages via rsync into `mktemp -d` and records lstat for restore. |
| **Validate that the change happened** | `validate.sh` reads migrator's tracking file. For every COMPLETED row, checks: migrated path exists, backup exists, mtime matches recorded ts, lstat type matches backup, content equals expected rewrite of backup, symlink target matches expected. Tree-wide `--scan-root` looks for residual fat1 references. |
| **Resume after mid-run kill** | Tracking file is append-only at `<workdir>/progress.log`. On restart, every `BACKED_UP`-but-not-`COMPLETED` row triggers restore-from-backup followed by re-execute. Backup is the source of truth; live path may be in any intermediate state. Re-running migrator with the same `--workdir` resumes automatically. |
| **Rollback even after success** | `migrator.sh --mode rollback` walks tracking in reverse, restores each `COMPLETED` row from its backup, restores its mtime, appends `ROLLED_BACK` to tracking. `--mode cleanup` deletes backups + tracking. Mock pipeline includes a `validate-rollback` phase that diffs the rolled-back mock against the original source — bit-for-bit equivalence is the gate. |

## /tmp constraint

The operator confirmed: `/tmp` is the only writable shared location. There is no `/var/tmp`, no `$HOME` option, no shared mount. So:

- `migrator.sh`'s `--workdir` defaults to `/tmp/migration_f2/` (configurable).
- `mock_build.sh`'s `--mock-root` defaults to `/tmp/mock_f2/`.
- `selective_copy.sh` creates a `mktemp -d /tmp/scopy.XXXXXX` staging dir.
- `common.sh:check_tmpfs_warning` warns loudly if the chosen dir is tmpfs (sweepers and reboot will lose backups).
- **Recommended operator practice**: run the full forward + validate + decision-to-keep cycle in one continuous shell session. Don't let a tmpfiles.d sweeper or a reboot get between execute and validate.

## --root safety guard

`migrator.sh` REQUIRES `--root`. Every CSV path is asserted to be under `--root` (`assert_under_root` in common.sh). A stray fat1 path in the CSV would `die` before any mutation. This is the load-bearing defense against the failure mode the operator called out as expensive: "messing up the precopied fat2 can lead to tremendous delays".

A root starting with `/tmp/` is treated as mock — no `--yes` required, no countdown. A non-`/tmp` root requires `--yes` and shows a 5-second countdown abortable with Ctrl-C. Test harnesses set `NONINTERACTIVE=1` to skip the countdown silently.

## Resume model in detail

The previous tracking model only had BACKED_UP → COMPLETED. If killed between `mv` and the COMPLETED write, the row's state was unrecoverable — re-running would either re-backup the mutated state (destroying the original) or skip the row leaving partial state.

New model: tracking is append-only. The LATEST status for a given Original_Path wins.

- `BACKED_UP`: backup exists, mutation may or may not have started.
- `COMPLETED`: row is fully done (mutated + mtime restored + logged).
- `ROLLED_BACK`: row has been restored from backup.

On `--mode execute` startup, `tracking_latest_status_for` is checked per row:

- `COMPLETED` → skip
- `BACKED_UP` → restore-from-backup, then redo (idempotent because backup is source of truth)
- `ROLLED_BACK` or absent → fresh

This makes resume safe regardless of when the kill happened. The only invariant needed is backup-file integrity.

## Configuration-as-code (intentional)

`MIGRATION_MAP` lives in `migration_map.sh` — a **passive data module** that declares the associative array and nothing else (no functions, no `main`). It is the single source of truth for forward mappings (`fat1 → fat2`, `opc_d1 → opc_d2`, etc.). `migrator.sh`, `finder.sh`, and `validate.sh` each `source migration_map.sh`; **none of them sources another tool.**

`finder.sh`'s `NAME_SEARCH_PATTERNS` and `CONTENT_SEARCH_PATTERNS` are just `"${!MIGRATION_MAP[@]}"`. Because finder and migrator read the *same* array, anything finder finds is something migrator can rewrite, by construction — the invariant the old "finder sources migrator" coupling protected, now kept without the inverted dependency or the function-namespace bleed it caused.

There is no reverse map: the old `REVERSE_MIGRATION_MAP` (derived via `derive_reverse_map`) was never consumed anywhere, so both were dropped (YAGNI). Derive it at the point of use if a reverse migration is ever needed.

Adding a new pattern is a single edit to `migration_map.sh`. The map is `declare -Ar` (associative + readonly). Note: `declare -A readonly NAME=(...)` is a latent bug (bash parses `readonly` as a separate identifier and `NAME` is NOT actually readonly). The `-Ar` form is the correct shorthand and is documented inline.

## Bash 4.2 idioms to preserve

The host runs bash 4.2.46 (RHEL 7 era). Namerefs (`declare -n`) require 4.3+, so they cannot be used. **`eval`-based associative-array indirection** stands in for namerefs wherever a function must read or populate a caller-named array: `apply_path_mapping` and `replace_content_in_file` in `common.sh`, and `tracking_load_latest` in `tracking.sh` (which populates four caller-declared result arrays — collapsing five copy-pasted parse loops into one). The eval'd arguments are array names from trusted source files (no user input), so the usual injection concerns don't apply. Don't "modernize" this without bumping the version floor and updating `require_bash_version` calls. The suite is verified on real bash 4.2.46 + GNU coreutils via the `centos:7` container harnesses (selective_copy's test needs rsync, absent from the base image — add it via the CentOS vault repos, or use the prebuilt `bashutils7:rsync` image).

**Empty-array expansion under `set -u` is the other 4.2 trap.** `"${arr[@]}"` on an EMPTY array aborts with "unbound variable" on bash 4.2/4.3 (fixed in 4.4 — so it is invisible on bash 5.x and only bites on the target 4.2.46). Use `"${arr[@]+"${arr[@]}"}"` for any array that may be empty, or guard with `[ "${#arr[@]}" -gt 0 ]` before the loop. This bit `selective_copy.sh` (an empty `EXCLUDE_MAPPING` and no-match `rsync_exclude_args`) and surfaced only once tested on real 4.2.46.

`selective_copy.sh` is **config-driven**: nothing job-specific is hardcoded. `--config <file>` (a sourced bash snippet — see `selective_copy.conf.example`) supplies `SOURCE_BASE_DIR`, `TARGET_BASE_DIR`, an optional fixed `STAGING_DIR`, and the `COPY_MAPPING` / `SYMBOLIC_LINK_MAPPING` / `EXCLUDE_MAPPING` / `NESTED_ITEM_TRANSFORM` arrays; `--source-base` / `--target-base` / `--staging-dir` override the config. `prepare` honors a fixed `--staging-dir` (created + perms set, must be empty) or falls back to `mktemp`.

## Shell hygiene patterns (don't drop these when editing)

- **`set -euo pipefail`** in every executable script, set after `source common.sh`.
- **`require_bash_version`** check up front. Fail at startup with a clear message rather than mysteriously deep in the run.
- **`local count=$((count + 1))`** instead of `((count++))` — the latter returns exit 1 on the first call and is killed by `set -e`.
- **Process substitution** `done < <(find ... -print0)` instead of `find ... | while read` — pipes run the while loop in a subshell and silently drop any state set inside.
- **`grep -v ... || true`** when filtering tracking files. If every line matches, grep exits 1 and pipefail kills the script — the `|| true` is load-bearing.
- **`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`** at the bottom of every executable script so it can be sourced without firing `main`. The tools no longer source each other — they source the `migration_map.sh` / `tracking.sh` / `backup.sh` library modules, which carry an idempotent-source guard (`[ -n "${_X_SH:-}" ] && return 0`) and define data/functions only, no `main`.
- **`replace_content_in_file`** in common.sh writes via `cat tmp > file`, not `mv tmp file`. This preserves the original inode's perms/owner/ACL/timestamps. mtime is bumped (and must be restored by the caller from the recorded original).
- **Backup directory mirrors the original tree shape**, not basename + epoch. Collisions are impossible regardless of name overlap and rollback is structural rather than tracking-dependent.
- **`csv_read_3col` skips rows with an empty `Absolute_Path`** (blank or whitespace-only lines, a trailing newline). Without this, an empty field reaches `assert_under_root ""` and `die`s mid-run — one stray blank line would abort the entire migration. (Bug B.)
- **`migrate_directory` renames inner entries, not just file contents.** When a directory row is renamed, a descendant that is also its own CSV row has a now-stale path and its row is skipped — so the directory walk is the only place that descendant's NAME can be migrated. It processes deepest-first within the directory (a rename never invalidates a deeper path) and the directory's backup is taken first, so rollback stays faithful. (Bug C.)

## Running

```bash
# --- LOCAL SMOKE TEST (any Linux box, no fat1/fat2 needed) ---
bash bin/run_all_tests.sh

# --- MOCK REHEARSAL on the real host (touches /tmp only) ---
bash bin/setup_migrator_test.sh --mode all \
    --csv tests/cases/fat2.csv \
    --source-root /applications/opc_d2

# --- INDIVIDUAL PHASES ---
bash bin/mock_build.sh --csv tests/cases/fat2.csv \
                       --source-root /applications/opc_d2 \
                       --mock-root /tmp/mock_f2
bash bin/migrator.sh --mode execute \
                     --root /tmp/mock_f2 \
                     --csv /tmp/mock_f2/mock_input.csv \
                     --workdir /tmp/migration_f2_test
bash bin/validate.sh --root /tmp/mock_f2 --workdir /tmp/migration_f2_test \
                     --scan-root /tmp/mock_f2

# --- LIVE MIGRATION (the real thing) ---
bash bin/migrator.sh --mode execute \
                     --root /applications/opc_d2 \
                     --csv tests/cases/fat2.csv \
                     --workdir /tmp/migration_f2 \
                     --yes               # countdown follows

# --- ROLLBACK (works for failed OR successful runs) ---
bash bin/migrator.sh --mode rollback \
                     --root /applications/opc_d2 \
                     --workdir /tmp/migration_f2 \
                     --yes

# --- CLEANUP (deletes backups + tracking) ---
bash bin/migrator.sh --mode cleanup \
                     --root /applications/opc_d2 \
                     --workdir /tmp/migration_f2
```

## Legacy / wind-down

- **`bin/setup_finder_test.sh`** and **`bin/setup_linux_test.sh`** still exist but pre-date the lib refactor. They print operator instructions rather than running tests. Replace or delete on a future pass.
- **`bin/diagnose_migrator_bug.sh`** was built to diagnose a specific harness bug (now fixed: `cp -a` is checked, `[ -d ]` has the `[ ! -L ]` guard). It remains useful as a forensic tool if a new harness bug appears, but the bug it was built for is no longer reachable in the rewritten orchestrator.
- **`docs/DIAGNOSE_WORKFLOW.md`** describes the remote-operator runbook for the old diagnostic. Useful as a template if another remote-diagnose situation arises, but not part of the active workflow.

## Author conventions

- Commits: no `Co-Authored-By: Claude` trailer. Author is Abhijit Bandyopadhyay <abhijitb@gmail.com>.
- Commit message style: `<type>: <description>` — `feat | fix | docs | refactor | test | chore`.
