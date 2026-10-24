# Proposal: close the loop from development to bug trace

Status: dated proposal, created 2026-10-12 and updated 2026-10-23. The shipped/open/next notes below are a snapshot, not live status; the [backlog](../backlog.md) and owning issues control current priority and acceptance. Nothing here changes workflow rules unless adopted through the project process.

## Why

One month into the 0.2.0 work, most elapsed time goes into waiting on and rerunning gates, finding crashes by hand, and rediscovering the same classes of bug. The loop is open at three points: failures are not classified, crashes leave no usable trace, and a fixed bug does not always leave a test behind.

## What validation reviews showed

The unit tier is a small part of the full feedback loop. Most delay comes from
database fixture startup, installed GUI scenarios and serialized acceptance
runs. Failures need to be separated into product defects, test-environment
failures and GUI timing under contention. These are durable observations, not
current performance measurements; use fresh, source-pinned evidence when
changing timeouts, sharding or runner capacity.

The unit and sandbox tiers now use pinned `cargo-nextest`. The pilot did not show a raw speed improvement; its value is process isolation and clear per-test outcomes. Driver, release, GTK and keyring tiers still use Cargo's test runner or the isolated-test runner while their fixture and registration models remain separate ([#892](https://github.com/cozyGarage/BookiE/issues/892)).

## Done since the proposal

Updated 2026-10-17.

- Failure classifier: `scripts/classify-ci-failure.py` (#678). It tags a failed job `infra`, `gui-timing`, `gui`, `code` or `unknown`; a job log with no result line (a runner or Forgejo connection lost) is also `infra`.
- Gate queue: `scripts/forgejo-train.sh` gates several branches as one combined check (#718), while accepted aggregate PRs replace constituent gates only through [ADR 0020](../decisions/0020-aggregate-forgejo-trains.md) and its immutable input checks. `.gitattributes` merges `CHANGELOG.md` and the PostgreSQL `connection_paths.rs` registry by union. The gate script retries transient API and push failures.
- Still open from stage 1: `scripts/isolated-tests.json` cannot merge by union, so concurrent test-registration changes can break the preflight harness. Moving registration into test attributes or nextest groups would remove that shared-file conflict. Branch protection that requires a branch to be up to date would also catch stale branches.
- Nextest: the unit and sandbox tiers use the pinned runner with retries disabled; broader adoption remains open until the other tiers' fixtures and registrations support it.
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
3. **Extend `nextest` beyond unit and sandbox tiers** once the remaining fixtures support process isolation. Keep retries disabled unless evidence justifies them. Cost: medium.
4. **Property tests for the security-critical parsers** (`proptest`). A first set for SQL classification ran 400,000 cases without a violation and takes under a second at the default size.
5. **Snapshot tests (`insta`)** for exports and the Explain tree.

### 3. Release

Today: the tag release workflow builds the Arch, Debian, Flatpak and AppImage artifacts, generates `SHA256SUMS` and creates a draft release. A maintainer publishes it after review.

Gap: the release workflow does not install the built packages or run installed GUI acceptance. That still needs a supported native desktop session, on the host or in a VM, as described by the current [validation playbook](../validation-playbook.md#release-qualification).

Next: retain the tag workflow for artifact builds and add clean-install verification only when selected through the backlog. A containerized GTK check is not a substitute for the native desktop pass (PKG-1).

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

## Reusable database fixtures

Repeated image downloads, schema setup and data seeding add cost and failure points to integration tests. Reusable fixture layers can include pinned engine images, deterministic schema/data seeds, and copy-on-write database clones where the storage platform supports them. These patterns are options to measure, not selected dependencies or current workflow requirements.

Potential value for BookiE, in order of effort:

1. **Reuse pinned fixture images with seeded schemas.** Repeated pulls and fixture startup are common sources of delay. Prepare immutable engine fixtures with their schema and seed data ready, then measure their effect on startup time and reproducibility before adopting them across test layers.
2. **Seed once, create isolated copies for experiments.** Where the storage platform supports safe copy-on-write snapshots, an immutable seeded PostgreSQL template can provide a fresh database per experiment. Verify isolation, reset behavior and cleanup before relying on it in shared validation.
3. **Plan regression checks for generated SQL.** BookiE builds browse paging, keyed updates, catalog and foreign-key queries. Baseline EXPLAIN plans against a seeded database so material query-plan regressions are visible. The many-schema catalog performance work ([#580](https://github.com/cozyGarage/BookiE/issues/580)) is a candidate workload.
4. **Database cloning infrastructure**, only when large realistic datasets and parallel isolated runs justify its operational cost. Current fixture sizes do not establish that need.

## Remaining proposed work

The classifier and gate queue are shipped. Nothing else in this proposal is approved until it is selected through Project #3.

1. Retry known infrastructure failures once at the job level; keep code failures unchanged.
2. Prebaked fixture images and a lab registry to reduce repeated pulls and startup failures.
3. A local crash note and `--diagnostics` command.
4. Pull request template and issue fields that connect fixes to their regression tests.
5. Extend `nextest` beyond unit and sandbox tiers, move isolated-test registration out of the shared JSON file, and add changelog fragments.
6. Clean install and installed-GUI verification for candidate packages; artifact builds, checksums and draft creation already run in the tag workflow.

## What this does not change

The workflow rules in [AGENTS.md](../../AGENTS.md) and the [validation playbook](../validation-playbook.md) continue to govern; this proposal does not change them. The policy and audit seam and the privacy stance also remain unchanged.
