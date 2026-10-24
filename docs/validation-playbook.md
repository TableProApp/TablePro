# Validation playbook

Use this page to select checks, hand off work, and review evidence. The executable catalog is [test-layers.json](../scripts/test-layers.json). [Testing](testing.md) describes fixtures; the [completion page](bookie-0.2-sprint.md) records 0.2.0, while the [backlog](backlog.md) and owning issues set subsequent order and acceptance. A green layer certifies only its named scope.

## Current desktop target

The [sprint](bookie-0.2-sprint.md) records the maintainer's 2026-10-18 completion decision; use the release page linked there for current publication status. The [backlog](backlog.md) orders subsequent work; each selected issue names its acceptance layers. Debian/GNOME installed-package expansion remains later work. GTK 4.24 in the layer catalog names the toolkit development-library floor of [ADR 0021](decisions/0021-toolkit-floor.md), not a required desktop shell. Keep existing automated Linux checks and record unavailable environments as pending.

## Start here

Run commands from the repository root with the toolchain required by the repository.

### Local pre-push gate

For a single broad release-style run, use:

```bash
bash scripts/ci-local.sh release
```

It runs the fast workspace checks, GTK widgets, Docker driver and socket fixtures, SSH, app-server tests, TLS, keyring, PostgreSQL release checks, installed GTK safety flows, the ClickHouse/MySQL/MongoDB GTK fixtures, DuckDB and dependency checks. It does not run the `values` or `b4-rollback` layers, distro-floor and package-upgrade checks, nightly mutation/coverage/soak, or opt-in Kerberos tests. Use the named-layer command below when those contract layers are needed; the two paths overlap and do not need to be run together for every change.

On a local machine with Docker and the required native libraries, run a broad local regression pass before pushing:

```bash
set -e
python3 scripts/run-test-layer.py full app-server values drivers b4-rollback tls \
  postgres-release ssh keyring security-policy supply-chain widgets ui \
  workflow-lint harness packaging-contracts change-contracts
bash scripts/test-pg-dump.sh
```

This covers the fast workspace gate, app-server and cross-driver value contracts, Docker driver/rollback/TLS/PostgreSQL/SSH fixtures, keyring and dependency policy checks, plus the PostgreSQL dump/restore fixture. The named layers run sequentially and save the source revision, worktree state, tracked-diff digest and logs under `target/quality/`; `test-pg-dump.sh` runs separately. This does not cover the distro-floor matrix, installed-package upgrade/rollback, nightly mutation or soak runs, or the opt-in Kerberos and specialized GTK database fixtures. Those remain separate acceptance checks. The [completion page](bookie-0.2-sprint.md) records 0.2.0 status; current work and acceptance criteria live on the owning boards. Dated release audits and validation history are source-pinned records, not current status.

Before opening a pull request, also run `bash scripts/preflight.sh` as required by `AGENTS.md`. It repeats unit and sandbox tests but adds the crate-boundary and comment-line checks that `ci-local.sh full` does not run.

Run `quick` for a short edit loop. Run the pre-push gate after changes that touch shared core/value paths or before handing a B3 slice to review. Keep the hosted workflow as the recorded platform/packaging check.

```bash
python3 scripts/run-test-layer.py --list
python3 scripts/run-test-layer.py harness
python3 scripts/run-test-layer.py quick
python3 scripts/run-test-layer.py change-contracts
python3 scripts/run-test-layer.py security-policy supply-chain
python3 scripts/run-test-layer.py drivers b4-rollback tls postgres-release
python3 scripts/run-test-layer.py widgets app-server keyring ui
python3 scripts/run-test-layer.py values
```

The fast Build Linux job runs `change-contracts` before the full GTK/unit layer. It compares the checked-out commit with the pull request base or prior push commit, runs mapped exact regression tests for changed value-path files, and retains a report and per-command logs under `target/quality/`. Locally, check uncommitted work against `HEAD`, or compare a branch with its base explicitly:

```bash
python3 scripts/run-change-contract-tests.py
python3 scripts/run-change-contract-tests.py --base origin/linux
```

Use the remote that tracks [`cozyGarage/BookiE`](https://github.com/cozyGarage/BookiE) for `--base` (often `origin` after cloning BookiE).

Changes under `crates/core/src/`, `crates/core/tests/`, `apps/linux/app/src/`, `crates/mcp/src/`, and database-driver `src/` paths select focused exact regressions where mapped, otherwise the changed package's unit or integration tests. Edit `scripts/change-test-map.json` when adding a focused value regression. Driver integration-test files stay in the Docker `drivers` layer, which executes those server fixtures. The runner fails if Cargo returns success without a passing test summary or if an expected exact test does not appear exactly once as passed, with a single summary, no ignored or measured tests, and matching counts. The named-test runners share `scripts/rust_test_evidence.py`; full workspace summaries allow ignored fixture tests because their owning layers execute them.

Choose the layers affected by the change; the examples are separate invocations, not a requirement to repeat overlapping unit suites. The runner executes selected layers sequentially. Independent steps and later layers still run after a failure; the overall result remains failed. Nothing retries automatically. Layers can compose existing tiers; each test keeps its original tier ownership.

Each invocation writes `target/quality/<UTC timestamp>-layers/report.json` and one log per step. It records the commit, dirty status, tracked-diff digest, untracked input paths and their content digest, exact arguments, elapsed time, exit code and status. The untracked digest uses sorted repository-relative Git paths and file bytes; regular files also contribute executable status, and symlinks contribute their link target. Git-ignored build outputs are excluded, and a clean tree skips this scan. A dirty-tree report is development evidence, not reproducible release-candidate evidence: commit the tested changes before handing them off. The runner does not archive untracked file contents. Inspect a live log with `tail -f` in another terminal; do not pipe the test command through a command that discards its exit status.

For the standalone security and workflow layers, match the hosted tool versions:

```bash
cargo install cargo-deny --locked --version 0.20.2
cargo install cargo-audit --locked --version 0.22.2
go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
```

Put Go's bin directory on PATH and install ShellCheck for `workflow-lint`. Advisory databases remain live even with pinned tools; a later advisory failure is new evidence, not a reason to freeze or suppress the database.

Missing tools, nonzero exits, timeouts, cancellations and absent required test summaries cannot produce a pass. Cargo layers require at least one executed test and no failed summaries. The Python harness requires one nonempty unittest summary and one plain `OK` outcome. Failed, skipped or additional suite summaries cannot be hidden by another success line, even when the command exits zero. Environment-specific ignored tests still belong to their dedicated fixture layers. Value and isolated-test runners enforce stricter per-test execution contracts. Process exit alone is used for non-test tools and scripts that enforce their own evidence contract; it is not a coverage claim. SIGKILL, power loss or a runner crash can leave `status: running`; treat that as incomplete, never passed. Review every step status, not just the final log line.

## Layers and boundaries

| Layer | What it verifies | Prerequisites / boundary |
| --- | --- | --- |
| `harness` | Failure handling, workflow wiring, test runner and function-size regressions | Python 3; no Cargo build |
| `workflow-lint` | Action schemas, expressions and embedded shell | actionlint v1.7.12 and ShellCheck |
| `packaging-contracts` | Candidate archive and Debian package validator behavior | Git, tar, `dpkg-deb`; no actual install or upgrade |
| `change-contracts` | Focused regressions or package tests selected from changed core, app, MCP and driver source paths | Rust 1.98; changed driver integration tests remain in the Docker `drivers` layer |
| `quick` | Guards, formatting, non-GTK Clippy, units and sandbox | Rust 1.98 and native libraries |
| `full` | Default workspace checks including app logic | GTK 4.24 development stack; no display automation or DuckDB |
| `sandbox` | Integration tests without external servers or a display | Local sockets/processes must be allowed |
| `drivers` | PostgreSQL, MySQL, MSSQL, ClickHouse, Redis, MongoDB, MCP BSON, policy sessions, PostgreSQL socket and SSH | Docker and OpenSSH; SQLite is in sandbox, DuckDB has its own Build job |
| `b4-rollback` | MySQL failed-batch rollback and PostgreSQL rollback-failure handling | Docker and native TLS build dependencies |
| `values` | Exact values across eight drivers, core, app and MCP | Docker, GTK build dependencies, optional DuckDB build; strict selected-test counts |
| `tls` | CA, hostname, encryption and plaintext refusal against real servers | Docker Compose and generated private fixture certificates |
| `ssh` | SSH agent authentication and OpenSSH sessions | Docker and OpenSSH client tools |
| `postgres-release` | Policy, TLS/SSH, lock, cancellation, rollback and reconnect | Docker Compose, keyring/D-Bus and generated materials |
| `security-policy` | Policy/MCP permissions, allowlists, bounds and audit behavior | Non-GTK dependencies; does not prove every server authorization mode |
| `supply-chain` | Advisory, license and dependency-source policy | `cargo-deny`, `cargo-audit`, network; repository exceptions remain explicit |
| `widgets` | Named GTK widget regressions in isolated processes | GTK 4.24, Xvfb and private D-Bus |
| `app-server` | App parser and grid-edit contracts against PostgreSQL, MySQL, MongoDB and SQL Server | GTK 4.24 build libraries and Docker; hosted GTK fast job |
| `keyring` | Registered Secret Service contracts | Private D-Bus, gnome-keyring and libsecret tools |
| `ui` | Real application actions and database postconditions via AT-SPI | GTK 4.24, Xvfb, PyAT-SPI; X11 automation, not Wayland acceptance |
| `mssql-kerberos` | SQL Server integrated authentication, SPN refusal and verified TLS against an isolated test domain | Docker Compose with privileged-container support; opt-in local fixture |
| `gtk-clickhouse` | Installed GTK Enum16 grid edit against ClickHouse | GTK 4.24, Docker, Xvfb, Secret Service and AT-SPI; local release layer |
| `gtk-mysql-approval` | Approval and dispatch behavior against MySQL | GTK 4.24, Docker, Xvfb, Secret Service and AT-SPI; local release layer |
| `gtk-mongodb` | Installed GTK MongoDB cursor visibility and grid edits | GTK 4.24, Docker, Xvfb, Secret Service and AT-SPI; local release layer |

Build/package, mutation, coverage and acceptance retain their existing entrypoints:

| Scope | Entry point | Completion evidence |
| --- | --- | --- |
| Optional DuckDB | Build Linux / `duckdb`; commands in [testing](testing.md#optional-features-and-ignored-tests) | Driver tests plus app feature build |
| Mutation | GitHub Linux test quality; Forgejo nightly; [local instructions](testing-quality-and-performance.md#mutation-testing) | Selected/generated count, caught/missed/timeout/unviable counts and outcomes JSON; Forgejo also checks missed mutants against package baselines |
| Coverage | Linux test quality; [local instructions](testing-quality-and-performance.md#coverage) | LCOV, exclusions and summary; this report has no threshold. Forgejo nightly separately enforces the unit-tier and per-crate floors. |
| Flatpak | Flatpak Linux (packaging only) | Pull requests build the default profile; push and `workflow_dispatch` also build development; not regression acceptance |
| Arch / Debian candidate | [Packaging guide](../apps/linux/packaging/README.md) and packaging scripts | Immutable SHA, package checksum, validator output |
| GTK soak | GTK Safety Soak | Five independent retry-free attempts per run at one resolved SHA. The 30-attempt/six-run threshold is in the [archived 0.2.0 handoff](archive/bookie-0.2-completion-handoff-2026-10-18.md), not a default for future releases; current follow-ups are TEST-31 ([#556](https://github.com/cozyGarage/BookiE/issues/556)) and PKG-1 ([#574](https://github.com/cozyGarage/BookiE/issues/574)). |
| Installed acceptance | [Manual feature checklist](manual-verification-0.2-features.md) and issue acceptance criteria | VM/desktop version, Wayland session, package checksum, steps, result and screenshots |

## Hosted checks

Check every required result against the exact commit under review. A skipped check is not a pass, and a green fast tier does not certify tests that only run in a separate acceptance tier. Accepted aggregate trains follow [ADR 0020](decisions/0020-aggregate-forgejo-trains.md) and the [train procedure](testing-ci.md#aggregate-train-acceptance): one gate on the exact aggregate PR head replaces constituent Forgejo gates only after manifest, freshness and merge-tree verification. A standalone `forgejo-train.sh` preflight is not aggregate acceptance. The current workflow files and [AGENTS.md](../AGENTS.md) define which checks run for each change and where acceptance happens. Forgejo's `ci.yml` merge tier and `nightly.yml` share the `bookie-lab` workflow concurrency group with cancellation disabled. This queues scheduled and manual runs across refs on a best-effort basis; it does not promise strict ordering, and workflow runs already created from older revisions are not retroactively serialized. The gate script's local lock remains an additional guard for manual callers.

The gate reports both the browser run number and the API run ID. They can differ. The train verifier's `--run` argument takes the API ID; task reporting uses the browser run number and the tested revision. Do not substitute one identifier for the other.

Treat static-analysis findings as evidence to review. Fix valid findings in a focused change. For a confirmed false positive or accepted exception, record a short reason in the tool; keep a reusable explanation here only when it helps other contributors.

### Live issue-state report

Run `python3 scripts/check-github-issue-status.py` when reconciling the open-work index with GitHub. It requires an authenticated `gh` CLI and makes an explicit network request. It reports closed or unverified issue entries but never edits the ledger or Project #3. This point-in-time report is separate from offline `check-known-issues.py` and does not run in preflight or CI. Authentication, network, timeout, or API-shape failures mean the live state is unavailable, not that an issue is closed.

Use isolated fixtures with synthetic data and credentials. Do not put credentials, customer data, personal file paths, internal host names or machine-specific instructions in source, test output or committed evidence. Keep untrusted change validation isolated from production data and personal sessions.

## Build reuse and safe parallel work

Reuse the existing build cache, lockfile and toolchain. Do not run `cargo clean` to fix a test failure. Feature, profile and compiler-flag changes can trigger rebuilds; run the narrow reproducer before wider layers.

Avoid concurrent builds or fixture runs that share mutable state. Use the repository's layer runner and fixture isolation rules. Do not stop or remove resources owned by another task.

## Agent task template

Copy this and fill in every field:

```text
Repository and branch: <name>; expected full SHA: <sha>
Goal: <one invariant or failure>; issue and lane: <issue id> / <lane>
Allowed edits: <paths>; other agent-owned paths: <paths>
Run layers: <catalog names>; narrow reproducer: <exact command>
Available test prerequisites: <relevant tools or fixtures>
Shared resource reservation: <owner/time or isolated setup>
Fix authorization: <test only / reproduce then fix>; push authorization: <yes/no>
Return: initial failure, cause, patch, tests before/after, report paths, SHA,
        skipped/blocked/not-run scopes, unresolved risks and hosted run URLs.
Do not weaken assertions, ignore survivors, retry into green, raise size baselines,
or count a missing fixture as passed. Preserve unrelated changes.
```

An agent must read `AGENTS.md`, inspect status and confirm the SHA before editing. If the environment is blocked, return the failing prerequisite and evidence; do not replace a real server test with a mock and claim equivalent coverage. All reports must distinguish local results, hosted results and installed acceptance.

## Turn every finding into a regression

1. Record origin: user report, upstream issue/commit, mutation, fuzz case or CI run.
2. State the invariant and smallest input; record engine/version and expected type as well as value. Preserve a minimized sanitized fixture, never customer data.
3. Add the lowest-tier reproducer and demonstrate failure before changing code.
4. Fix the cause; cover valid, invalid and exact-boundary neighbors. Test each affected consumer: decode, binding, formatting, grid editing, export and re-import.
5. Add real-server or UI evidence where pure tests cannot prove the behavior. Assert database state and returned values, not merely absence of an error.
6. Register ignored GTK/keyring tests in `isolated-tests.json`; regenerate the ignored-test ledger. New tiers need a catalog entry, local runner and hosted gate.
7. Run focused mutation checks with a nonzero selected count and independent expected values. Document each equivalent survivor with a concrete argument; leave unresolved survivors/timeouts open.
8. Update scenario evidence and the owning issue or board. Keep the test with the fix.

Use [value contracts](value-contracts.md) and the B3 board as the current case backlog. The [scenario survey](archive/b3-test-scenario-survey.md) records dated research patterns and source provenance. Current examples:

| Encountered scenario | Permanent regression home | Next edge to investigate |
| --- | --- | --- |
| Rounded wide integers/decimals | Shared value corpus, core XLSX, PostgreSQL numeric contracts | Consumer edits and remaining numeric representations |
| Time 24:00 became midnight | PostgreSQL temporal units and real-server contracts | Temporal arrays, infinities and intervals |
| BC/year 10000 SQL export failed | Core SQL literal unit and PostgreSQL date round-trip | Remaining driver-specific calendar limits and non-SQL consumer parity |
| Decoder and oracle shared the same bug | Array size literal and numeric variant assertions | Independent oracles for other driver decoders |
| Green CI omitted eight SSH tests | SSH runner, ignored-test inventory and workflow regression | Audit new ignored targets whenever added |
| Empty/failed mutation report looked complete | Mutation summary fixtures and workflow regression | Triage survivors and timeouts from the exact run report tracked under [TEST-2 / #559](https://github.com/cozyGarage/BookiE/issues/559); counts vary by source SHA, so do not carry an old total forward |
| Test process failed, hung or never ran | Layer-runner negative tests | Keep adding actual infrastructure failure modes |

Secure connection coverage is engine-specific. Track valid auth, rejected auth, wrong CA/hostname, no plaintext fallback, cancellation during connect/read/write, disconnect/reconnect, pool reuse, partial streams, malformed lengths, NULL/empty distinctions, Unicode/binary boundaries and authorization on every consumer. An unchecked scenario is a backlog item, not an implied capability or a pass.

## Release qualification

For a future candidate, B3 requires closed correctness findings and their regressions. B4–B6 also require the planned installed-package, Wayland, upgrade/rollback and candidate soak evidence. Docker supplies deterministic servers and Xvfb supplies automated GTK interaction. The 0.2.0 release is already published; these criteria do not reopen that milestone. Arch/Omarchy under native Wayland is the selected 0.2.0 desktop target. Debian/GNOME VM qualification remains post-release backlog work. Xvfb and widget passes cannot certify a native Wayland target. No workflow here automatically publishes a release or waives an acceptance gate.

## Static-analysis triage

Confirm framework-specific findings against the framework's documented behavior before changing source. Record a concise disposition for confirmed false positives and avoid adding source suppressions unless the analyzer cannot express the exception another way.

### GTK CSS node selectors

SonarCloud reports eight “Unknown type selector” findings on `apps/linux/data/resources/style.css:25-26` for `columnview`, `listview`, `row` and `cell`.

These are GTK CSS node names in the focus-ring selector. GTK documents `columnview`, `listview` and `row` as nodes in the `GtkColumnView` / `GtkListView` tree. GTK's `GtkColumnViewCellWidget` source sets its CSS node name to `cell`. The stylesheet targets those nodes to draw the grid-cell focus ring; converting them to classes would stop matching the widget tree.

Disposition: confirmed framework-specific false positives from the web CSS analyzer. Keep the GTK selectors unchanged. The SonarCloud findings still need their status updated in the project dashboard; no source suppression was added.

- [GTK ColumnView CSS nodes](https://docs.gtk.org/gtk4/class.ColumnView.html)
- [GTK ListView CSS nodes](https://docs.gtk.org/gtk4/class.ListView.html)
- [GTK ColumnView cell CSS name in GTK source](https://github.com/GNOME/gtk/blob/main/gtk/gtkcolumnviewcellwidget.c#L282-L299)

## CI tiers

CI is split into fast feedback and slower integration or acceptance checks. Read the workflow definitions and [AGENTS.md](../AGENTS.md) for current triggers, required gates and ownership. A pull request is ready only when its required checks pass at the current head SHA. Skipped, cancelled, timed-out or unavailable checks are not passes. Scheduled runs and local results can add evidence, but do not replace a required check on the reviewed commit.
