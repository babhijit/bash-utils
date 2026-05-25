# SESSION

Last Updated: 2026-05-25 (Asia/Kolkata)
Branch: main
Tag at handoff: `first-draft`
Remote: `git@github.com:babhijit/bash-utils.git`
Current Focus: Verifying the refactored migration suite end-to-end on a Linux host. The code is feature-complete from the macOS side but UNVERIFIED — none of the GNU-coreutils-dependent paths have been executed.

## Status

Major refactor complete. All 8 structural issues from the earlier code review are addressed, plus the four hard DR requirements (backup, validate, resume, rollback+cleanup). The suite is reorganized into a flat `bin/` hierarchy with a shared `common.sh` library. Tagged `first-draft` on commit.

Next person to pick up: run `bash bin/run_all_tests.sh` on Linux. If it passes, the implementation is functionally correct and ready for mock-rehearsal against the real fat2 tree.

## Completed This Session

- **bin/common.sh (new)** — shared utilities: structured logging, quote-aware CSV parser, sed-safe literal content replacement, `--root` assertion, lstat helpers, tmpfs warning, 5-second confirmation gate, run-id generator. No `/tmp` defaults baked in; all callers set their own.

- **bin/migrator.sh (rewrite)** — required `--root` guard with `assert_under_root` per CSV row, `--workdir` defaulting to `/tmp/migration_f2`, append-only tracking at `<workdir>/progress.log`, resume model where `BACKED_UP`-but-not-`COMPLETED` rows trigger restore-from-backup then re-execute, single `MIGRATION_MAP` with reverse derived at runtime, sed-safe content rewrite, child-file mtime restore inside directory walks, `--dry-run` that's also resume-safe, `--yes` + 5-second countdown for non-`/tmp` roots, backup tree mirroring original tree shape (no collisions).

- **bin/finder.sh (refactor)** — now sources `migrator.sh` for `MIGRATION_MAP` keys (single source of truth), fixed `-name` → `-iname` in prune (case-insensitive throughout), dedupes by absolute path before emitting, `--minimal` flag for 3-col output suitable for migrator.

- **bin/mock_build.sh (new)** — the "smart selective copy". Reads a 3-col CSV, copies LIVE paths from `--source-root` to `--mock-root` (default `/tmp/mock_f2`), per-copy `verify_lstat_match`, refuses if `--mock-root` is under `--source-root`, emits `mock_input.csv` for migrator. Idempotent: re-runs skip rows whose mock copy is already lstat-verified.

- **bin/validate.sh (new)** — standalone post-migration consistency check. For every COMPLETED row: migrated path exists, backup exists, mtime matches recorded ts, lstat type matches backup, content equals expected rewrite of backup, symlink target matches expected. Optional `--scan-root` for tree-wide residual fat1 reference scan (informational).

- **bin/setup_migrator_test.sh (rewrite)** — thin orchestrator. Delegates to `mock_build.sh` → `migrator.sh` → `validate.sh` → rollback → `validate-rollback` (diffs rolled-back mock against original source bit-for-bit) → cleanup. No duplicated logic.

- **bin/selective_copy.sh (refactor)** — `mktemp -d /tmp/scopy.XXXXXX` per-run staging (no more shared `/tmp/selective_copy_stage`), tab-separated state file (handles paths with spaces), `--shared-group` flag for 2770 + setgid alternative to chmod 777, `--source-user` / `--target-user` identity sanity checks, state-file tamper detection (newest-inner-file vs state-file mtime), new `--mode cleanup`.

- **bin/csv_reduce.sh (new)** — collapses finder's 5-col diagnostic CSV to migrator's 3-col format, deduped by absolute path. Idempotent on 3-col input.

- **bin/run_all_tests.sh (new)** — synthetic end-to-end smoke. Builds its own source tree under `/tmp/run_all_tests.<pid>/` exercising file/dir/symlink, runs the full pipeline including resume-no-op and rollback. No fat1/fat2 dependency.

- **CLAUDE.md (rewrite)** — documents both pipelines (live + mock), the four hard requirements with their implementations, the `/tmp` constraint, `--root` guard, resume model, bash 4.2 idioms, the flat layout convention.

- **docs/DIAGNOSE_WORKFLOW.md** — annotated as historical at the top; original content preserved as a template for future remote-diagnose situations. Not committed (covered by `.gitignore`'s `docs/` rule).

## Critical Verification Gap

Everything was written on macOS. None of the GNU-coreutils-dependent code paths (`stat -c`, `touch -d "@epoch"`, `find -printf`, `df --output=`) have been executed. The implementation could have a typo or a wrong flag and we wouldn't know.

**First action on Linux: `bash bin/run_all_tests.sh`**. If that passes, everything important works.

## In Progress

Nothing actively in progress. Refactor is at a clean checkpoint.

## Next Steps (priority order)

1. **Smoke test on Linux**: `bash bin/run_all_tests.sh`. Expect "ALL TESTS PASSED" at the end. If anything fails, the error message + stderr should point at the broken bit.
2. **Mock rehearsal against real fat2 tree** (only after #1 passes):

   ```bash
   bash bin/setup_migrator_test.sh --mode all \
       --csv tests/cases/fat2.csv \
       --source-root /applications/opc_d2
   ```

3. **Live migration** (only after #2 passes including `validate-rollback`):

   ```bash
   bash bin/migrator.sh --mode execute \
       --root /applications/opc_d2 \
       --csv tests/cases/fat2.csv \
       --workdir /tmp/migration_f2 \
       --yes
   ```

4. **Post-live validate**:

   ```bash
   bash bin/validate.sh --root /applications/opc_d2 \
       --workdir /tmp/migration_f2 \
       --scan-root /applications/opc_d2
   ```

## Blockers

- **No Linux access from macOS side**, hence the verification gap.
- **`/tmp` is the only writable shared location** on the live host — backups are tmpfs-vulnerable. CLAUDE.md flags this and `check_tmpfs_warning` warns at runtime, but operator discipline (one continuous session, validate before logout) is the only real mitigation.

## Key Decisions

- **Flat hierarchy in `bin/`** — no `bin/lib/`, no `bin/utils/` subdir. Operator deploys everything to a single workdir; all sources resolve via `dirname "${BASH_SOURCE[0]}"`.
- **`/tmp/migration_f2/` as canonical workdir** (not per-run unique). Re-running migrator with the same `--workdir` resumes from the tracking file. To start over, `--mode cleanup` first.
- **`--root` is REQUIRED on migrator** and asserted against every CSV row. The single load-bearing defense against accidentally pointing at fat1.
- **Bash 4.2 floor** preserved. Eval-based associative-array indirection in `common.sh` (no namerefs). Documented inline.
- **Resume by restore-then-redo, not by step-tracking.** `BACKED_UP`-but-not-`COMPLETED` rows always restore from backup before retrying. Backup is the only invariant.
- **Backup tree mirrors original tree shape** under `<workdir>/backups/`. Collisions impossible regardless of basename overlap.
- **`docs/` is gitignored** (per pre-existing `.gitignore`) — `DIAGNOSE_WORKFLOW.md` stays local-only.

## Repo State Reference

```text
bash-utils/
├── CLAUDE.md                            ← refactored, documents both pipelines
├── .claude/SESSION.md                   ← this file
├── .gitignore                           ← pre-existing; excludes docs/, *.log
├── bin/
│   ├── common.sh                        NEW
│   ├── finder.sh                        REFACTOR
│   ├── csv_reduce.sh                    NEW
│   ├── selective_copy.sh                REFACTOR
│   ├── mock_build.sh                    NEW
│   ├── migrator.sh                      REWRITE
│   ├── validate.sh                      NEW
│   ├── setup_migrator_test.sh           REWRITE (thin orchestrator)
│   ├── setup_finder_test.sh             unchanged (legacy)
│   ├── setup_linux_test.sh              unchanged (legacy)
│   ├── diagnose_migrator_bug.sh         unchanged (legacy)
│   └── run_all_tests.sh                 NEW
├── docs/DIAGNOSE_WORKFLOW.md            UNCOMMITTED (gitignored), annotated historical
├── lib/                                 unused placeholder (.gitkeep)
└── tests/
    ├── cases/fat2.csv                   the real test input
    ├── fixtures/                        placeholder
    └── mocks/                           placeholder
```

## Resume Hints for Future Claude

- **Run `bash bin/run_all_tests.sh` first.** That's the canonical "is this implementation correct" check. Don't spend time auditing code if the smoke test passes.
- **If `run_all_tests.sh` fails on Linux**, the error will name a specific assertion (`mtime preserved (label)`, `exists`, `lacks 'FAT1'`, etc.) — that points at which phase broke. Read the relevant function in migrator.sh / mock_build.sh / common.sh.
- **`migrator.sh` sources are intentional**: `finder.sh` and `validate.sh` source it to get `MIGRATION_MAP` and `backup_path_for()`. The sourcing guard at the bottom prevents `main` from firing.
- **bash 4.2** — do not introduce `declare -n` or `${var@operator}` or other 4.3+ features without a discussion.
- **`/tmp` is non-negotiable as the only writable shared location.** Don't propose `$HOME` or `/var/tmp` alternatives.
- **No `Co-Authored-By: Claude` on commits.** Per the user's global CLAUDE.md.
