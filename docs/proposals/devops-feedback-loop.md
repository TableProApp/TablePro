# Proposal: close the loop from development to bug trace

Status: proposal, 2026-10-12. Nothing here is accepted until the owner picks it up. See [Done since the proposal](#done-since-the-proposal) for what has shipped.

## Why

One month into the 0.2.0 work, most elapsed time goes into waiting on and rerunning gates, finding crashes by hand, and rediscovering the same classes of bug. The loop is open at three points: failures are not classified, crashes leave no usable trace, and a fixed bug does not always leave a test behind.

## What the validation data showed (runs 200 to 304, 2026-10-12)

| Measure | Value |
|---|---|
| Runs | 102 (74 passed, 28 failed) |
| Failure rate | 27 percent |
| Passing run, median | 18.6 minutes (90th percentile 22) |
| Failing run, median | 10.1 minutes |
| Time spent on failed runs | about 259 of about 1,600 minutes |
| Unit tier (`cargo test --lib --bins`) | about 27 seconds for 2,224 tests |

Failures fall into three kinds: real defects the gate was right to catch, infrastructure (image pull and fixture start timeouts, compiler crashes, a runner starting before it could reach Docker), and GUI timing under load (TEST-31). The unit tier is not the slow part; the Docker suites, the GUI scenarios and the queue are.

A pilot of `cargo-nextest` (0.9.148) on the unit tier measured 28 to 30 seconds against 26 to 27 for `cargo test`, so it is not a speed-up. Its value here is different: one process per test, per-test retries and timeouts, and sharding across executors. That could replace `scripts/run-isolated-tests.py` and `scripts/isolated-tests.json`, which are also a frequent merge-conflict file.

## Done since the proposal

Updated 2026-10-14.

- Failure classifier: `scripts/classify-ci-failure.py` (#678). It tags a failed job `infra`, `gui-timing`, `gui`, `code` or `unknown`; a job log with no result line (a runner or Forgejo connection lost) is also `infra`.
- Gate queue: `scripts/forgejo-train.sh` gates several branches as one combined check (#718), but does not replace required per-pull-request head gates ([validation playbook](../validation-playbook.md#hosted-checks)). `.gitattributes` merges `CHANGELOG.md` and the PostgreSQL `connection_paths.rs` registry by union. The gate script retries its API calls and push after a Forgejo outage interrupted two gates on 2026-10-13.
- Still open from stage 1: `scripts/isolated-tests.json` cannot merge by union, and on 2026-10-13 two registrations merged into one list entry without a comma and broke Preflight for every pull request until it was repaired. That is the strongest case for moving registration into test attributes or nextest groups. Branch protection that requires a branch to be up to date would also have caught it.
- Coverage is split by test tier. The unit report does not cover driver integration paths; the nightly workflow now measures Docker suites for PostgreSQL, MySQL, SQLite, MongoDB, Redis and ClickHouse against per-crate floors. Use those reports for driver coverage rather than inferring gaps from the unit report.

## The loop, stage by stage

### 1. Develop

Today: parallel contributors use separate branches and worktrees, with isolated database and protocol fixtures for integration work.

Gaps: the same few files conflict on every merge (`CHANGELOG.md`, `scripts/isolated-tests.json`, `baselines/*`); workspace-wide edits collide with agents' branches.

Next: generate the changelog from per-PR fragments (one file per change) instead of editing one list; move isolated-test registration into the test crate attributes (or nextest groups) so a new test does not edit a shared JSON file.

### 2. Test

Layers: unit, real-driver Docker suites, GUI scenarios, distro-floor containers, installed package, manual checklist. Containers prove the code behaves; connection-path acceptance uses the installed package in the target native desktop session (see [testing](../testing.md)).

Gaps: failures are read by hand; the same infrastructure signatures recur.

Next, in order:

1. **Classify failures automatically.** A small script reads the failed job log and tags it: `infra` (known signatures: `PullImage ... RequestTimeoutError`, `fixture did not become ready`, `Compiler killed by signal`, `StartupTimeout`), `gui-timing`, or `code`. Post the tag on the run. Cost: small.
2. **Retry known infrastructure signatures once at the job level** in the workflow, so a human does not rerun. Cost: small.
3. **Adopt `nextest` for process isolation and retries**, not for speed. Cost: medium.
4. **Property tests for the security-critical parsers** (`proptest`). A first set for SQL classification ran 400,000 cases without a violation and takes under a second at the default size.
5. **Snapshot tests (`insta`)** for exports and the Explain tree.

### 3. Release

Today: an Arch package built locally from a pinned commit; deb and Flatpak recipes; release evidence in the ledger.

Gaps: no release candidate is built and installed by CI; installed acceptance needs a supported native desktop session, on the host or in a VM, as described by the current [validation playbook](../validation-playbook.md#release-decision).

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

## Environments and data: cheap clones instead of rebuilding databases

Contributed from the 2026-10 PostgreSQL talk and the Postgres.FM episodes on Xata and RegreSQL. The idea: seed a database once, then give every test its own copy-on-write clone in seconds.

What the tools are (checked 2026-10-12):

| Tool | What it does | Licence | Activity |
|---|---|---|---|
| [DBLab Engine](https://github.com/postgres-ai/database-lab-engine) | Thin clones and branches of a PostgreSQL database on ZFS or LVM, for testing in CI | Apache-2.0 | pushed 2026-10-08 |
| [RegreSQL](https://github.com/boringSQL/regresql) | SQL regression tests with expected results and EXPLAIN plan baselines | BSD-2-Clause | pushed 2026-10-04 |
| Xata | Open-source PostgreSQL branching | see episode | see episode |

All three focus on PostgreSQL, BookiE's most mature engine. They do not address the other drivers.

Where they would pay off for BookiE, in order of value for effort:

1. **Reuse pinned fixture images with seeded schemas.** Repeated pulls and fixture startup are common sources of delay. Prepare immutable engine fixtures with their schema and seed data ready, then measure their effect on startup time and reproducibility before adopting them across test layers.
2. **Seed once, create isolated copies for experiments.** Where the storage platform supports safe copy-on-write snapshots, an immutable seeded PostgreSQL template can provide a fresh database per experiment. Verify isolation, reset behavior and cleanup before relying on it in shared validation.
3. **RegreSQL on the SQL we generate.** BookiE builds SQL itself: browse paging, keyed updates, catalog and foreign key queries. Baseline their EXPLAIN plans against a seeded database so a change that turns an index scan into a sequential scan fails a test. The open many-schema catalog performance work ([#580](https://github.com/cozyGarage/BookiE/issues/580)) needs exactly this.
4. **DBLab itself**, only when we need large realistic datasets and many parallel clones. It adds operational complexity and is not justified for the current fixture sizes.

## Remaining proposed work

The classifier and gate queue are shipped. Nothing else in this proposal is approved until it is selected through Project #3.

1. Retry known infrastructure failures once at the job level; keep code failures unchanged.
2. Prebaked fixture images and a lab registry to reduce repeated pulls and startup failures.
3. A local crash note and `--diagnostics` command.
4. Pull request template and issue fields that connect fixes to their regression tests.
5. `nextest` isolation and retries, plus changelog fragments.
6. Release-candidate CI builds for Arch and Debian packages.

## What this does not change

The workflow rules in [AGENTS.md](../../AGENTS.md) and the [validation playbook](../validation-playbook.md) continue to govern; this proposal does not change them. The policy and audit seam and the privacy stance also remain unchanged.
