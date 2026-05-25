# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Bash utilities for a fat1 → fat2 dev-environment cloning workflow used as a DR exercise on a Linux host with **no sudo available**. The host has two unix accounts (fat1 user and fat2 user), each with read access to both trees but write access only to their own. `/tmp` is the only filesystem location both users can write to.

The whole suite assumes Linux + GNU coreutils + bash 4.2+. macOS will not run these scripts (`stat -c`, `touch -d "@epoch"` are GNU-only).

## Flat layout

All scripts live in `bin/`. There is no `bin/lib/` subdirectory because the operator deploys everything to a single working directory (`/tmp/migration_f2/` by convention). Sources resolve via `source "$(dirname "${BASH_SOURCE[0]}")/common.sh"` so any pair of scripts in the same directory composes.

```text
bin/
├── common.sh                  ← shared library (sourced by everyone)
├── finder.sh                  ← discover fat1-style references in a tree
├── csv_reduce.sh              ← reduce finder's 5-col CSV to migrator's 3-col
├── selective_copy.sh          ← two-stage cross-user copy via /tmp
├── mock_build.sh              ← build a sandbox from a CSV (smart selective copy)
├── migrator.sh                ← stateful path/content rewriter with backup/resume/rollback
├── validate.sh                ← post-migration consistency checker
├── setup_migrator_test.sh     ← orchestrator: mock_build → migrator → validate → rollback
├── setup_finder_test.sh       ← (legacy) mock env for finder
├── setup_linux_test.sh        ← (legacy) mock env for selective_copy
├── diagnose_migrator_bug.sh   ← (legacy) read-only diagnostic; useful if a new bug appears
└── run_all_tests.sh           ← synthetic end-to-end smoke; no fat1/fat2 dependency
```

`lib/` and `tests/{fixtures,mocks}/` are now unused placeholders. `tests/cases/fat2.csv` is the real input CSV used during development and as the canonical example.

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

`MIGRATION_MAP` in `migrator.sh` is the single source of truth for forward mappings (`fat1 → fat2`, `opc_d1 → opc_d2`, etc.). The reverse map is derived at runtime via `derive_reverse_map` in common.sh — no duplicate-and-drift.

`finder.sh` sources `migrator.sh` to get the same `MIGRATION_MAP`. Its `NAME_SEARCH_PATTERNS` and `CONTENT_SEARCH_PATTERNS` are just `"${!MIGRATION_MAP[@]}"`. Anything finder finds is something migrator can rewrite, by construction.

Adding a new pattern is a single edit to `MIGRATION_MAP`. The map is `declare -Ar` (associative + readonly). Note: `declare -A readonly NAME=(...)` is a latent bug (bash parses `readonly` as a separate identifier and `NAME` is NOT actually readonly). The `-Ar` form is the correct shorthand and is documented inline.

## Bash 4.2 idioms to preserve

The host runs bash 4.2.46 (RHEL 7 era). Namerefs (`declare -n`) require 4.3+, so they cannot be used. `common.sh` uses **`eval`-based associative-array indirection** in three helpers — `derive_reverse_map`, `apply_path_mapping`, `replace_content_in_file`. The eval'd arguments are array names from trusted source files (no user input), so the usual injection concerns don't apply. Don't "modernize" this without bumping the version floor and updating `require_bash_version` calls.

## Shell hygiene patterns (don't drop these when editing)

- **`set -euo pipefail`** in every executable script, set after `source common.sh`.
- **`require_bash_version`** check up front. Fail at startup with a clear message rather than mysteriously deep in the run.
- **`local count=$((count + 1))`** instead of `((count++))` — the latter returns exit 1 on the first call and is killed by `set -e`.
- **Process substitution** `done < <(find ... -print0)` instead of `find ... | while read` — pipes run the while loop in a subshell and silently drop any state set inside.
- **`grep -v ... || true`** when filtering tracking files. If every line matches, grep exits 1 and pipefail kills the script — the `|| true` is load-bearing.
- **`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`** at the bottom of every executable script so other scripts can source it without firing `main`. `finder.sh` and `validate.sh` source `migrator.sh` to access `MIGRATION_MAP` and `backup_path_for`.
- **`replace_content_in_file`** in common.sh writes via `cat tmp > file`, not `mv tmp file`. This preserves the original inode's perms/owner/ACL/timestamps. mtime is bumped (and must be restored by the caller from the recorded original).
- **Backup directory mirrors the original tree shape**, not basename + epoch. Collisions are impossible regardless of name overlap and rollback is structural rather than tracking-dependent.

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
