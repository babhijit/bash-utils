# SESSION

Last Updated: 2026-05-30 (Asia/Kolkata)
Branch: `main` @ `100c2e6` (PR #3 merged). Also open: `feat/audit-env` (unmerged).
Remote: `git@github.com:babhijit/bash-utils.git`
Current Focus: Migration toolkit is feature-complete and batched for the /tmp cap. The repair engagement is paused at Phase 0, awaiting the host audit.

## Status

Two parallel threads:

1. **Migration toolkit (selective_copy → migrator → validate)** — COMPLETE, all on `main`, fully tested on bash 4.2.46. The big recent change: `selective_copy` is now PHASED/batched (see below).
2. **FAT2 repair engagement** — PAUSED at Phase 0. The read-only audit tool (`bin/audit_env.sh`) + cross-host briefing (`docs/TESTING_AND_MOCK_ENV.md`) are on the **unmerged** `feat/audit-env` branch (PR open). Waiting on the operator to run the audit on the host and return `audit.txt`.

## What landed on `main` this session — PR #3 (`feat/phased-selective-copy`, merge `100c2e6`)

**Why:** `/tmp` on the DR host has a HARD ~1 GB cap, but FAT1 is ~7 GB. The old "stage everything then deploy" model would `ENOSPC` mid-copy. `selective_copy.sh` was rewritten as a **single phased/batched path**:

- `plan` (opc_d1, once) — file-granular bin-pack into ≤-budget batches (default 950 MiB = `STAGING_BUDGET_BYTES`); records every dir's mode+mtime; warns on a single file > budget.
- `prepare` (opc_d1) — stage the next batch into `STAGING_DIR`, write a **per-batch attribute-reference CSV** (the "reference for the problematic files"), widen perms (+r) for cross-user read. Auto-advances; free-space preflight aborts BEFORE rsync.
- `deploy` (opc_d2) — rsync staging → target, **restore mode+mtime from the CSV** (NOT ownership — target stays opc_d2-owned), then **drain** staging.
- `finalize` (opc_d2, once) — symlinks + nested transforms + **deepest-first directory-mtime reconcile** (dirs written across batches have bumped mtimes until then).
- `status` / `cleanup [--cleanup-state]`.
- Two **independent** logins, **no inter-process sync** — marker files in `STATE_DIR` (`batch_NNN.{PLANNED,STAGED,DEPLOYED,*_FAILED}`); each user writes only its own. Resumable; dual logging (per-user `<state>/<user>.log` + machine `events.<user>.jsonl`); live `rsync --info=progress2` console.
- `migrator.sh` gained a backup free-space **preflight** (sum CSV `du -sb` vs `check_free_space_bytes`) before the first backup.
- `tests/docker/` — a login-able **two-user rehearsal host** (`rehearse.sh`: build/up/login/ssh-on/down) to dry-run the real cross-user PHASE 0 before the live box.

**Bugs caught by in-container testing (would have been silent on bash 5.x):**

| Bug | Fix |
| --- | --- |
| `IFS=$'\t' read` collapses consecutive tabs → empty `%l` (symlink target, empty for files) shifted fields → **every regular file's attrs skipped** (mode never restored) | put the empty-capable field LAST in `find -printf` |
| Sticky `1777` staging → deploy user can't delete stage user's files → **cross-user drain fails** | staging/state are `0777` (not sticky) — documented why |
| `>>` open error leaks before `2>/dev/null` binds; shared event log not writable by 2nd user | `{ …; } 2>/dev/null` grouping + per-USER log/event files |

**Tests (all green on centos:7 / bash 4.2.46):** `phased_copy_test.sh` 22/22 (content/mode/mtime/dir-mtime/symlink exactness, rename/exclude/empty-dir/spaces/oversize, resume, free-space guard), `selective_copy_test.sh` 14/14 (TWO real users, cross-user drain), `migrator_preflight_test.sh` 7/7, plus run_all / run_container / edge_cases / run_mock_env / fix_dir_mtimes all green.

**Docs:** CHEATSHEET / RUNBOOK PHASE 0 rewritten to the rinse-and-repeat batched flow + the rehearsal-env section; CLAUDE.md updated (phased model, marker no-sync, 0777 drain, dual logging, migrator preflight).

## In Progress

Nothing actively in flight. Both engagements are at clean checkpoints.

## Next Steps

1. **Repair engagement (high priority):** operator runs `bin/audit_env.sh` on the host as opc_d2 and returns `audit.txt` → then produce the Phase 1/2 differential analysis + repair-vs-rebuild recommendation (port/path remap tables, per-cert dispositions, ownership model). Then Phase 2b (keystore validity, store password supplied securely), Phase 3 (plan + approval), Phase 4 (idempotent repair scripts, one subsystem at a time, FAT2 writes only).
2. **Merge `feat/audit-env`** when ready (brings `audit_env.sh` + the cross-host briefing to `main`).
3. **Migration run** (whenever the operator chooses): supply the real `COPY_MAPPING` in `$CONF`, rehearse PHASE 0 in `tests/docker`, then run plan → prepare/deploy loop → finalize on the host.

## Blockers

- **`audit.txt` from the host** is the gating input for the repair analysis.
- Real `COPY_MAPPING` (which items to copy fat1→fat2) is operator knowledge, needed before a live PHASE 0.

## Key Decisions

- **Phased/batched selective_copy** (not stage-everything) — the only model that fits ~7 GB through a ~1 GB `/tmp`.
- **Marker-file coordination, no inter-process sync** — each user writes only its own markers; lock-free, resumable, no cross-user writes.
- **Restore mode+mtime, NOT ownership** — FAT2 files are correctly opc_d2-owned; ownership recorded for reference only.
- **Directory mtimes reconciled in finalize**, not per batch (cross-batch bump).
- **`0777` not sticky `1777`** for staging/state — required for the cross-user drain.
- **Military-precision testing standard** (user directive): verify EVERY change in-container (bash 4.2.46) with exactness assertions + failure injection; never trust native/bash-5.x green. Saved to memory.
- **No `Co-Authored-By: Claude`** on commits; author Abhijit Bandyopadhyay.

## Test Environment

- `centos:7` = bash 4.2.46 + GNU coreutils + OpenSSL 1.0.2k (the target runtime). `bashutils7:rsync` = centos:7 + rsync (CentOS vault repos) — needed for selective_copy/phased tests.
- macOS CANNOT run the suite (BSD coreutils + bash 5.x masks bash-4.2 bugs). All verification is in-container.
- `tests/docker/rehearse.sh` builds `bashutils7:rehearsal` — a two-user login-able host for dry-running PHASE 0.

## Resume Hints

- `/project:resume` at next session start.
- Re-verify quickly: `docker run --rm -v "$PWD":/work -w /work bashutils7:rsync bash tests/phased_copy_test.sh`
- Repair engagement context: `bin/audit_env.sh` (Phase 0/1/2 read-only audit) + `docs/TESTING_AND_MOCK_ENV.md` on `feat/audit-env`.
