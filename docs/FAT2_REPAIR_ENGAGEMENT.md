# FAT2 Repair Engagement — Analysis, Approach & Plan

> **Durable record** of the engagement to replicate/repair the broken **FAT2** dev
> environment from the known-good **FAT1**, on one Linux host. The governing spec
> is the operator's **Operating Brief** (the operator holds it verbatim). This
> document reconciles that Brief with the current state of this `bash-utils` repo
> and records the analysis, phase plan, decisions, traps, and open questions.
>
> **Why this file exists:** so a fresh session — or the Claude on the Linux box —
> can `/project:resume` and pick up the *entire* engagement with full context, not
> just the code. Committed to `main` (single branch), so it travels via git.
>
> **Status at last update (2026-05-30):** at the **Phase 0 gate** — read-only audit
> tooling is built and on `main`; awaiting the operator to run it on the host and
> return the report. **No writes to FAT2 have occurred or are authorized yet.**

---

## 1. Mission

Make **FAT2** work by replicating/repairing it from **FAT1**, on a single Linux host
running two parallel dev environments of the same app under two OS users:

| Env | User | Root | Role |
|-----|------|------|------|
| **FAT1** | `opc_d1` | `/applications/opc_d1` | Known-good **source**. **READ-ONLY ALWAYS.** May be live/in-use. |
| **FAT2** | `opc_d2` | `/applications/opc_d2` *(confirm)* | Broken, partially-migrated copy. The thing to fix. |

`opc_d2` may share a group with `opc_d1` and read most of FAT1 (confirm; don't assume).
App stack: **Apache Tomcat**, **TLS/PKI + keystores**, **Oracle DB** connectivity
(TNS, Oracle Wallets, JDBC thin/OCI, mutual-TLS).

## 2. How FAT2 broke (failure model — informs what to look for)

FAT2 was produced by bespoke bash scripts that copied and rewrote FAT1 → FAT2.
**Those scripts are buggy and are the systemic root cause.** The damage is broad,
not a few isolated misses. Expect any combination of:

- Partially copied trees (files/dirs/symlinks never copied).
- Stale symlinks in FAT2 still pointing into `/applications/opc_d1`.
- Broken symlinks (target moved/absent).
- Files copied but **not rewritten** — still contain FAT1 paths/user/ports/hostnames.
- Files **partially rewritten** — half-applied `sed`, truncated writes, greedy or
  too-narrow substitutions → files that *exist* and look done but are broken.
- Certs/keystores/wallets that are FAT1-specific, missing, expired, or **pinned**.
- Ownership/permission breakage — files still `opc_d1`-owned; secrets `opc_d2`
  can't read; dirs `opc_d2` can't write.

> **A half-migrated file is more dangerous than a missing one — it gives false
> confidence. Verify content, not just existence.**

## 3. Reconciliation: the Brief ↔ THIS repo  *(the load-bearing context)*

This is the piece that is easy to lose. **This `bash-utils` repo *is* the family of
"bespoke utility scripts" the Brief names as the buggy root cause.**

| Operating Brief element | This repo (current state) |
|---|---|
| "bespoke bash utility scripts that copied/rewrote FAT1→FAT2 … buggy … the root cause" (Brief Q8 asks to locate them) | **= this repo**: `selective_copy.sh`, `migrator.sh`, `finder.sh`, `validate.sh`. They are **SUSPECT EVIDENCE**, not a tool to re-run blindly. |
| What we did this session | **Audited + hardened** the toolkit — fixed bugs A–F, rewrote `selective_copy` as a **phased/batched** copy under the ~1 GB `/tmp` cap, added exhaustive bash-4.2.46 container tests. This makes the **rebuild option trustworthy *if chosen*; it does NOT license re-running them now.** |
| Phase 0 Discovery + Phase 1 differential + Phase 2 cert deep-dive (all read-only) | **= `bin/audit_env.sh`** (on `main`). Read-only on both trees; three-way symlink classification; missing/extra/unrewritten/ownership diffs; Tomcat ports; Oracle config; cert/keystore inventory (OpenSSL 1.0.2-compatible). Masks secrets, captures permission-denied, refuses a `REPORT_DIR` under either tree. |
| Phase 4 rebuild **mechanism** (only if chosen) | The hardened **`selective_copy` (phased) → `migrator` → `validate`** pipeline — **PARKED** until Phase 3 decides. |
| Brief Q7 (shell access) | **INDIRECT** — Claude runs on macOS, not the host. Produces scripts; the operator runs them and returns stdout/stderr. |
| Brief Q8 (location of the scripts) | **Answered: this repo.** Audited + hardened this session; treated as the suspect cause, not re-run blindly. |

**Bottom line:** the migration pipeline is simultaneously *the suspect* and *(now
hardened) the potential rebuild tool*. We do **not** touch it until the read-only
audit data and an **approved Phase 3 plan** justify it.

## 4. Prime directives (non-negotiable)

1. **Never write/modify/move/delete/restart anything under `/applications/opc_d1` or
   owned by `opc_d1`.** Before any write, `readlink -f` the target and assert it is
   under the FAT2 root and not a symlink resolving into FAT1.
2. **Nothing destructive without explicit human approval in chat.** No `rm -rf`, no
   truncation, no overwrite of an existing FAT2 file without `cp -a file file.bak.$(date +%Y%m%d_%H%M%S)`.
3. **Preserve the broken FAT2 as reference.** Snapshot before any rebuild
   (`tar -czf /tmp/fat2_broken_$(date +%F).tgz -C /applications opc_d2` or rename to
   `opc_d2.broken`). Never delete it during the engagement.
4. **Never run `sed`/text edits on binaries** — `.jks .p12 .pfx .keystore .truststore
   .jar .war cwallet.sso ewallet.p12 .so`, images. Path-fix plain-text config only.
5. **Never print/log/write secrets to world-readable places.** Mask. `set +o history`
   around password commands; prefer files/prompts over args (args show in `ps`).
6. **Phases with approval gates.** Discovery → diff/decision → plan → execute (one
   subsystem at a time) → validate. No fixes before the audit justifies them.
7. **Every script idempotent, re-runnable, non-destructive on re-run.** Back up
   before edit; check before change; log every action to a timestamped file.
8. **Confirm direct vs. indirect shell.** (Established: **indirect** — produce
   scripts + run instructions, ask for output back.)

## 5. Method — let the data choose repair-in-place vs. clean rebuild

Do **not** pre-commit. The systemic, pipeline-caused damage *suggests* a clean
deterministic rebuild from FAT1 (broken FAT2 kept aside for mining) usually beats
file-by-file archaeology — fix the pipeline once and re-running converges, vs.
whack-a-mole. **But** if the differential audit shows FAT2 is ≥~90% correct with only
stale symlinks + missing certs, **repair-in-place wins.** Decide from the numbers;
present the recommendation before executing.

We are now well-positioned for *either* branch: the audit tool exists (to decide),
and the rebuild pipeline is hardened + tested (to execute a rebuild trustworthily).

## 6. Phase plan

### Phase 0 — Discovery (READ-ONLY)  ← **current gate**
Run `bin/audit_env.sh` in **two passes, one per login** — because `opc_d2`
cannot read all of FAT1 (some files are `0600`/owned-by-`opc_d1`; some dirs are
untraversable), and a single `opc_d2` run would SILENTLY lose whole FAT1
subtrees from the differential. Each login is authoritative for its OWN tree;
`opc_d1` writes a manifest of FAT1's ground truth to a shared `/tmp` handoff, and
`opc_d2` ingests it to compute the differential, symlink-shared classification,
and binary checksum compare **without needing to read restricted FAT1 files** —
and additionally measures the **readability GAP** (the exact FAT1 paths `opc_d2`
cannot reach, which a rebuild must stage through `/tmp` via `opc_d1`).

`EXCLUDE_DIRS` prunes backup/irrelevant subtrees (e.g. `_backup`) symmetrically
from both trees so their stale configs/certs don't poison the decision counts.

**Two dials:** `ROLE` (which login) × `LEVEL` (how deep). The decision may take
several phases, so snapshot high-level first and drill down only where it matters:

- **`LEVEL=1` (default) — SNAPSHOT.** Fast, no hashing/content-grep/cert-decode.
  Per-subsystem file+byte **scorecard** (FAT1 vs FAT2), path differential counts,
  symlink classification, ownership breakage, readability GAP, and a heuristic
  **divergence VERDICT** that names the drifting subsystems to drill into.
- **`LEVEL=2` — DRILL-DOWN.** Adds unrewritten-token grep, binary checksum
  compare, cert decode, Tomcat/Oracle config. `SCOPE="sub1 sub2"` limits the
  expensive content work to named top-level subsystems (the structural diff stays
  whole-tree). Pass the SAME `LEVEL`/`SCOPE` to BOTH passes.

**Phase A — snapshot** (adjust `EXCLUDE_DIRS` to the real backup dir names):
```
# 1) as opc_d1 — writes the FAT1 manifest to the shared handoff dir:
ROLE=fat1 FAT1_ROOT=/applications/opc_d1 FAT2_ROOT=/applications/opc_d2 \
  FAT1_USER=opc_d1 FAT2_USER=opc_d2 MANIFEST_DIR=/tmp/fat2_audit_handoff \
  EXCLUDE_DIRS="_backup" bash bin/audit_env.sh
# 2) then as opc_d2 — ingests the manifest, writes the snapshot report:
ROLE=fat2 FAT1_ROOT=/applications/opc_d1 FAT2_ROOT=/applications/opc_d2 \
  FAT1_USER=opc_d1 FAT2_USER=opc_d2 MANIFEST_DIR=/tmp/fat2_audit_handoff \
  REPORT_DIR=/tmp/fat2_audit EXCLUDE_DIRS="_backup" bash bin/audit_env.sh
```
**Phase B — drill down the subsystems the verdict flagged** (add `LEVEL=2 SCOPE=…`
to BOTH passes, e.g.):
```
ROLE=fat1 LEVEL=2 SCOPE="security conf" ... EXCLUDE_DIRS="_backup" bash bin/audit_env.sh
ROLE=fat2 LEVEL=2 SCOPE="security conf" ... REPORT_DIR=/tmp/fat2_audit_L2 \
  EXCLUDE_DIRS="_backup" bash bin/audit_env.sh
```
It maps both trees: layout, symlinks, Java/Tomcat/`server.xml`/`setenv.sh`,
listening ports, env/shell-init, Oracle TNS/wallet/sqlnet, certs/keystores/
truststores, cron/systemd; captures permission-denied (signal). The fat2 pass
writes ONLY to its `REPORT_DIR`; the fat1 pass ONLY to `MANIFEST_DIR`. Operator
returns the report folder(s). Verified end-to-end on two real unix users on
bash 4.2.46 via `tests/audit_two_user_test.sh` (43/43: both levels + SCOPE +
exclude-symmetry + the permission GAP).

> Single-login fallback (`ROLE=both`, the default ROLE) is for mock/CI/rehearsal
> where one user can read both trees; it runs the manifest pass then the audit
> pass in one process. NOT for the host, where the two-login split is the point.

### Phase 1 — Differential audit (READ-ONLY) — produced from the audit data
- present in FAT1, **missing in FAT2** (not copied)
- in FAT2 but not FAT1 (extra/stale/FAT2-unique)
- FAT2 symlinks **into FAT1** and **broken** symlinks
- FAT2 plain-text files **still containing `opc_d1` / `/applications/opc_d1`** (and
  FAT1 hostname if it has a `d1`-style suffix) — incomplete rewrite
- files in both that **differ** (many *should* — is the difference *correct*?)
- FAT1 files `opc_d2` **cannot read** (shared-read feasibility)
- FAT2 entries **not owned by `opc_d2`** (ownership breakage)

### Phase 2 — Cert/keystore/wallet deep-dive (READ-ONLY)
For every PEM/CRT/CER, JKS/P12/keystore/truststore, Oracle wallet: subject, issuer,
SAN, **validity (flag expired)**, serial, SHA-256, alias list, entry type. Grep
configs for `fingerprint|thumbprint|pin|trustStore|keyStore|alias|WALLET_LOCATION|
SSL_SERVER_DN_MATCH`. Determine each cert's **role** → reuse / repath / regenerate.
**Phase 2b:** keystore alias/validity that needs the **store password** — supplied
securely (file/prompt, never CLI arg); deferred until needed.

### Phase 3 — Plan (→ approval)
Port-remap table, path-remap table, permission/ownership model, per-cert
disposition, and the **repair-vs-rebuild recommendation backed by the counts**.

### Phase 4 — Execute one subsystem at a time, validate after each
directory skeleton + ownership → env/shell files → Tomcat config (paths + ports) →
Oracle config (TNS/wallet/sqlnet/JDBC) → certs/keystores → start → smoke test.
Idempotent, logged, backup-before-edit scripts. (If "rebuild": the parked phased
`selective_copy` → `migrator` → `validate` pipeline is the mechanism.)

## 7. Blocking questions — status

| # | Question | Status |
|---|----------|--------|
| 1 | FAT2 root path + `opc_d2` username | **Settled:** `/applications/opc_d2`, `opc_d2` (confirm at run) |
| 2 | FAT2 same hostname as FAT1 (diff port) or **different** hostname/URL? (server-cert reuse) | **Open — the audit answers it** (surfaces hostnames/SAN); operator confirms the FAT2 URL |
| 3 | FAT1 & FAT2 → **same** Oracle DB/schema or **different**? (TNS/creds/wallet strategy) | **Open — the audit answers it** (surfaces `tnsnames`/connect strings); operator confirms intent |
| 4 | Architecture: fully independent vs. thin (shared read-only binaries) | **Mostly independent**, with **some symlinks (both envs) pointing to the same location**; audit's symlink classification refines this |
| 5 | Keystore/wallet passwords known? how supplied? | **Later/secure** — file or prompt, never CLI arg; not needed for read-only Phase 0–2 (Phase 2b) |
| 6 | FAT1 live/in active use? | **Assume yes** → read-only always |
| 7 | Direct vs. indirect shell | **Settled: indirect** (operator runs scripts, returns output) |
| 8 | Location of the migration scripts | **Settled: this repo** — audited + hardened; treated as suspect, not re-run blindly |

## 8. Trap catalogue (apply during analysis + repair)

1. **Port collisions (#1 failure):** every FAT2 listening port must differ from FAT1 —
   HTTP/HTTPS/**AJP**/**shutdown port `<Server port=>`**, JMX+RMI, JPDA/JDWP debug,
   app listeners. Cross-check against live `ss -tlnp`. Keep an explicit FAT1→FAT2
   port map applied consistently.
2. **Hardcoded paths + FAT1 username:** rewrite `opc_d1`/`/applications/opc_d1` →
   `opc_d2`/… in `server.xml`, `setenv.sh`, `catalina.properties`, `context.xml`,
   `logging.properties`, log4j/logback (log output paths!), `.bash_profile`/`.bashrc`,
   `tnsnames.ora`, `sqlnet.ora`, JDBC URLs, keystore/truststore paths, app
   `*.properties`/`*.yml`. Beware `opc_d10`/comment substring hits — anchored,
   reviewed subs; **diff every change.**
3. **Symlinks — 3 modes:** (a) stale absolute into FAT1; (b) broken; (c) resolves to
   FAT1's **writable runtime** (logs/work/temp) → FAT2 corrupts FAT1. Relative vs.
   absolute matters.
4. **Certs/TLS — role decides reuse:** server TLS keys on **hostname+chain** (same
   host+hostname, diff port = fine); **client/mTLS identity** reuse means FAT2
   authenticates *as FAT1* (flag!); truststores env-agnostic; Oracle wallets host- +
   permission-bound (`WALLET_LOCATION` must point at FAT2); rule out **expiry** &
   **pinning** before regenerating; never echo keystore passwords; key file perms
   `0600`/`0640`.
5. **Permissions/ownership/ACLs:** `opc_d1`-owned files block FAT2 writes (work/temp/
   logs/upload must be `opc_d2`-writable); `0600`-owned-by-`opc_d1` secrets unreadable
   even in same group → need `0640`+shared group or a `opc_d2`-owned copy; check
   `getfacl` + setuid/setgid.
6. **Oracle:** `TNS_ADMIN` → FAT2 config dir; `tnsnames.ora` same-vs-different DB
   (major branch); `sqlnet.ora` `WALLET_LOCATION`/`SSL_SERVER_DN_MATCH`; JDBC thin
   (wallet props) vs OCI (`ORACLE_HOME`/`LD_LIBRARY_PATH`); verify with `tnsping` +
   minimal connect before declaring success.
7. **Runtime/process collisions:** `CATALINA_PID`, `hsperfdata`, fixed `/tmp` locks,
   JMX/RMI ports; review `-Xmx`/`-Xms` for the JVM pair; `CATALINA_HOME` vs `BASE`;
   never kill FAT1's processes — remap.
8. **Env/shell init:** FAT1-specific `JAVA_HOME`/`ORACLE_HOME`/`TNS_ADMIN`/
   `CATALINA_*`/`PATH`/`LD_LIBRARY_PATH`; differing `umask`; source order.
9. **Scheduled/startup:** `crontab -l -u opc_d2` referencing FAT1; systemd (root;
   maybe absent for dev); legacy init scripts.
10. **Buggy-script damage signatures:** truncated/half-written files; greedy subs;
    missed occurrences; **binaries corrupted by text-mode `sed`** (checksum vs FAT1 —
    equal hash on env-agnostic binary = good; differing hash on a "shouldn't change"
    binary = corruption suspect); encoding/BOM/line-ending changes. When unsure on a
    binary, re-copy from FAT1.

## 9. Toolkit inventory (all on `main` — single branch)

| Script | Role in this engagement |
|--------|--------------------------|
| `bin/audit_env.sh` | **Phase 0/1/2 read-only audit.** The tool that runs first. |
| `bin/selective_copy.sh` | **Phased/batched cross-user copy** (FAT1→/tmp→FAT2 under the ~1 GB cap). The rebuild mechanism — **parked** until Phase 3. |
| `bin/migrator.sh` | In-place `fat1→fat2` path/content rewrite with backup/resume/rollback + free-space preflight. Rebuild step 2. |
| `bin/validate.sh` | Post-migration consistency checker. Rebuild validation. |
| `bin/finder.sh` | Discover fat1 references in a tree (feeds the migrator CSV). |
| `bin/fix_dir_mtimes.sh` | Repair directory mtimes bumped by renames. |
| `bin/mock_build.sh` | Build a sandbox mock from a CSV (rehearsal). |
| `tests/` + `tests/docker/rehearse.sh` | Container test suite (bash 4.2.46) + a login-able two-user rehearsal host to dry-run the real cross-user flow off the live box. |
| Library modules | `common.sh`, `migration_map.sh`, `tracking.sh`, `backup.sh`. |

> Note: `selective_copy`/`migrator` etc. are the **suspect** scripts the Brief warns
> about. They are now hardened + tested, but only become the **rebuild mechanism**
> if Phase 3 chooses rebuild — never re-run blindly.

## 10. Deliverables & acceptance criteria (from the Brief)

**Deliverables:** read-only Phase 0/1/2 audit report with differential tables + cert
dispositions + repair-vs-rebuild recommendation (backed by counts); port-remap +
path-remap tables; idempotent/logged/backup-first scripts per phase; a validation
suite (port-up, `curl`/`openssl s_client` HTTP+HTTPS, `tnsping` + minimal JDBC, post-
run log scan for stack traces / bind errors / SSL handshake failures).

**Acceptance:** FAT2 starts cleanly under `opc_d2`; no port collisions with FAT1 or
any process; no FAT2 file/symlink references `opc_d1`/`/applications/opc_d1`; TLS
endpoints present valid (unexpired, hostname-matching) certs; Oracle connectivity
succeeds as the intended identity; FAT2 writes only within its own tree; **FAT1
remains byte-for-byte untouched.**

## 11. Immediate next action

**Phase 0, read-only — TWO passes (one per login).** Operator deploys the repo on
the host and runs, first as `opc_d1` then as `opc_d2`:
```
# 1) as opc_d1:
ROLE=fat1 FAT1_ROOT=/applications/opc_d1 FAT2_ROOT=/applications/opc_d2 \
  FAT1_USER=opc_d1 FAT2_USER=opc_d2 MANIFEST_DIR=/tmp/fat2_audit_handoff \
  EXCLUDE_DIRS="_backup" bash bin/audit_env.sh
# 2) as opc_d2:
ROLE=fat2 FAT1_ROOT=/applications/opc_d1 FAT2_ROOT=/applications/opc_d2 \
  FAT1_USER=opc_d1 FAT2_USER=opc_d2 MANIFEST_DIR=/tmp/fat2_audit_handoff \
  REPORT_DIR=/tmp/fat2_audit EXCLUDE_DIRS="_backup" bash bin/audit_env.sh
```
then returns `/tmp/fat2_audit/` (and `/tmp/fat2_audit_handoff/`). Only one file
needs deploying: `bin/audit_env.sh` (self-contained, sources nothing). Claude
produces the Phase 1/2 differential tables, cert dispositions, and the
repair-vs-rebuild recommendation. **No FAT2 writes until a Phase 3 plan is
approved.**
