# Cross-host briefing: testing harness, mock environment, and the bugs they guard

**Audience:** a Claude (or human) picking this repo up on another host — e.g. the
Linux box where a local mock environment was already built from `fat2.csv`.

**The transfer is git.** Everything below is committed text in this repo. Pull
`main`, run `/project:resume` (reads `.claude/SESSION.md`), and you have it all.
No manual file copying / Google Drive needed.

---

## 1. The mock environment is now a script: `tests/setup_mock_env.sh`

It builds **one** mock SOURCE tree that is the `fat2.csv` dataset rendered in
**realistic, type-dispatched content** — Tomcat `server.xml`/`context.xml`
(with `< > & " /` and `&amp;` entities), java `.properties`, pkibot `.ini`,
openssl `.cnf`, certnanny `.cfg`, `setenv` shells, crontab `.snip`, and **binary
`.jks` keystores** — each carrying the migration tokens (`fat1/FAT1/opc_d1/
opcsvcf1/xbapp_d1`) where they really appear. It also injects the edge cases
(below) and emits a **combined CSV** that drives them all in one pipeline run.
Everything lives under `--root` (default `/tmp/mock_src`); it is marker-guarded
and never touches a real tree.

```bash
bash tests/setup_mock_env.sh --reset            # build /tmp/mock_src + combined CSV
bash tests/run_mock_env_test.sh                 # drive full pipeline + per-edge asserts
```

**Why realistic content matters:** dummy `config for X` lines barely exercise the
sed rewrite. Realistic XML/ini/cnf/shell (special chars, multi-line, binary)
genuinely test `replace_content_in_file` (sed escaping), `validate` (recomputed-
rewrite diff), and byte-exact rollback. **Bug F was found precisely because the
content was realistic** — a dummy fixture would have missed it.

## 2. Reconcile with a pre-existing local mock — don't just replace

If you already built a `fat2.csv`-based mock with **better real-layout fidelity**
(actual subtree shapes, real filenames, true symlink topology), keep that. Fold
this script's value into it rather than discarding either:

- Port your layout fidelity into `materialize_fat2` (or feed a richer CSV).
- Keep `inject_edges` (E1–E7) and `gen_content` (per-type realistic content) —
  that's the bug-catching surface.
- Goal: a mock that is **layout-faithful AND edge-laden AND realistic-content**.

## 3. The edge cases (E1–E7) — keep these covered

| | Edge case | What it guards |
|---|---|---|
| E1 | blank / whitespace-only CSV lines | parser must not abort the whole run |
| E2 | path containing spaces | quoting throughout |
| E3 | dir-rename row + a descendant row | descendant's name must still migrate |
| E4 | `fat1_X` and `fat2_X` coexist | rewrite fat2_X; leave fat1_X; rollback preserves it |
| E5 | symlink: fat1 name + dangling target | retarget + rename + mtime |
| E6 | rollback round-trip | content + mtime restored byte/second-exact |
| E7 | dir-mtime drift after a rename | `fix_dir_mtimes` repairs parent dirs |

## 4. Bugs already found and fixed (A–F) — do NOT reintroduce

| Bug | Where | Lesson |
|---|---|---|
| A | `setup_migrator_test.sh` | validate-rollback compared a doubled path → vacuous pass |
| B | `common.sh:csv_read_3col` | a blank CSV line aborted the run; skip empty-path rows |
| C | `migrator.sh:migrate_directory` | rename inner entries deepest-first, rollback-safe |
| D | `selective_copy.sh` | `"${arr[@]}"` on an empty array aborts on **bash 4.2/4.3** under `set -u`; use `"${arr[@]+"${arr[@]}"}"` |
| E | `selective_copy.sh` | normalize `dest_name`; copy dir CONTENTS into dest (no `bin/bin` nesting) |
| F | `migrator.sh:restore_from_backup` | rollback must NOT delete the coexisting `fat1_X` it left in place |

## 5. Test in the TARGET runtime, not just natively

The production host is **bash 4.2.46 (RHEL7) + GNU coreutils**. If your Linux box
runs bash 5.x, it will **mask** the bash-4.2-only failures (Bug D is invisible on
4.4+). Always validate in the target runtime:

```bash
docker run --rm -v "$PWD":/work -w /work centos:7 bash bin/run_all_tests.sh
docker run --rm -v "$PWD":/work -w /work centos:7 bash tests/run_mock_env_test.sh
docker run --rm -v "$PWD":/work -w /work centos:7 bash tests/edge_cases.sh
# selective_copy's two-user test needs rsync (absent from base centos:7):
docker build -t bashutils7:rsync - <<'DOCKERFILE'
FROM centos:7
RUN sed -i 's|^mirrorlist=|#mirrorlist=|g; s|^#\{0,1\}baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo \
 && yum -y install rsync && yum clean all
DOCKERFILE
docker run --rm -v "$PWD":/work -w /work bashutils7:rsync bash tests/selective_copy_test.sh
```

## 6. For the actual FAT2 repair: `bin/audit_env.sh`

Read-only Phase 0/1/2 differential audit of FAT1 vs FAT2 (layout, symlink
three-way classification incl. intentionally-shared targets, missing/extra/
unrewritten/ownership, Tomcat ports, Oracle config, cert/keystore inventory).
Run as `opc_d2`; it changes nothing and redacts secrets. See `RUNBOOK.txt` for
the full repair procedure and `CHEATSHEET.txt` for the concrete commands.
