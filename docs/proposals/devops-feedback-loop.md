# Proposal: close the loop from development to bug trace

Status: proposal, 2026-10-12. Nothing here is accepted until the owner picks it up.

## Why

One month into the 0.2.0 work, most elapsed time goes into waiting on and rerunning gates, finding crashes by hand, and rediscovering the same classes of bug. The loop is open at three points: failures are not classified, crashes leave no usable trace, and a fixed bug does not always leave a test behind.

## What the data says (Forgejo, runs 200 to 304, 2026-10-12)

| Measure | Value |
|---|---|
| Runs | 102 (74 passed, 28 failed) |
| Failure rate | 27 percent |
| Passing run, median | 18.6 minutes (90th percentile 22) |
| Failing run, median | 10.1 minutes |
| Runner minutes spent on failed runs | about 259 of about 1,600 |
| Unit tier (`cargo test --lib --bins`) | about 27 seconds for 2,224 tests |

Failures fall into three kinds: real defects the gate was right to catch, infrastructure (image pull and fixture start timeouts, compiler crashes, a runner starting before it could reach Docker), and GUI timing under load (TEST-31). The unit tier is not the slow part; the Docker suites, the GUI scenarios and the queue are.

A pilot of `cargo-nextest` (0.9.148) on the unit tier measured 28 to 30 seconds against 26 to 27 for `cargo test`, so it is not a speed-up. Its value here is different: one process per test, per-test retries and timeouts, and sharding across executors. That could replace `scripts/run-isolated-tests.py` and `scripts/isolated-tests.json`, which are also a frequent merge-conflict file.

## The loop, stage by stage

### 1. Develop

Today: parallel agents on branches, a squash merge by the gate owner, a local worktree per lane, a local test bench with Postgres, LDAP and mock files.

Gaps: the same few files conflict on every merge (`CHANGELOG.md`, `scripts/isolated-tests.json`, `baselines/*`); workspace-wide edits collide with agents' branches.

Next: generate the changelog from per-PR fragments (one file per change) instead of editing one list; move isolated-test registration into the test crate attributes (or nextest groups) so a new test does not edit a shared JSON file.

### 2. Test

Layers: unit, real-driver Docker suites, GUI scenarios, distro-floor containers, installed package, manual checklist. Containers prove the code behaves; only the installed package on a real desktop proves a connection path works (see `docs/testing.md`).

Gaps: failures are read by hand; the same infrastructure signatures recur.

Next, in order:

1. **Classify failures automatically.** A small script reads the failed job log and tags it: `infra` (known signatures: `PullImage ... RequestTimeoutError`, `fixture did not become ready`, `Compiler killed by signal`, `StartupTimeout`), `gui-timing`, or `code`. Post the tag on the run. Cost: small.
2. **Retry known infrastructure signatures once at the job level** in the workflow, so a human does not rerun. Cost: small.
3. **Adopt `nextest` for process isolation and retries**, not for speed. Cost: medium.
4. **Property tests for the security-critical parsers** (`proptest`). A first set for SQL classification ran 400,000 cases without a violation and takes under a second at the default size.
5. **Snapshot tests (`insta`)** for exports and the Explain tree.

### 3. Release

Today: an Arch package built locally from a pinned commit; deb and Flatpak recipes; release evidence in the ledger.

Gaps: no release candidate is built and installed by CI; installed acceptance depends on one desktop.

Next: on a candidate tag, CI builds the Arch and deb packages, attaches checksums, and runs the installed GUI suite inside a clean container per distro (already the distro-floor shape). Keep the desktop pass (PKG-1) as the human gate it is.

### 4. Observe

Today: panic messages are withheld on purpose (the log names the file and line only). A crash is diagnosed from a core dump by hand, as with the 2026-10-12 aborts.

Gaps: a real crash on a user's machine leaves too little to act on, and there is no reproducible environment record.

Next: a local-only crash note. On a panic or abort handler, write a small file under the user's state directory with the version, the GTK and libadwaita versions, the panic location (file and line, already considered safe), and the last lines of the log; never SQL, values or paths to data. Add `bookie --diagnostics` and an **About > Copy diagnostics** button that print the same environment block for an issue. Nothing is sent anywhere; the user attaches it. This keeps the privacy stance of the existing panic hook.

### 5. Bug trace

Today: installed-test findings become GitHub issues with a good template (environment, steps, expected, actual, traced cause); fixes reference them; the ledger records evidence.

Gaps: a fix does not always ship with a test that fails without it; the introducing change is not recorded.

Next:

- Rule in the pull request template: a bug fix names the test that fails without it (unit, property or GUI scenario).
- An **introduced in** field on crash and data-loss issues, filled from `git blame`, so recurring classes show up (for example the `AdwTabView` close handshake or `RefCell` re-borrow).
- A weekly review of the open crash issues, the failure classes from step 2, and the ledger rows that need a human.

## Order of work

1. Failure classifier and job-level retry (days).
2. Crash note and `--diagnostics` (days).
3. Pull request template and issue fields (hours).
4. `nextest` isolation and retries, changelog fragments (a week).
5. Release-candidate CI build (a week).

## What this does not change

The gate rules (Forgejo and GitHub both green on the same head), the policy and audit seam, and the privacy stance stay as they are.
