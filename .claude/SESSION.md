# SESSION

Last Updated: 2026-05-29 19:43 IST
Branch: `refactor/decouple-migration-map` (4 commits ahead of `main`; NOT pushed)
Remote: `git@github.com:babhijit/bash-utils.git`
Current Focus: Architecture refactor + bash-4.2 edge-case bug fixes + `selective_copy.sh` made config-driven — all done and verified.

## Status

**COMPLETE — clean handover.** Working tree clean (only `.claude/SESSION.md` modified, `.claude/settings.local.json` untracked/ignored). Nothing in progress. Next action is operational: define the real migration run config and/or push the branch.

## Completed This Session

### Architectural refactor (commit `7374eb0`)

- **`bin/migration_map.sh`** (new) — passive data module; `MIGRATION_MAP` only, no functions, no `main`. Idempotent-source guard.
- **`bin/tracking.sh`** (new) — tracking-file contract (header/append/latest_status/field) + `tracking_load_latest()`, which collapsed **5** copy-pasted `tail+while-read` parse loops (migrator ×4, validate ×1) into one eval-indirection reader.
- **`bin/backup.sh`** (new) — `backup_path_for()` (backup-tree layout contract shared with validate) + `backup_cp()`.
- **`bin/migrator.sh`** / **`bin/finder.sh`** / **`bin/validate.sh`** rewired: no tool sources another tool. Dropped dead `REVERSE_MIGRATION_MAP` + `derive_reverse_map` (YAGNI — never consumed anywhere).
- **`bin/common.sh`** trimmed: `derive_reverse_map` removed; eval-indirection note updated.
- **Tier 3 (unify validators) deliberately skipped**: real duplication was gone after Tier 2; the 3 validators check genuinely different post-conditions.

### Bug fixes — found by running current scripts on real bash 4.2.46, then fixed

| Bug | Where | Fix |
| --- | --- | --- |
| A — validate-rollback compared doubled path → vacuous `pass=0` green | `setup_migrator_test.sh` | Strip `MOCK_ROOT` yields the source path directly; no re-prepend of `SOURCE_ROOT`. Now `pass=114`. |
| B — one blank/whitespace CSV line aborted the whole run | `common.sh:csv_read_3col` | Skip rows with empty `Absolute_Path`; warn if other columns were non-empty. |
| C — dir-rename + descendant row: descendant NAME never migrated | `migrator.sh:migrate_directory` | Renames inner entries deepest-first (`find -depth`), rollback-safe (backup taken before any mutation). |
| D — `selective_copy` aborted on bash 4.2: `"${arr[@]}"` on empty array under `set -u` | `selective_copy.sh` | `"${arr[@]+"${arr[@]}"}"` for `EXCLUDE_MAPPING` and `rsync_exclude_args`. |
| E — `selective_copy` double-nested: `TARGET/bin/bin/…` | `selective_copy.sh` prepare + deploy | Normalize `dest_name` (strip trailing `/`); copy directory CONTENTS into dest (`rsync src/ dst/`). |

### `selective_copy.sh` made config-driven (commits `2c04412`, `c236c63`)

- `--config <file>` (sourced bash snippet) supplies `SOURCE_BASE_DIR`, `TARGET_BASE_DIR`, optional `STAGING_DIR`, and the four array mappings. Nothing job-specific is hardcoded.
- `--source-base` / `--target-base` / `--staging-dir` override the config (CLI wins).
- `prepare` honors a fixed `--staging-dir` (created + perms set, must be empty) or falls back to `mktemp`.
- `bin/selective_copy.conf.example` documents the full contract.
- Per-mode fail-fast asserts added for required values.
- **Bash-4.2 empty-array idiom** `"${arr[@]+"${arr[@]}"}"` is MANDATORY under `set -u`; plain `"${arr[@]}"` on an empty array aborts on 4.2/4.3, invisible on 5.x.

### Tests and verification

- **`tests/run_container_tests.sh`** — materializes source tree from `fat2.csv`, runs full pipeline (mock_build → migrator → validate → rollback → validate-rollback).
- **`tests/edge_cases.sh`** — 7 adversarial cases (E1–E7): blank CSV lines, spaces in paths, dir+descendant rename, fat1/fat2 coexist, dangling symlink, rollback round-trip, dir-mtime drift.
- **`tests/selective_copy_test.sh`** — two real non-root users (`srcu`/`tgtu`), prepare/deploy/cleanup, 13 assertions.
- **Verified on `centos:7` (bash 4.2.46 + GNU coreutils)**: `run_all_tests.sh` ALL TESTS PASSED · `edge_cases.sh` 15/15 · `run_container_tests.sh` fat2 84/84, rollback `pass=114` · `selective_copy_test.sh` 13/13.
- Docker image **`bashutils7:rsync`** = `centos:7` + rsync (via CentOS vault repos) — needed for `selective_copy_test.sh`.

### Documentation

- **`CLAUDE.md`** updated: flat-layout tree (new modules listed), "Configuration-as-code" section (map now in `migration_map.sh`, reverse map dropped), bash-4.2 idioms (eval-indirection + empty-array trap), Shell hygiene bullets (Bugs B + C patterns), selective_copy config model.
- **`CLAUDE.md`** also notes: macOS CANNOT run this suite (BSD coreutils + bash 5.x); all real verification is in-container.

## In Progress

Nothing.

## Next Steps (priority order)

1. **Push + PR** (branch `refactor/decouple-migration-map` is NOT pushed):

   ```bash
   git push -u origin refactor/decouple-migration-map
   gh pr create ...
   ```

2. **Define the real migration run config**: write a `selective_copy.conf` (or pass CLI flags) for the actual DR job:
   - Which items to copy from `/applications/opc_d1` → `/applications/opc_d2` (`COPY_MAPPING`)
   - Any exclusions, symlink remaps, nested transforms
   - Staging path: e.g. `/tmp/test_f2/migration`
   - Deploy scripts to `/tmp/test_f2/bin` on the target host

3. **Dry-run the full pipeline** once the config is written:

   ```bash
   # As opc_d1:
   bash /tmp/test_f2/bin/selective_copy.sh --mode prepare --config ./job.conf \
       --source-user opc_d1 --target-user opc_d2
   # As opc_d2:
   bash /tmp/test_f2/bin/selective_copy.sh --mode deploy --config ./job.conf \
       --target-user opc_d2 --staging-dir /tmp/test_f2/migration
   bash /tmp/test_f2/bin/migrator.sh --mode execute \
       --root /applications/opc_d2 --csv fat2.csv --workdir /tmp/migration_f2 --yes
   bash /tmp/test_f2/bin/validate.sh --root /applications/opc_d2 \
       --workdir /tmp/migration_f2 --scan-root /applications/opc_d2
   ```

4. **Confirm on the real RHEL7 host** (centos:7 is a close proxy — bash 4.2.46, same GNU coreutils; but the real host is ground truth).

## Blockers

- **Real `COPY_MAPPING` is operator knowledge** — which items to copy from FAT1 tree into FAT2 is not in the codebase; only the operator can specify it.
- Branch not pushed (no blocker; just not done yet).

## Files Touched This Session

| File | Change |
| --- | --- |
| `bin/migration_map.sh` | NEW — passive MIGRATION_MAP data module |
| `bin/tracking.sh` | NEW — tracking contract + tracking_load_latest() |
| `bin/backup.sh` | NEW — backup_path_for() + backup_cp() |
| `bin/migrator.sh` | Rewired to modules; Bug C fix; backup_cp; tracking_load_latest |
| `bin/finder.sh` | Rewired to migration_map.sh (no longer sources migrator) |
| `bin/validate.sh` | Rewired to modules (no longer sources migrator); tracking_load_latest |
| `bin/common.sh` | Bug B fix; derive_reverse_map removed |
| `bin/setup_migrator_test.sh` | Bug A fix |
| `bin/selective_copy.sh` | Config-driven; Bugs D + E fixed |
| `bin/selective_copy.conf.example` | NEW — sample job config |
| `bin/fix_dir_mtimes.sh` | Pre-existing uncommitted fix (now committed) |
| `tests/run_container_tests.sh` | NEW — fat2 pipeline harness |
| `tests/edge_cases.sh` | NEW — adversarial edge battery |
| `tests/selective_copy_test.sh` | NEW — two-user prepare/deploy/cleanup test |
| `tests/fixtures/test_fix_dir_mtimes.sh` | NEW — fix_dir_mtimes fixture test |
| `CLAUDE.md` | Architecture + bash-4.2 idioms + selective_copy config model |
| `.claude/SESSION.md` | This file |

## Key Decisions

- **No Tier 3 (validator unification)**: real dup already removed; validators check different post-conditions.
- **Fix C via `migrate_directory` inner-rename, NOT literal row reorder**: reorder would make parent's backup capture mutated children → stray files on rollback.
- **Fix E via contents-copy semantics**: `rsync src/ dst/` on both prepare + deploy; normalize `dest_name` (strip trailing `/`) so `dest_name` is the rename target, not a nesting wrapper.
- **selective_copy is config-driven**: no hardcoded parent/root dirs.
- **Bash-4.2 empty-array idiom** `"${arr[@]+"${arr[@]}"}"` is mandatory under `set -u` on target 4.2.46.
- **Keep per-tool flags** (not a unified cross-tool config): selective_copy uses `--config`; migrator/validate use their own flags.
- **No `Co-Authored-By: Claude`** on commits.

## Resume Hints

- Run `/project:resume` at the start of the next session to load this context.
- `centos:7` Docker image is already pulled; `bashutils7:rsync` is built locally (325 MB). Test commands: `docker run --rm -v "$PWD":/work -w /work centos:7 bash tests/run_container_tests.sh` and `docker run --rm -v "$PWD":/work -w /work bashutils7:rsync bash tests/selective_copy_test.sh`.
- The real operational question (what to copy, from where to where) has NOT been answered yet. That's the next conversation.
