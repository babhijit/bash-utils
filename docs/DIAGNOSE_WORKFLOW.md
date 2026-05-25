# Diagnose-migrator-bug Remote Workflow

> **STATUS: HISTORICAL.** The specific bug this document was built to diagnose
> ("Source path not found" from `setup_migrator_test.sh`) was fixed in the
> 2026-05-25 refactor:
>
> - The unchecked `cp -a` in the prepare phase was wrapped in error handling.
> - The `[ -d ]` test that misclassified symlinks-to-directories now has the
>   `[ ! -L ]` guard.
> - The harness itself was rewritten as a thin orchestrator that delegates to
>   `mock_build.sh` (which has per-copy `verify_lstat_match` against the source).
> - `bin/run_all_tests.sh` runs the full pipeline against a synthetic tree on
>   any Linux box, so this kind of regression is now catchable without a
>   remote operator.
>
> The runbook below is preserved as a template for **future** remote-diagnose
> situations where the driver has no shell on the affected host. The phrasing,
> the driver/operator split, the report-return mechanics, and the hypothesis
> decision tree are reusable; only the specific bug, paths, and probe defaults
> would need replacing.
>
> Current diagnostic of choice if anything in the pipeline misbehaves:
> `bash bin/run_all_tests.sh` locally, then `setup_migrator_test.sh --mode all`
> on the remote host with the real CSV. Both produce clear pass/fail output
> that's much easier to triage than the original ad-hoc WARNs.

---

A step-by-step runbook for diagnosing the "Source path not found" bug in
`setup_migrator_test.sh` when you (the driver) **do not have direct access** to
the system where the bug reproduces, and must coordinate with an **operator** on
the remote host.

This document has two voices:

- **DRIVER** = you, on your local machine, with no shell on the remote box.
- **OPERATOR** = the person with shell access on the remote box. May be a
  human teammate, a sysadmin, or yourself via a ticketing/jump-host workflow.

Every section labels whose work it is.

---

## 0. What we're diagnosing (driver: read once, then move on)

`setup_migrator_test.sh --mode prepare` reads a real CSV of paths, copies each
listed file into a mock environment under `/tmp/test_f2/migration_test/` (the
harness's `TEST_ROOT`), and writes a `test_input.csv` recording the mock paths.
The harness logs every copy as `INFO ... Copying real item: <src> -> <dst>`.

**Two-level layout on the remote host:**

- `/tmp/test_f2/` — the **operator's working directory**. The scripts
  (`migrator.sh`, `setup_migrator_test.sh`, `diagnose_migrator_bug.sh`) and the
  input CSV (`fat2.csv`) live here. Created and maintained by the operator;
  never touched by the harness.
- `/tmp/test_f2/migration_test/` — the **harness's test environment**
  (`TEST_ROOT` in `setup_migrator_test.sh:22`). Created, populated, and
  destroyed by the harness. This is the only path you should ever wipe.

Do **not** confuse the two. `rm -rf /tmp/test_f2` would delete the scripts
along with the test environment; the right cleanup is
`rm -rf /tmp/test_f2/migration_test`.

The bug: when `setup_migrator_test.sh --mode execute` runs next, `migrator.sh`
WARNs `SKIP: Source path not found: <mock_path>` for paths the prepare log
claims were copied successfully. Something between "prepare logged the copy"
and "execute read the path" diverges.

The diagnostic ([bin/diagnose_migrator_bug.sh](../bin/diagnose_migrator_bug.sh))
gathers read-only evidence in 8 sections and pins the failure on one of three
hypotheses:

- **A** — `cp -a` returned 0 but the file isn't on disk.
- **B** — destination path was truncated to its parent directory.
- **C** — a file in the input CSV was misclassified as a directory and `mkdir`'d
  instead of `cp`'d.

The diagnostic does NOT modify any state. It is safe to run repeatedly.

---

## 1. Preconditions check (driver)

Before involving the operator, confirm with them (one short message) that all
of the following are true on the remote host. If any is false, the workflow
either changes or aborts.

```text
[ ] OS is Linux (any distro with GNU coreutils).
    Not macOS/BSD: the scripts use `stat -c %y` and `touch -d "@epoch"`.
[ ] Bash 4.2 or higher.  (Operator runs: bash --version)
[ ] An `fat2.csv` (or equivalent input CSV) is present on the host, OR you
    can provide one to the operator. This is the real CSV that triggers the
    bug — NOT a test fixture.
[ ] Operator has write access to /tmp (the mock env, the diagnostic report,
    and migrator's backup directory all land in /tmp).
[ ] Operator can return a ~50-500KB text file back to you. Common channels:
    scp/sftp, attached to email, pasted into a ticket, or base64-encoded
    blob in chat. Pick one up front.
```

If the operator says "I don't have an `fat2.csv` here, what do I run against?",
the workflow stops — the bug needs the real input to reproduce. Generate one
with `finder.sh` (see [CLAUDE.md](../CLAUDE.md)) and ship it over before
proceeding.

---

## 2. What to send to the operator (driver)

The operator needs four scripts and (optionally) the input CSV. Decide your
transfer mechanism (scp, git clone, paste-into-files, attach-to-email) and
send these:

```text
bin/migrator.sh
bin/setup_migrator_test.sh
bin/diagnose_migrator_bug.sh
bin/finder.sh                   # only needed if operator must generate the CSV
fat2.csv                        # only if operator doesn't already have it
```

`selective_copy.sh` and the other `setup_*_test.sh` files are NOT involved.

**Tell the operator where to place them.** The convention on this host is
`/tmp/test_f2/` (the parent of the harness's `TEST_ROOT`):

```text
/tmp/test_f2/                              ← operator's working dir; scripts live here
├── migrator.sh
├── setup_migrator_test.sh
├── diagnose_migrator_bug.sh
├── finder.sh                              # optional
├── fat2.csv
└── migration_test/                        ← created by the harness; do not pre-create
    ├── environment_to_migrate/
    ├── test_input.csv
    ├── setup_migration.log
    └── migration_progress.log
```

Everything above `migration_test/` is operator-owned and persists across runs.
Everything inside `migration_test/` is harness-owned and gets rebuilt every
`--mode prepare`. The diagnostic defaults (`--input-csv ./fat2.csv`,
`--test-root /tmp/test_f2/migration_test`) line up with this layout, so running
from `/tmp/test_f2/` makes the commands below copy-pasteable verbatim.

---

## 3. Operator runbook (send this to the operator)

> Copy the block below into the message you send the operator. They should be
> able to run it end-to-end without further explanation.

---

### Step 1 — Make scripts executable and verify

```bash
cd /tmp/test_f2                       # scripts and fat2.csv live here
chmod +x migrator.sh setup_migrator_test.sh diagnose_migrator_bug.sh

# Confirm bash version (must be 4.2 or higher)
bash --version | head -1

# Confirm the input CSV looks right (should print header + a few rows)
head -3 fat2.csv
```

If `bash --version` shows anything below 4.2, STOP and report back — the
scripts have a hard version check at startup and will exit immediately.

### Step 2 — Run prepare to build the mock environment

This step replicates the real items listed in `fat2.csv` into a sandbox under
`/tmp/test_f2/migration_test/`. It does NOT touch any of the real source
paths — it only reads them.

```bash
# Clean slate (in case a previous run left artifacts). ONLY the harness's
# TEST_ROOT — never /tmp/test_f2, that's where the scripts live.
rm -rf /tmp/test_f2/migration_test

bash setup_migrator_test.sh --mode prepare --csv fat2.csv 2>&1 | tee prepare.out
```

Expected ending: `PREPARE complete. Replicated <N> real items.`

If you see `WARN` lines saying `Source item not found on filesystem`, that's
normal — those are paths in `fat2.csv` that no longer exist on this host. Note
the count but keep going.

### Step 3 — Run execute and capture the WARNs

This is where the bug shows up. We're capturing migrator's WARN output, NOT
trying to fix the migration.

```bash
bash setup_migrator_test.sh --mode execute 2>&1 | tee execute.out
```

Look for lines like:

```text
WARN - SKIP: Source path not found: /tmp/test_f2/migration_test/environment_to_migrate/...
```

Count them:

```bash
grep -c "SKIP: Source path not found" execute.out
```

If that count is ZERO, the bug did not reproduce this run — STOP and report
back. We may need a different input CSV or a different probe substring.

### Step 4 — Pick a probe substring

The diagnostic centers on one substring that appears in failing paths. Look at
the first few "Source path not found" lines:

```bash
grep "SKIP: Source path not found" execute.out | head -5
```

Pick a substring that appears in those failing paths and is **distinctive
enough** to not match unrelated files. Good probes: a unique directory name, a
component like `mq-opcsvcf1`, an unusual filename token. Bad probes: `log`,
`bin`, `etc` (too generic).

If you're not sure, default to `mq-opcsvcf1` — the diagnostic's built-in
default — and the driver will pick another if needed.

### Step 5 — Run the diagnostic

**Do NOT run `setup_migrator_test.sh --mode cleanup` before this step** — the
diagnostic needs the mock environment intact.

```bash
bash diagnose_migrator_bug.sh \
    --input-csv fat2.csv \
    --test-root /tmp/test_f2/migration_test \
    --probe "mq-opcsvcf1"       # replace with the probe you picked in step 4
```

It prints progress to the console and writes a report file. The last line tells
you where:

```text
Full report saved to:  /tmp/migrator_diagnosis_<YYYYMMDD_HHMMSS>.txt
```

### Step 6 — Return the report to the driver

Send back **all three** files:

1. `/tmp/migrator_diagnosis_<timestamp>.txt` (the main diagnostic)
2. `prepare.out` (from step 2)
3. `execute.out` (from step 3)

If the channel is text-only and the report is too large to paste, gzip and
base64-encode:

```bash
gzip -c /tmp/migrator_diagnosis_*.txt | base64 > diag.txt.gz.b64
gzip -c prepare.out | base64 > prepare.out.gz.b64
gzip -c execute.out | base64 > execute.out.gz.b64
```

Driver decodes with:

```bash
base64 -d diag.txt.gz.b64 | gunzip > diag.txt
```

### Step 7 — Do NOT clean up yet

Leave `/tmp/test_f2/migration_test/` in place until the driver confirms the
diagnosis is complete. Re-runs of the diagnostic with different `--probe`
values may be needed.

When the driver gives the all-clear (this wipes ONLY the harness's test
environment — the scripts and `fat2.csv` in `/tmp/test_f2/` are untouched):

```bash
rm -rf /tmp/test_f2/migration_test
rm -f  /tmp/migrator_diagnosis_*.txt
rm -f  /tmp/test_f2/prepare.out /tmp/test_f2/execute.out
rm -f  /tmp/test_f2/diag*.b64
```

---

## 4. What to look for in the report (driver)

Once the report is in your hands, read these sections **in this order**. They
are arranged to converge on the bug fastest.

### 4.1 Section 1 — Existence checks

Confirms the operator ran prepare correctly. All five paths should say `FOUND`.
If `TEST_CSV` or `SETUP_LOG` is missing, prepare didn't run; go back to step 2.

### 4.2 Section 3 — Test CSV rows matching probe

This is what setup *thinks* it produced. Confirm:

- The hex dump contains no stray `\r` (would show as `\r` between fields). If
  it does, the CSV was authored on Windows and the path-quote stripping in
  `setup_migrator_test.sh:160` (`absolute_path="${absolute_path%$'\r'}"`)
  isn't sufficient — but that's already in the code, so this is unlikely.
- The Absolute_Path column starts with `/tmp/test_f2/migration_test/environment_to_migrate/`.
- The match count is non-zero.

### 4.3 Section 4 — Input CSV rows matching probe

This is what setup *read*. Confirm:

- Field count distribution shows the expected number of columns. If you see
  multiple distinct counts (`3 ...`, `4 ...`, `5 ...`), some rows have embedded
  commas in paths — that breaks `IFS=, read` and is a real bug class, distinct
  from A/B/C.
- Hex dump has no surprises.

### 4.4 Section 6 — Setup log entries matching probe

This is the **ground truth of what prepare actually did**. For each probe row,
you'll see one of:

- `INFO - Creating mock directory: <path>` → setup classified the source as a
  directory.
- `INFO - Copying real item: <src> -> <dst>` → setup classified the source as
  a file (or symlink) and used `cp -a`.
- `WARN - Source item not found on filesystem` → the real source doesn't
  exist on this host. Not our bug.

The "summary by action" sub-table tells you the distribution at a glance.

### 4.5 Section 2 + Section 5 — What's actually on disk

Section 2 lists everything in the mock tree matching the probe. Section 5 walks
each test-CSV path individually and reports `[-e]/[-f]/[-d]/[-L]`.

Cross-reference with section 6.

### 4.6 Section 7 — Path cross-reference

For each probe path in the input CSV, the diagnostic computes the expected
mock path (`MOCK_ENV_DIR + input_path`) and checks if it appears verbatim in
`test_input.csv`. A `NO` here means the harness wrote a different path than
expected — usually a smoking gun for hypothesis B.

---

## 5. Decide which hypothesis fits (driver)

Apply this decision tree using the sections above:

```text
Does section 5 show DOES NOT EXIST for paths section 6 logged as
"Copying real item: ..."?
│
├── YES → Hypothesis A: cp -a is silently failing or being cleaned up.
│         Investigate:
│           - Is /tmp on tmpfs with size limits? Check `df -h /tmp` (ask op).
│           - Is there a tmpwatch/systemd-tmpfiles job sweeping /tmp?
│           - Are any of the source paths on a fuse mount that returns
│             success but doesn't copy contents?
│
└── NO  → Does section 5 show the parent directory exists but the file
          basename is missing from it, AND section 6's logged destination
          is shorter than the input CSV path (section 4)?
          │
          ├── YES → Hypothesis B: mkdir -p created the parent but the file
          │         landed elsewhere. Look at setup_migrator_test.sh's
          │         mock_env_path construction at lines 131-148.
          │         Most likely cause: a path containing a `:` or `\n` or
          │         something IFS-sensitive. Re-read section 4's hex dump.
          │
          └── NO  → Does section 5 show [-d]=y where you expected [-f]=y,
                    AND section 6 says "Creating mock directory" for a
                    basename that ends in `.ini`, `.pem`, `.conf`, etc.?
                    │
                    ├── YES → Hypothesis C: the input CSV's source path is a
                    │         symlink (or something else) that `[ -d ]`
                    │         returns true for. setup_migrator_test.sh:139
                    │         tests `if [ -d "$real_path_from_csv" ]` — but
                    │         `[ -d ]` follows symlinks. A symlink-to-directory
                    │         would be misclassified.
                    │         Fix: change to `[ -d "$real_path_from_csv" ] && [ ! -L "$real_path_from_csv" ]`.
                    │
                    └── NO  → None of A/B/C fit. Re-run the diagnostic with
                              a different probe — the substring you chose
                              may be matching paths that aren't actually
                              failing. Use a token from a confirmed-failing
                              path in `execute.out`.
```

---

## 6. Send the fix back to the operator (driver)

Once you know which hypothesis fits, the fix is in either
[setup_migrator_test.sh](../bin/setup_migrator_test.sh) or the operator's
environment. Either way, send the operator a self-contained instruction set.

**For an environment fix (hypothesis A — `/tmp` is being swept, etc.):**

> Please run:
>
> ```bash
> df -h /tmp
> mount | grep ' /tmp '
> systemctl list-timers | grep -i tmp
> ls -la /etc/tmpfiles.d/ 2>/dev/null
> ```
>
> and send back the output. I suspect `<reason>`.

**For a code fix (hypothesis B or C):**

> Apply this patch to `setup_migrator_test.sh` (line `<N>`):
>
> ```diff
> -    if [ -d "$real_path_from_csv" ]; then
> +    if [ -d "$real_path_from_csv" ] && [ ! -L "$real_path_from_csv" ]; then
> ```
>
> Then re-run the workflow from step 2 in section 3 of the runbook. The
> "Source path not found" WARN count should drop to zero (or to a small
> number that all correspond to genuinely missing source paths — confirm
> against the prepare log).

---

## 7. Closing out (driver + operator)

When the fix is confirmed:

1. **Operator** runs cleanup:

   ```bash
   rm -rf /tmp/test_f2/migration_test
   rm -f  /tmp/migrator_diagnosis_*.txt
   rm -f  /tmp/test_f2/prepare.out /tmp/test_f2/execute.out
   rm -f  /tmp/test_f2/diag*.b64
   ```

   If the operator is done with the scripts entirely and wants to remove
   the working dir too, that's a separate explicit `rm -rf /tmp/test_f2`
   — but only after confirming the diagnostic is complete.

2. **Driver** commits the patch (if code was changed) using the project's
   commit convention — no `Co-Authored-By: Claude` trailer (see
   [CLAUDE.md](../CLAUDE.md) author conventions).

3. **Driver** captures any environment-specific finding (e.g. "tmpfiles.d
   sweeps `/tmp/test_f2/migration_test/*` after 1 hour on this host") in a
   place future you will find it — a comment at the top of
   `setup_migrator_test.sh`, a note in `CLAUDE.md`, or an issue ticket.

---

## Appendix A — Quick reference (what file goes where)

| File                                                                | On driver | On operator | Notes                              |
|---------------------------------------------------------------------|:---------:|:-----------:|------------------------------------|
| [bin/migrator.sh](../bin/migrator.sh)                               |     X     |      X      | Sourced by setup harness           |
| [bin/setup_migrator_test.sh](../bin/setup_migrator_test.sh)         |     X     |      X      | The harness being diagnosed        |
| [bin/diagnose_migrator_bug.sh](../bin/diagnose_migrator_bug.sh)     |     X     |      X      | Read-only, safe to re-run          |
| [bin/finder.sh](../bin/finder.sh)                                   |     X     |  optional   | Only if generating a fresh CSV     |
| `fat2.csv` (input CSV)                                              |     X     |      X      | Must match across both sides       |
| `/tmp/migrator_diagnosis_*.txt`                                     |     X     |      X      | Generated; returned to driver      |
| `prepare.out`, `execute.out`                                        |     X     |      X      | Generated; returned to driver      |

## Appendix B — Common gotchas

- **Operator runs as a user who can't write `/tmp/test_f2/migration_test`.**
  `TEST_ROOT` is a `readonly` constant at [setup_migrator_test.sh:22](../bin/setup_migrator_test.sh#L22)
  with no CLI override. If the harness's `TEST_ROOT` is unwritable, the
  operator must either edit that constant or run as a user who can write to
  `/tmp/test_f2/`. Distinct from the operator's working dir `/tmp/test_f2/`
  itself, which the operator owns. The diagnostic's `--test-root` flag must
  point at whatever the harness actually used.
- **Symlinks in the source pointing at unreadable targets.** `cp -a` on a
  symlink to a path the operator can't read will succeed at copying the link
  itself but fail later when migrator tries to follow it. Section 5's `[-L]=y`
  with a missing `realpath` target is the signature.
- **Multiple input CSVs of the same name in different directories.** The
  diagnostic's `--input-csv` defaults to `./fat2.csv` in CWD. If the operator
  ran from a different directory than where they put the CSV, section 4 will
  be empty. Always pass `--input-csv` with an explicit path if there's any
  doubt.
- **The probe matched nothing.** Section 3 and section 4 will both show
  zero matching rows. Re-pick a probe from `execute.out`'s actual failing
  paths, not from memory.
