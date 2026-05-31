# TASKS — bash-utils / FAT2 repair engagement

Working backlog. Companion to `.claude/SESSION.md` (current snapshot) and
`docs/FAT2_REPAIR_ENGAGEMENT.md` (full analysis/approach). Single branch: `main`.

Legend: [x] done · [ ] open · [~] in progress · [⏸] blocked/gated

---

## DONE — toolkit + tooling (all on `main`)

- [x] Architecture refactor — no tool sources another; `migration_map.sh` /
      `tracking.sh` / `backup.sh` library modules; dropped dead reverse map.
- [x] Bugs A–F fixed + verified on real bash 4.2.46 (validate-rollback doubled
      path; blank-line abort; dir+descendant rename; empty-array under `set -u`;
      rsync double-nest; rollback deleting coexisting `fat1_X`).
- [x] `selective_copy.sh` rewritten as **phased/batched** (plan → prepare/deploy
      loop → finalize → status/cleanup) under the ~1 GB `/tmp` cap: marker-file
      no-sync coordination, per-batch attribute-reference CSV (restore mode+mtime,
      not ownership), 0777 cross-user drain, free-space preflight, resume,
      dual logging (per-user `.log` + `events.<user>.jsonl`), live `--info=progress2`.
      Fixed the `IFS=$'\t'` tab-collapse + cross-user log permission bugs.
- [x] `migrator.sh` backup free-space preflight (sum CSV `du -sb` vs free space).
- [x] Tests green in centos:7/bash-4.2.46: `phased_copy_test.sh` 22/22,
      `selective_copy_test.sh` 14/14 (two real users), `migrator_preflight_test.sh`
      7/7, run_all / run_container / edge_cases / run_mock_env / fix_dir_mtimes.
- [x] `tests/docker/rehearse.sh` + `Dockerfile.rehearsal` — login-able two-user
      rehearsal host.
- [x] `bin/audit_env.sh` — read-only Phase 0/1/2 differential audit (RO both trees,
      masks secrets, captures permission-denied, REPORT_DIR refused under either tree).
- [x] Docs: CHEATSHEET / RUNBOOK (batched PHASE 0 + rehearsal section), CLAUDE.md,
      `docs/TESTING_AND_MOCK_ENV.md`, `docs/FAT2_REPAIR_ENGAGEMENT.md`.
- [x] Consolidated to a **single branch** (`main`); all feature branches merged + deleted.

---

## ENGAGEMENT — FAT2 repair (phased, approval-gated)

### Phase 0 — Discovery (READ-ONLY)  [~] current gate
- [~] Operator deploys `bin/audit_env.sh` and runs **TWO passes** (opc_d2 can't read
      all of FAT1, so each login owns its tree via a /tmp manifest handoff):
      1. as opc_d1: `ROLE=fat1 FAT1_ROOT=/applications/opc_d1 FAT2_ROOT=/applications/opc_d2 FAT1_USER=opc_d1 FAT2_USER=opc_d2 MANIFEST_DIR=/tmp/fat2_audit_handoff EXCLUDE_DIRS="_backup" bash bin/audit_env.sh`
      2. as opc_d2: `ROLE=fat2 ... MANIFEST_DIR=/tmp/fat2_audit_handoff REPORT_DIR=/tmp/fat2_audit EXCLUDE_DIRS="_backup" bash bin/audit_env.sh`
      (default run = `LEVEL=1` snapshot: scorecard + verdict + structural diff, no
      content. Phase B: re-run both with `LEVEL=2 SCOPE="<flagged>"` to drill down.
      LEVEL-2 is REWRITE-AWARE: FAT2 judged vs the expected MIGRATION_MAP rewrite of
      FAT1, NOT raw FAT1 → MIGRATED_OK / NOT_REWRITTEN / DRIFT; binaries IDENTICAL /
      CORRUPT. **opc_d1 pass needs audit_env.sh + migration_map.sh; opc_d2 pass needs
      only audit_env.sh.**)
- [ ] Operator returns `/tmp/fat2_audit/` (audit.txt + breakdown incl. GAP lists).
- [x] Two-user (opc_d1/opc_d2) handoff verified on bash 4.2.46: `tests/audit_two_user_test.sh`
      49/49 (both LEVELs + SCOPE drill-down; rewrite verdicts MIGRATED_OK/NOT_REWRITTEN/
      DRIFT + binary IDENTICAL/CORRUPT; manifest captures opc_d2-unreadable files;
      GAP set exact; EXCLUDE symmetric; LEVEL-1 skips content).
- [ ] (Optional safety-first) rehearse the toolkit on a Linux box / `tests/docker` first.

### Phase 1 — Differential audit (READ-ONLY)  [⏸ gated on Phase 0 output]
- [ ] Tables: missing-in-FAT2; extra-in-FAT2; symlinks-into-FAT1; broken symlinks;
      unrewritten `opc_d1` refs; differing-but-should-differ; FAT1-unreadable-by-opc_d2;
      FAT2-not-owned-by-opc_d2.
- [ ] Compute the repair-vs-rebuild signal (≥~90% correct → repair; systemic → rebuild).

### Phase 2 — Cert/keystore/wallet deep-dive (READ-ONLY)  [⏸ gated]
- [ ] Per cert: subject/issuer/SAN/validity(expired?)/serial/SHA-256/role.
- [ ] Grep configs for pinning/alias/trustStore/keyStore/WALLET_LOCATION/SSL_SERVER_DN_MATCH.
- [ ] Per-cert disposition: reuse-as-is / repath / regenerate.
- [ ] **Phase 2b** — keystore alias/validity needing the store **password**; supply
      securely (file/prompt, never CLI arg). Deferred until needed.

### Phase 3 — Plan (→ approval)  [⏸ gated]
- [ ] Port-remap table; path-remap table; permission/ownership model; per-cert
      disposition; **repair-vs-rebuild recommendation backed by counts**. Get approval.

### Phase 4 — Execute one subsystem at a time, validate after each  [⏸ gated]
- [ ] Snapshot broken FAT2 first (directive 3).
- [ ] dir skeleton + ownership → env/shell → Tomcat (paths+ports) → Oracle
      (TNS/wallet/sqlnet/JDBC) → certs/keystores → start → smoke test.
- [ ] If "rebuild": use the parked phased `selective_copy` → `migrator` → `validate`.
- [ ] Validation suite: port-up, `curl`/`openssl s_client` (HTTP+HTTPS), `tnsping` +
      minimal JDBC, post-run log scan (stack traces / bind errors / SSL handshake).

---

## OPEN QUESTIONS (status)

- [x] Q1 FAT2 path/user → `/applications/opc_d2`, `opc_d2` (confirm at run).
- [ ] Q2 FAT2 same hostname as FAT1 or different? → **audit answers + operator confirms.**
- [ ] Q3 Same Oracle DB/schema or different? → **audit answers + operator confirms.**
- [x] Q4 Architecture → mostly independent, some shared symlinks; audit refines.
- [ ] Q5 Keystore/wallet passwords → supply securely later (Phase 2b).
- [x] Q6 FAT1 live → assume yes; read-only always.
- [x] Q7 Shell access → indirect.
- [x] Q8 Migration scripts location → this repo; suspect; not re-run blindly.

## ACCEPTANCE CRITERIA (definition of done)

FAT2 starts cleanly under `opc_d2`; no port collisions; no FAT2 file/symlink
references `opc_d1`/`/applications/opc_d1`; TLS endpoints valid (unexpired,
hostname-matching); Oracle connects as the intended identity; FAT2 writes only in
its own tree; FAT1 byte-for-byte untouched.

## TOOLKIT FOLLOW-UPS (non-blocking)

- [ ] Legacy `setup_finder_test.sh` / `setup_linux_test.sh` predate the lib refactor —
      replace or delete on a future pass.
- [ ] `diagnose_migrator_bug.sh` / `docs/DIAGNOSE_WORKFLOW.md` — retain as forensic
      template; not part of the active flow.
