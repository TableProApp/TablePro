# Agent and contributor rules

These rules apply to every coding agent and every contributor. `CLAUDE.md` points here; tool-specific files must not restate or contradict this page.

## Project

**BookiE** is a Linux-only native database client (formerly TablePro on this branch). The product repository is [`cozyGarage/BookiE`](https://github.com/cozyGarage/BookiE). Work happens on the `linux` branch in the Rust 1.98 Cargo workspace at the repository root (`crates/`, `apps/linux/`, `tests/`, `scripts/`, `docs/`).

- The rename covers the display name, packaging install names (`bookie`, `bookie-agentd`, with `tablepro*` aliases) and branding assets only. Cargo package and binary names stay `tablepro-app` / `tablepro-agentd`. App ID, config and data paths, keyring schema, UUIDs, audit format and protocol contracts stay `tablepro` / `com.tablepro.linux`. Crate names stay `tablepro-*`. Check the sprint before renaming any of them.
- The UI uses GTK4, libadwaita, GtkSourceView and Relm4. Database drivers are static workspace crates registered at compile time. No cross-platform UI layers, web views or source for another operating system.
- Every shipped feature works without an account, license key, subscription, paid tier or remote entitlement check.
- The root [LICENSE](LICENSE) applies. User-facing changes go in [CHANGELOG.md](CHANGELOG.md).

## Where to start

1. [docs/README.md](docs/README.md): the documentation map and where each fact belongs.
2. [The active sprint](docs/bookie-0.2-sprint.md): milestone order, 0.2.0 readiness and acceptance. The [0.2.0 scope](docs/0.2.0-scope.md) lists the blockers; everything else is in the [backlog](docs/backlog.md), and [known limitations](docs/known-limitations.md) says what the application cannot do. 0.2.0 ships as a development release for the Arch and Hyprland target, with hotfixes to follow.
3. [Bookie Project #3](https://github.com/users/cozyGarage/projects/3): open work, status and lane. The [ledger index](docs/known-issues.md) maps ledger IDs to issues. Filter the project by **Lane** (B3, B4, UX, Maintainer).
4. The ADR that governs your change ([index](docs/decisions/README.md)). Every type or value change follows [ADR 0007](docs/decisions/0007-type-and-value-preservation.md).

Accepted ADRs constrain architecture. The sprint owns sequencing and acceptance; ROADMAP and PLAN only point to it. Dated reviews and archives prove their recorded source only; they do not override current decisions.

## Product context and specs

[PRODUCT.md](PRODUCT.md) says what BookiE is and is not, [docs/personas.md](docs/personas.md) says who it serves, and [PRINCIPLES.md](PRINCIPLES.md) holds the standing principles. [specs/](specs/README.md) describe current behaviour extracted from the code. They are drafts until reviewed: this file and accepted ADRs rank above them, and when a spec and the code disagree, check the code and fix the spec.

## Lanes and ownership

Lanes keep parallel agents from editing the same files. Pick open work from [Project #3](https://github.com/users/cozyGarage/projects/3) filtered by your **Lane**. Each open issue has one lane; edit only that lane's files unless a handoff comment on the issue records otherwise.

| Lane | Owns |
| --- | --- |
| B3 | Types, values, drivers and result paths: `crates/core` value and result types, decoders under `crates/drivers/`, grid value display, the [B3 board pointer](docs/type-contract-strategy.md) |
| B4 | Transport, guard, audit, SSH, rollback and acceptance: `crates/policy`, `crates/transport`, `crates/ssh`, audit storage, the [B4 board pointer](docs/b4-task-board.md) |
| UX | App layer (`apps/linux/`), packaging, CI and the lab, the ledger index, and shared documentation. UX also runs the Forgejo gate for every pull request that is green on GitHub and merges it once both agree |
| Cursor | Documentation and tests only. UX reviews its test pull requests; the maintainer merges its documentation pull requests, which need no Forgejo run |
| Maintainer | Decisions and anything needing a person or a real desktop |

- To work in another lane's files, first record the handoff on the GitHub issue (and update the project **Lane** / `lane:*` label plus the [ledger index](docs/known-issues.md) Lane column) in the same commit as the first change.
- When a lane finishes a row, close or move the issue on the project and remove its line from the ledger index.
- Each agent works in its own git worktree (a sibling directory named for the lane, for example `bookie-b3`), never in another agent's checkout. Branch from the latest `linux` on [`cozyGarage/BookiE`](https://github.com/cozyGarage/BookiE). Name branches `<lane>/<topic>` or `<type>/<topic>`.

## Workflow

1. Write the failing test first, then the fix, in one commit.
2. Run the checks in [Validation](#validation) locally. Run scripts unpiped: `bash scripts/preflight.sh | tail -3` reports `tail`'s status, not the script's.
3. Merge the latest BookiE `linux` branch from GitHub `cozyGarage/BookiE` into the branch (do not rebase a shared branch). Resolve generated files such as `Cargo.lock` by regenerating them.
4. **Gate on Forgejo:** `bash scripts/forgejo-gate.sh <branch> [remote-branch]`. It pushes to the lab Forgejo, waits for that push's run and lists jobs that did not pass. Forgejo is the acceptance gate: it runs the merge tier (Docker drivers, installed GTK, distro floor, packages) on every branch push. GitHub no longer runs the merge tier on pushes to `linux` or `main`: drivers, installed GTK, driver TLS, the PostgreSQL release fixture and DuckDB run on Forgejo only, so a green GitHub pull request only means the cheap tier ran.
5. Open the GitHub pull request against `linux`, merge it when the Forgejo gate is green (squash, subject `<type>(<scope>): <summary> (#N)`), then sync Forgejo's `linux` to GitHub's. The UX lane gates and merges every pull request that is green on GitHub, using `--match-head-commit`. A push that only merges `linux` into a branch, does not need a new gate: compare the pull request's own diff against BookiE `linux` for the gated head and the current head (`git diff <bookie-remote>/linux...<head> -- crates scripts`, where `<bookie-remote>` is the remote that tracks `cozyGarage/BookiE`), and merge when it is unchanged. Re-gate when the pull request's own code or tests changed. Say in the report that the comparison was made.
6. **Documentation-only changes skip CI.** A change that touches only `*.md` files and `docs/` is pushed straight to `linux` after `python3 scripts/check-doc-links.py`, `check-known-issues.py` and `inventory-ignored-tests.py --check` pass. The heavy GitHub workflows ignore such pushes; the cheap `linux-ci-contracts` harness still checks them on GitHub. `forgejo-gate.sh` runs the same checks and exits without queueing a run. Do not use a Forgejo `paths-ignore` filter: Forgejo reads the changed files of a merge commit as none, so every branch that merged `linux` would silently get no run. Do not push a documentation-only tip to Forgejo's `linux`; the next code merge carries it. A change that touches any other file takes the full path above.
7. **One gate at a time.** The gate script holds a host lock, so queued gates wait for each other. Overlapping runs starve the installed GTK jobs of CPU and produce accessibility-timeout failures that mean nothing. A GTK or driver failure seen while another run was active is inconclusive until it is re-run alone. Never start a second gate by hand to "speed up". The daily full run (22:00 UTC) and the nightly workflow (23:00 UTC) run on `linux` at night; a queued sync of Forgejo's `linux` waits on the same lock and holds it until its run finishes. Runners carry the label `debian-host` (native GTK, widgets and release fixtures stay there) and `any-host` (all four executors, used by the guard, Clippy, unit, sandbox, supply-chain, driver and distro-floor jobs). A single failed job can be re-run from the Forgejo run page without a new push.
8. **Do not repeat work between GitHub and Forgejo.** GitHub runs the cheap tier, security, Flatpak and the workflow and harness contracts on pull requests, plus at most a weekly scheduled backup run. A push to `linux` does not start the merge tier there. Forgejo runs the merge tier on its own executors. Do not re-run a Forgejo job to learn what GitHub already reported, and do not trust a skipped GitHub job as a pass. CodeQL and SonarCloud run on GitHub as reference scans, not gates: fix real findings in small pull requests and mark wrong ones "False positive" or "Won't fix" with a reason (see validation-playbook, SonarCloud triage).
9. **Merge only on GitHub.** Forgejo is the gate, not the merge target: never merge a pull request on Forgejo, and never push to Forgejo's `linux` by hand. A Forgejo merge makes its `linux` diverge from GitHub's, and the sync (which only fast-forwards) then stops until someone resets it.
10. Never leave a background job, container or lab VM change running that you did not start, and never stop one you did not start. On shared executors, stop only your own containers by name.

## Principles

1. Security comes first. Validate input at system boundaries and deny unsafe operations by default.
2. Fix root causes. Reproduce or trace a defect before changing code.
3. Keep dependencies one-directional and preserve crate boundaries.
4. Use clear names, small functions, early returns and explicit error paths.
5. Do not add comments. Code, types, tests and module boundaries express intent. Record only what an external system forces on us and no name can say.
6. Every testable behaviour change needs a regression test.
7. Keep changes focused. Do not mix unrelated cleanup into a fix.
8. No feature gates based on accounts, licenses, subscriptions, payment or remote access checks.

## Workspace architecture

The workspace manifest is `Cargo.toml`. [ARCHITECTURE.md](ARCHITECTURE.md) has the data flow.

- `crates/core`: domain types, driver traits, query results, filters, transactions and the driver registry. Depends on no other workspace crate.
- `crates/policy`: statement classification, rules, approvals, masking, blast-radius checks and audit types. Depends on `core` only.
- `crates/storage`: saved connections, Secret Service access, query history and the audit journal.
- `crates/ssh`: SSH tunnels through built-in `russh` or system OpenSSH.
- `crates/transport`: connection assembly for the GUI and `agentd`: driver options, SSH chain, tunnel and the service endpoint used for certificate verification.
- `crates/app-services`: GTK-free application logic moved out of `apps/linux/app/src/services` in stages ([ADR 0018](docs/decisions/0018-headless-app-services-crate.md)); it must not depend on `gtk4`, `libadwaita`, `glib` or `relm4`.
- `crates/mcp`: MCP authentication, scopes, connection allowlists, rate limits, tools and transport.
- `crates/agentd`: headless MCP process and composition root without GTK.
- `crates/drivers/*`: one static crate per engine, implementing `core` traits, never depending on the app.
- `apps/linux/app`: the GTK application and composition root.

Dependencies point toward `core`. Domain and driver crates never import GTK or Relm4. A new engine is a driver crate implementing the `core` contracts, added to both composition roots, with documented maturity ([adding drivers](docs/adding-drivers.md)) and tests against a real engine.

## UI and async rules

- GTK widgets belong to the glib main context. Database and blocking work never run on the GTK thread.
- Relm4 messages drive state transitions; component-scoped commands own work whose lifetime belongs to a component. Async outcomes return to the update loop before touching widgets. Keep logic out of widget construction so it can be unit-tested.
- Cancellation and timeouts reach the database operation (ADR 0005). A dropped future is not proof that a driver stopped.
- Late results never replace state from a newer connection, query or request: use a generation or request id.

## Security invariants

These apply to the GUI, the MCP server and `tablepro-agentd`.

- Every connection exposed to a consumer is wrapped by `PolicyGuard`. MCP and agent code never sees a raw driver connection.
- MCP token scopes say who may call a tool, connection allowlists say which connections a token may use, `PolicyGuard` says what SQL may run. All three are required.
- Preview, transaction, retry and batch paths pass the same policy checks as direct execution.
- Statement handling keeps the order: classify, evaluate rules, request approval when required, apply masking, execute, write the audit outcome.
- Denied, failed, cancelled and timed-out operations produce their terminal audit state. Audit failure never opens a path around policy.
- MCP input, saved connection files, imported files, environment variables and database metadata are untrusted.
- Bind values through driver parameters. Validate and dialect-quote identifiers. Never build SQL by joining untrusted text.
- Passwords, tokens and SSH secrets live in Secret Service through `tablepro-storage`, never in JSON, command lines, traces, errors or audit fields, and stay in `secrecy` types until the driver boundary.
- Bound request sizes, query limits, timeouts and rate limits at external interfaces. No unbounded queues or collections controlled by callers.
- MCP tools use least-privilege scopes and deny access when a token, scope, allowlist entry or policy decision is missing.
- New dependencies need a license and advisory review against `deny.toml`.

## Rust code style

`rustfmt.toml`, `clippy.toml` and the workspace lints are authoritative; [code conventions](docs/code-conventions.md) settles function length, parameters, naming and extraction.

- Rust edition 2024, Rust 1.98, line width 120.
- No comments or doc comments, except the external-system rule above. A Rust file may not gain comment lines (`check-comment-lines.py`, baselines in `baselines/comment-line-baselines.txt`); after deleting comments run `python3 scripts/check-comment-lines.py --update` to lower them.
- Early returns; at most three levels of indentation in a function body.
- A function body is at most 60 lines (`check-function-size.py`, baselines in `baselines/function-size-baselines.txt`: lower a count when you split, never raise one). Rust files stay under 1,200 lines (`check-file-size.sh`, baselines in `baselines/file-size-baselines.txt`: split before growing a listed file).
- Small public APIs; private by default.
- No `unwrap`, `expect`, `panic!`, `todo!` or `unimplemented!` in production paths. A new integration test file under `tests/` starts with `#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]`.
- Typed `thiserror` errors across crate boundaries, with context but no secrets.
- Avoid `unsafe`; isolate it behind the smallest safe interface when a native API forces it.
- Do not suppress Clippy lints locally to avoid fixing code.
- Logs use `tracing` fields; `print!` and friends are denied. Never log SQL parameters, credentials, tokens, connection strings or unmasked results.

## Tests

Unit tests sit next to pure logic; integration tests live in each crate's `tests/`. Driver behaviour is tested against a real database (testcontainers or an isolated local database); filesystem tests use `tempfile`. Policy and MCP changes test denied and allowed cases, scopes, allowlists, approval, masking, timeouts and audit terminal states. GTK-only behaviour that automation cannot reach gets manual steps in [manual verification](docs/manual-verification-0.2-features.md). Never change a test to accept incorrect behaviour; confirm a new regression test fails on the unfixed code.

Rules for pull requests that add tests (any agent, including Cursor):

- Assert observable behaviour, such as an outcome, a stored value or an error kind, and not rule names, message text or internal identifiers that the code owner may rename.
- A test pull request does not change product rules. When a rule looks wrong, tell the lane owner and leave the rule alone.
- A new test fails on the code before the fix, or its commit says it pins existing behaviour.
- Merge the latest BookiE `linux` branch into the branch and run `scripts/preflight.sh` before opening the pull request.
- Do not edit ledger rows, sprint text or files that another lane owns (for example `policy/src/rules.rs`, owned by B4 in the lane table); those edits are what conflict.
- Check the open pull requests for the same files first. When two change the same map or sentinel (for example `change-test-map.json`), say which one lands first and rebase the other.
- Say in the pull request when it needs the Forgejo gate; the maintainer or the UX lane gates the exact head, since these agents cannot reach Forgejo.

Every test belongs to one tier with one script and one gate. Use the [validation playbook](docs/validation-playbook.md) to pick layers and `python3 scripts/run-test-layer.py --list` to discover commands.

| Tier | Contents | Script |
|---|---|---|
| unit | `--lib` on the non-GTK crate list in `preflight.sh` (skips `tablepro-app`) | `scripts/preflight.sh` |
| sandbox | integration targets needing no Docker, database or display | `scripts/test-sandbox.sh` |
| driver | `crates/drivers/*/tests/integration.rs`, SSH and socket fixtures | `scripts/ci-local.sh integration` |
| driver-tls | `tests/driver-tls` | `scripts/test-driver-tls.sh` |
| release | `tests/release` against PostgreSQL | `scripts/test-postgres-release.sh` |
| gtk-widgets | `#[ignore]` widget tests listed in `scripts/isolated-tests.json` under `gtk` | `scripts/test-gtk-widgets.sh` |
| keyring | `#[ignore]` tests listed under `keyring` | `scripts/test-secret-service.sh` |
| gtk | `apps/linux/app/tests/gtk_safety.py` on an installed build | `scripts/test-gtk-safety.sh` |

All tiers run on Forgejo (`.forgejo/workflows/ci.yml` and `nightly.yml`). New gtk-widgets and keyring tests must be added to `isolated-tests.json`, and the ignored-test inventory regenerated, or the tier fails. A new crate goes into the crate lists in `preflight.sh` and `test-sandbox.sh`.

## Validation

From the repository root, narrow test first, then:

```bash
bash scripts/preflight.sh            # size, panic and bounded-operation guards, fmt, clippy, unit, sandbox
bash scripts/test-gtk-widgets.sh     # when GTK code changed
python3 scripts/check-known-issues.py && python3 scripts/check-doc-links.py   # when docs changed
cargo deny check                           # from the repository root, when dependencies changed
bash scripts/forgejo-gate.sh <branch>
```

Driver integration tests need Docker. If a prerequisite is missing, say which check could not run and why.

## Changelog and commits

- [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) in `CHANGELOG.md` under `[Unreleased]`: one line per user-facing change, describing user impact, with no paths, type or function names. Test coverage, evidence runs and audits are not changelog entries; record them on the owning board or in `docs/evidence/`. Do not add `Fixed` for a defect introduced and fixed before release.
- Conventional Commits with a single-line subject and no body. Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`, `style`, `revert`, `security`. Scopes such as `app`, `core`, `policy`, `mcp`, `agentd`, `storage`, `ssh`, `drivers`, `driver-postgres`.
- A public API change updates every caller and test in the same commit.

## Documentation rules

The [documentation map](docs/README.md) says where each fact lives and where a new document goes. In short: decisions in ADRs, open work in the ledger, order and acceptance in the sprint, run-specific proof in `docs/evidence/` or the PR, dated reviews in `docs/archive/`. Write each fact once and link to it. Keep file paths stable; scripts and other lanes depend on them.

## Writing style

Short, plain sentences. Be specific. No em dashes, sales language or generic praise. User-facing text describes behaviour and next steps without internal errors or secrets.
