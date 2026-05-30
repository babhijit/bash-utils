# SESSION

Last Updated: 2026-05-30 (Asia/Kolkata)
Branch: `main` @ `282ce3a` (clean; all work merged)
Remote: `git@github.com:babhijit/bash-utils.git`
Current Focus: All refactor, bug fixes, mock-env fixture, and docs work is complete and on `main`. Ready for the real migration run.

## Status

**COMPLETE.** Two PRs merged to `main`. Working tree clean (only untracked `.claude/settings.local.json`). The one remaining item is operational: the operator must supply the real `COPY_MAPPING` (which items to copy from `/applications/opc_d1` → `/applications/opc_d2`).

## What landed on `main` this session

### PR #1 — `refactor/decouple-migration-map` (7 commits, merge `7806ab7`)

**Architecture refactor:**

- `bin/migration_map.sh` (new) — passive data module; `MIGRATION_MAP` only. No tool sources another tool anymore.
- `bin/tracking.sh` (new) — tracking-file contract + `tracking_load_latest()`, collapsing 5 copy-pasted parse loops.
- `bin/backup.sh` (new) — `backup_path_for()` + `backup_cp()`; shared contract with validate.
- `bin/migrator.sh`, `bin/finder.sh`, `bin/validate.sh` — rewired to modules; dead `REVERSE_MIGRATION_MAP` / `derive_reverse_map` dropped.
- `bin/selective_copy.sh` — made config-driven (`--config <file>`); no hardcoded paths.
- `bin/selective_copy.conf.example` (new) — sample job config.

**Bug fixes (A–F), all found on real bash 4.2.46:**

| Bug | Fix |
| --- | --- |
| A — validate-rollback vacuous pass (doubled path) | `setup_migrator_test.sh` path strip corrected; now `pass=114` |
| B — blank/whitespace CSV line aborted whole run | `csv_read_3col` skips empty-path rows |
| C — dir-rename + descendant left unmigrated | `migrate_directory` renames inner entries deepest-first |
| D — bash 4.2 empty-array `"${arr[@]}"` abort under `set -u` | `"${arr[@]+"${arr[@]}"}"` in `selective_copy` |
| E — selective_copy double-nested (`TARGET/bin/bin`) | Normalize `dest_name`; copy dir CONTENTS into dest |
| F — rollback deleted coexisting `fat1_X` (redirect case) | `restore_from_backup` no longer removes `orig_path` in redirect case |

**New tests (all verified green on centos:7 / bash 4.2.46):**

- `tests/run_container_tests.sh` — fat2 pipeline materialize → full run
- `tests/edge_cases.sh` — 15/15 adversarial cases
- `tests/selective_copy_test.sh` — two-user prepare/deploy/cleanup, 13/13
- `tests/setup_mock_env.sh` — builds ONE realistic mock source (fat2 + E1–E7 edges, real per-type content: XML, properties, ini, cnf, cfg, shell, crontab, binary JKS)
- `tests/run_mock_env_test.sh` — drives full pipeline against it; validate-rollback `pass=121 fail=0`
- `tests/fixtures/test_fix_dir_mtimes.sh` — ALL TESTS PASSED

**Safety tag:** `pre-refactor-checkpoint` → `0d4317d` (main just before PR #1 merged). Still live on remote. Rollback: `git reset --hard pre-refactor-checkpoint`.

### PR #2 — `docs/ops-playbook-update` (1 commit, merge `282ce3a`)

`CHEATSHEET.txt` and `RUNBOOK.txt` rewritten as **concrete, copy-paste playbooks for this host**:

- Set-once variable block: `BIN=/tmp/test_f2/bin`, `SRC_ROOT=/applications/opc_d1`, `TGT_ROOT=/applications/opc_d2`, `STAGING=/tmp/test_f2/migration`, `WORKDIR=/tmp/migration_f2`, `CSV`, `CONF`.
- Roles explicit: **opc_d1 = source/FAT1, opc_d2 = target/FAT2**.
- New PHASE 0 (config-driven selective_copy).
- Behaviors documented: blank CSV lines, spaces in paths, dir+descendant rename, fat1/fat2 coexist + rollback behavior, dangling symlinks, binary JKS caveat.
- VERIFY section (centos:7 / `bashutils7:rsync` container commands).
- Recovery paths point at PHASE 0.

## In Progress

Nothing.

## Next Steps

1. **Supply the real `COPY_MAPPING`** — which items to copy from `/applications/opc_d1` → `/applications/opc_d2` (operator knowledge; not in the codebase). Once provided:
   - Fill in `$CONF` (`/tmp/test_f2/selective_copy.conf`) with actual `COPY_MAPPING`, exclusions, transforms.
   - Dry-run `selective_copy prepare` (as opc_d1) in the container against the real source tree.

2. **Deploy scripts to the target host:**
   - Copy `bin/*.sh` (ALL of them — includes `migration_map.sh`, `tracking.sh`, `backup.sh`, `common.sh` — every file) to `/tmp/test_f2/bin/` on the host. They must all sit in the same directory to resolve each other.

3. **Run mock rehearsal on the host** (Step 1 in RUNBOOK):

   ```bash
   NONINTERACTIVE=1 bash /tmp/test_f2/bin/setup_migrator_test.sh --mode all \
       --csv /tmp/test_f2/fat2.csv --source-root /applications/opc_d2
   ```

4. **Run live migration** (Step 2 in RUNBOOK) — only after mock passes:

   ```bash
   bash /tmp/test_f2/bin/migrator.sh --mode execute \
       --root /applications/opc_d2 --csv /tmp/test_f2/fat2.csv \
       --workdir /tmp/migration_f2 --yes
   ```

## Blockers

- **Real `COPY_MAPPING`** is the only remaining input the operator must provide (which items `selective_copy` copies).
- `selective_copy` was already run successfully in this DR per CLAUDE.md — PHASE 0 may be a no-op for the current state of `/applications/opc_d2`.

## Files Touched This Session

| File | Change |
| --- | --- |
| `bin/migration_map.sh` | NEW |
| `bin/tracking.sh` | NEW |
| `bin/backup.sh` | NEW |
| `bin/selective_copy.conf.example` | NEW |
| `bin/migrator.sh` | Rewired + Bugs C, F fixed |
| `bin/finder.sh` | Rewired to modules |
| `bin/validate.sh` | Rewired to modules |
| `bin/common.sh` | Bug B fixed; `derive_reverse_map` removed |
| `bin/setup_migrator_test.sh` | Bug A fixed |
| `bin/selective_copy.sh` | Config-driven; Bugs D, E fixed |
| `bin/fix_dir_mtimes.sh` | Hardened (pre-existing commit) |
| `tests/setup_mock_env.sh` | NEW — realistic mock source generator |
| `tests/run_mock_env_test.sh` | NEW — full-pipeline runner with edge assertions |
| `tests/run_container_tests.sh` | NEW |
| `tests/edge_cases.sh` | NEW |
| `tests/selective_copy_test.sh` | NEW |
| `tests/fixtures/test_fix_dir_mtimes.sh` | NEW |
| `CHEATSHEET.txt` | Rewritten for this host |
| `RUNBOOK.txt` | Rewritten for this host |
| `CLAUDE.md` | Architecture + bash-4.2 idioms + selective_copy model |

## Key Decisions

- **No tool sources another tool** — migration_map/tracking/backup are library modules.
- **Fix C via `migrate_directory` inner-rename** — not row reorder (would corrupt backups).
- **Fix F: rollback must NOT delete the coexisting `fat1_X`** — it predates the migration.
- **Realistic mock content** — dispatch by file type (XML, properties, ini, cnf, cfg, sh, jks) is what surfaces bugs that dummy files miss (Bug F was found this way).
- **Tier 3 (validator unification) skipped** — real dup removed by Tier 2; validators check distinct post-conditions.
- **bash-4.2 empty-array idiom** `"${arr[@]+"${arr[@]}"}"` is mandatory under `set -u`.
- **selective_copy config-driven** — per-tool flags kept (no unified cross-tool config).
- **No `Co-Authored-By: Claude`** on commits.

## Test Environment

- `centos:7` = bash 4.2.46 + GNU coreutils. Already pulled locally.
- `bashutils7:rsync` = centos:7 + rsync (via CentOS vault repos). Built locally (325 MB). Needed only for `selective_copy_test.sh`.
- macOS CANNOT run the suite (BSD coreutils + bash 5.x). All verification is in-container.

## Resume Hints

- `/project:resume` at next session start.
- Quick re-verify: `docker run --rm -v "$PWD":/work -w /work centos:7 bash tests/run_mock_env_test.sh`
- Safety tag is live: `git show pre-refactor-checkpoint` → `0d4317d`.
- The real COPY_MAPPING is the first conversation of the next session.
