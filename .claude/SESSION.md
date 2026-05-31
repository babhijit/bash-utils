# SESSION

Last Updated: 2026-05-30 (Asia/Kolkata)
Branch: `main` only — **single branch** (all feature branches merged + deleted).
Remote: `git@github.com:babhijit/bash-utils.git`
Current Focus: **FAT2 repair engagement, at the Phase 0 gate.** Read-only audit tooling is built and on `main`; awaiting the operator to run it on the host and return the report. NO writes to FAT2 yet.

> Full engagement analysis/approach/plan: **[docs/FAT2_REPAIR_ENGAGEMENT.md](../docs/FAT2_REPAIR_ENGAGEMENT.md)** (read this first on resume). Task backlog: **[.claude/TASKS.md](TASKS.md)**.

## The two things to understand on resume

1. **This `bash-utils` repo IS the "buggy migration scripts" the Operating Brief names as the root cause** of FAT2's broken state. We audited + hardened them this session; that does NOT mean re-run them — it makes the *rebuild option* trustworthy IF the audit later chooses it.
2. **The engagement's Phase 0 = read-only Discovery (`bin/audit_env.sh`), NOT `selective_copy`.** The CHEATSHEET's "PHASE 0" is `selective_copy` (a WRITE, and the suspect) — different thing. Don't conflate them. Nothing writes to FAT2 until a Phase 3 plan is approved.

## Status

- **Migration toolkit** — COMPLETE + hardened, all on `main`, fully tested on bash 4.2.46. It is the PARKED rebuild mechanism, reached for only if Phase 3 says "rebuild."
- **Repair engagement** — at **Phase 0**. `bin/audit_env.sh` (read-only Phase 0/1/2 audit) is on `main`. Blocked on the host audit output.

## What is on `main` (single branch — everything consolidated)

- `bin/audit_env.sh` — read-only differential audit (Phase 0/1/2); two-login manifest handoff × LEVEL 1/2 snapshot/drill-down; **rewrite-aware** (sources `migration_map.sh`, compares FAT2 to the expected rewrite, not raw FAT1); masks secrets; RO on both trees.
- `bin/selective_copy.sh` — PHASED/batched cross-user copy under the ~1 GB `/tmp` cap (plan → prepare/deploy loop → finalize; marker-based no-sync; per-batch attribute-reference CSV; resume; free-space preflight; dual logging; live progress).
- `bin/migrator.sh` — in-place fat1→fat2 rewrite + backup/resume/rollback + a new backup free-space preflight.
- `bin/validate.sh`, `bin/finder.sh`, `bin/fix_dir_mtimes.sh`, `bin/mock_build.sh`; libs `common.sh`/`migration_map.sh`/`tracking.sh`/`backup.sh`.
- Tests (all green in centos:7 / bash 4.2.46): `phased_copy_test.sh` 22/22, `selective_copy_test.sh` 14/14 (two real users), `migrator_preflight_test.sh` 7/7, plus run_all / run_container / edge_cases / run_mock_env / fix_dir_mtimes.
- `tests/docker/` — login-able two-user rehearsal host (`rehearse.sh`).
- Docs: CHEATSHEET.txt, RUNBOOK.txt (batched PHASE 0 + rehearsal section), CLAUDE.md, `docs/TESTING_AND_MOCK_ENV.md`, `docs/FAT2_REPAIR_ENGAGEMENT.md` (this engagement).

## Next Steps

1. **PHASE 0 (now):** operator deploys `bin/audit_env.sh` (self-contained, the only
   file needed) and runs **TWO passes** — `opc_d2` can't read all of FAT1, so each
   login is authoritative for its own tree via a `/tmp` manifest handoff. Adjust
   `EXCLUDE_DIRS` to the real backup-dir names (they hold stale opc_d1 configs):
   ```
   # 1) as opc_d1 (writes FAT1 manifest to the handoff dir):
   ROLE=fat1 FAT1_ROOT=/applications/opc_d1 FAT2_ROOT=/applications/opc_d2 \
     FAT1_USER=opc_d1 FAT2_USER=opc_d2 MANIFEST_DIR=/tmp/fat2_audit_handoff \
     EXCLUDE_DIRS="_backup" bash bin/audit_env.sh
   # 2) as opc_d2 (ingests manifest, writes report):
   ROLE=fat2 FAT1_ROOT=/applications/opc_d1 FAT2_ROOT=/applications/opc_d2 \
     FAT1_USER=opc_d1 FAT2_USER=opc_d2 MANIFEST_DIR=/tmp/fat2_audit_handoff \
     REPORT_DIR=/tmp/fat2_audit EXCLUDE_DIRS="_backup" bash bin/audit_env.sh
   ```
   then returns `/tmp/fat2_audit/` (audit.txt + breakdown incl. the readability-GAP
   lists, a per-subsystem **scorecard**, and a heuristic **verdict**). This default
   run is `LEVEL=1` (fast snapshot — no hashing/content/cert). **Phase B:** re-run
   both passes with `LEVEL=2 SCOPE="<flagged subsystems>"` to drill into content +
   certs where the verdict points. The LEVEL-2 compare is **rewrite-aware**: FAT2
   is a string-rewritten copy, so it's judged against the *expected* `MIGRATION_MAP`
   rewrite of FAT1 (MIGRATED_OK / NOT_REWRITTEN / DRIFT; binaries IDENTICAL /
   CORRUPT), NOT against raw FAT1. **Deploy note:** the `opc_d1` pass needs
   `bin/audit_env.sh` + `bin/migration_map.sh` together; the `opc_d2` pass needs
   only `audit_env.sh`. Verified on two real users (bash 4.2.46):
   `tests/audit_two_user_test.sh` **49/49** (both levels + SCOPE + exclude-symmetry
   + permission GAP + rewrite verdicts) via the `bashutils7:audit` image.
2. **PHASE 1/2:** Claude turns the report into differential tables, cert dispositions, and a **repair-vs-rebuild recommendation backed by the counts**.
3. **PHASE 3:** present port-remap + path-remap + ownership model + per-cert disposition → get approval.
4. **PHASE 4:** execute one subsystem at a time (FAT2 writes only), validate after each. If "rebuild", the parked phased pipeline is the mechanism.

## Blockers

- **`/tmp/fat2_audit/` from the host** is the gating input for Phase 1/2.
- Q2 (FAT2 same hostname?) and Q3 (same Oracle DB?) — answered BY the audit + operator confirmation (the reason Phase 0 runs first).

## Key Decisions

- **Single branch (`main`)** — operator preference; work directly on `main` going forward, no feature branches.
- **Phase 0 ≠ selective_copy.** Phase 0 is read-only Discovery via `audit_env.sh`. The migration pipeline is the suspect + parked rebuild tool, untouched until approved.
- **Let the data choose repair-in-place vs. clean rebuild** (≥~90% correct → repair; systemic → rebuild from FAT1 with broken FAT2 kept aside). Quality of diffs outranks the %: any **CORRUPT binary** or inconsistent **DRIFT** pushes to rebuild (per-subsystem; hybrid is fine). Decision rubric in `docs/FAT2_REPAIR_ENGAGEMENT.md`.
- **Cert/keystore/wallet REUSE-FIRST (operator-approved):** reuse FAT1 security material in FAT2 if it works (TLS handshake / client hostname / Oracle connect); regenerate only on functional failure. Read FAT1, write FAT2; unreadable FAT1 certs go via the GAP/`/tmp` route. (Full policy + conditions: engagement doc Phase 2.)
- **Indirect shell** — Claude produces scripts; operator runs on host, returns output.
- **Military-precision testing** — every change verified in centos:7/bash-4.2.46 with exactness + failure injection (saved to memory).
- **No `Co-Authored-By: Claude`** on commits; author Abhijit Bandyopadhyay.

## Test Environment

- `centos:7` = bash 4.2.46 + GNU coreutils + OpenSSL 1.0.2k (target runtime). `bashutils7:rsync` adds rsync (CentOS vault) for selective_copy/phased tests. macOS CANNOT run the suite (BSD + bash 5.x masks bash-4.2 bugs). `tests/docker/rehearse.sh` builds a two-user login-able host.

## Resume Hints

- `/project:resume`, then read `docs/FAT2_REPAIR_ENGAGEMENT.md` + `.claude/TASKS.md`.
- Re-verify quickly: `docker run --rm -v "$PWD":/work -w /work bashutils7:rsync bash tests/phased_copy_test.sh`
- The single next action is the Phase 0 audit run above — everything else is gated on its output.
