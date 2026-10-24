# Upstream Linux adoption and development workflow review

Reviewed 2026-10-18 against TablePro `main` `0ab322ea1d7576cfd858ab5946edb9e84cba9e5b` and BookiE `linux` `8626129e60c8f62661cf6d64a70067a6cbfbe654`. The maintainer confirmed that BookiE 0.2.0 delivery work is complete and release publication is pending. The [backlog](../backlog.md) owns subsequent order; this review changes no accepted ADR and publishes no release.

This extends the [movement and implementation audit](upstream-linux-movement-2026-10-18.md), with [source fingerprints and public observations](evidence/upstream-linux-audit-2026-10-18/source-pins.json). Public issue/PR state and local source were inspected. No application, database probe, package build or performance test was run. New tasks are investigations or selected engineering improvements, not a claim that BookiE reproduces an upstream bug.

## What to reuse from BookiE's upstream

TablePro remains BookiE's upstream and a source of compatible Rust/Linux code, not only feature ideas. Its Linux implementation has shared April history with BookiE. The useful unit of adoption is a bounded change with a known contract, source commit and regression case. Reuse can include code, fixtures, scripts and workflow structure when they fit. Record provenance and applicable attribution, adapt every affected consumer, and retain BookiE's type, session, policy and durable-identity decisions.

The [upstream reference guide](../upstream-sync.md) is the active entry point. Apple source, Swift runtime plugins and Mac license tiers do not fit BookiE's Linux composition. No framework or client-library replacement is selected merely because upstream chose it.

## Code architecture and contracts

| Upstream evidence | BookiE disposition | Selected owner |
|---|---|---|
| Connection-owned calls distinguish statement and connection cancellation, and wait for cancellation to settle before reuse | Extend existing control coverage with shared phase/resource cases. Closed #688 already fixed the direct late-cancel race; current `run_server_cancellable` awaits dispatch and uses unknown outcomes conservatively. The pooler/cross-client question is distinct. | UP-2 ([#1140](https://github.com/cozyGarage/BookiE/issues/1140)), UP-4 ([#1142](https://github.com/cozyGarage/BookiE/issues/1142)) |
| PostgreSQL uses tokio-postgres/deadpool and unnamed operations; pooler tests cover cancel, following work and setting isolation | First reproduce on BookiE's SQLx path. Compare typed results, custom codecs, protocol cancellation, arbitrary transports and pooler semantics before a library decision. Upstream's simple-query editor currently returns text metadata, a real migration cost. | UP-2 ([#1140](https://github.com/cozyGarage/BookiE/issues/1140)) |
| MySQL UTC reads and server-zone writes, DST round-trip checks and strict workspace modes | Native-client oracle for defaults/keys/schema changes before adopting session mutations. Existing non-UTC decode refusal is valuable but answers a different question. | UP-3 ([#1141](https://github.com/cozyGarage/BookiE/issues/1141)) |
| Capability values describe endpoint, TLS, auth, atomicity, commit resolution, count estimates and object kinds | Extend capabilities for a real consumer. Existing APP-MOD and #1065 own the dispatch/object-capability work. Avoid importing an entire new contract solely to remove driver-name matches. | Existing owners |
| Forward/backward page anchors and PostgreSQL heap windows with plan tests | Extend existing primary-key seeking first. Treat physical identity and consistency as an explicit engine decision; retain keyless-write refusal. | UP-5 ([#1143](https://github.com/cozyGarage/BookiE/issues/1143)) |
| Awaited result sink sends rows, metadata, notices and completion/truncation events | Reuse backpressure/event cases. Existing #1033 must precede #1034, and #1032 owns cumulative retained resources. A row-batch size is not a byte or process-memory ceiling. | Existing owners |
| Export streams on a separate read-only connection, with cancellation/progress and destination cleanup | Useful later ADR 0014 input. Snapshot consistency, session-local context, policy/audit, byte bounds and publication remain required. Separate full export from database snapshots. | Existing decision |

Sources: upstream [driver decision](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/docs/decisions/0016-driver-contract-v2.md), [capabilities](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/crates/core/src/capabilities.rs), and [paging cases](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/crates/drivers/postgres/tests/integration/paging.rs).

## Code style and enforceable rules

Upstream's [contributor guide](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/CONTRIBUTING.md) and [app Clippy configuration](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/crates/app/clippy.toml) provide useful enforcement examples:

- Disallowed methods make ownership rules executable: ambient runtime/spawn calls, blocking the GTK loop, abrupt application quit, and input delivery that can panic after close.
- Disallowed constructors protect a trust boundary: catalogue SQL text cannot be constructed from arbitrary UI input.
- Narrow source checks catch known GTK mistakes: blocking file operations, replacing the window's own action map, and unsafe tab identity stored through qdata.
- Clippy runs with and without default features. App/session configs retain the root JSON rules because Clippy uses the nearest config rather than merging all configs.

BookiE already enforces crate dependencies, GUI-free services, bounded app database operations, panic sites, file/function size and comment ratchets. Extend those checks where a real escape remains. UP-6 ([#1144](https://github.com/cozyGarage/BookiE/issues/1144)) asks for a small, evidenced set of app/task restrictions with positive and negative fixtures. Do not copy upstream's prohibition of Relm4 APIs into BookiE's accepted Relm4 architecture.

Upstream permits explanatory comments, uses a 100-line Clippy function threshold and suggests one non-trivial public type per file. BookiE deliberately uses its stricter comment rule and 60-line production-function ceiling. Those are different conventions, not findings against either project. Keep related internal helpers together; moving every small enum to its own module would add navigation cost without proving a boundary. A changed convention needs its own focused implementation and documentation, not a casual amendment in a feature patch.

The strongest transferable habit is to connect every important rule to a measurable failure and an enforcing tool. Avoid adding source greps whose false positives train contributors to ignore them. Prefer semantic/compiler checks where practical and test any source scanner against aliases, multiline syntax and permitted test code.

## Test design and CI

Upstream's [test guide](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/docs/testing.md) uses common connection, DDL and TLS conformance suites with engine adapters and capability agreement. Fault fakes expose deterministic lifecycle edges; real servers establish engine behavior. The cases themselves can be checked against fakes, reducing the risk that the test framework asserts nothing useful.

BookiE already has shared driver helpers, real-engine tests, TLS fixtures, contract guardrails, test mapping and an ignored-test registry. UP-4 ([#1142](https://github.com/cozyGarage/BookiE/issues/1142)) should first map existing coverage and then extract common knowledge; it must not create another tier, blanket-enable ignored tests or weaken guards to accommodate adapters. Engine exceptions need explicit reasons and cases. Independent native observations remain necessary for value/commit assertions.

Upstream's [Linux workflow](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/.github/workflows/build-linux.yml) has an always-evaluated aggregate `Linux` check after its component jobs. Path detection is a job, so unrelated changes can produce an explicit successful aggregate rather than omit a required workflow. The aggregate rejects failure/cancellation while allowing intentional skips. The path detector defaults to running when it lacks a baseline and uses NUL-separated names. These are useful contract-test cases, not permission to install Forgejo paths-ignore filters.

BookiE's GitHub cheap/Forgejo merge split already prevents duplicate expensive work. Retain the serialized Forgejo gate and inspect current harness tests before importing an aggregate or selector. Conditional success is valid only if the required dependency set actually ran for the relevant diff. Test absent baselines, merge-only pushes, shared-script changes, cancellation and failed dependencies. Changes to gate selection require pipeline regression tests.

Upstream pins tool versions, uses action SHA pins with dependency updates, checks unused dependencies with cargo-shear, runs supply-chain checks and tests its workflow/release scripts. BookiE already pins workflow actions and several validators and has a substantial harness. Investigate missing feature combinations and tool drift within #573 rather than add heavy jobs for tools already run by BookiE. Measure queue/build/test duration separately; more parallel jobs are not automatically faster on the lab. #1075 is closed and its existing scenario-timing outcome should be preserved. Three upstream SQL Server cancellation cases are excluded pending a client issue, so hosted green must still be read with that limitation.

## Build, infrastructure and software supply chain

### Deterministic release inputs

Upstream's [source builder](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/build-aux/packaging/make-sources.sh) creates committed source and versioned dependency tarballs, normalizes vendor archive ordering/ownership/time, and carries a Cargo source-replacement configuration. Distribution builds consume those inputs offline.

BookiE already creates an Arch candidate from an immutable SHA/checksum, checks package contents and exercises upgrades. UP-8 ([#1146](https://github.com/cozyGarage/BookiE/issues/1146)) extends that path with captured dependency inputs and consistent metadata. Preserve all local patched crates in source replacement. Preparation can use the network; compilation must prove when it does not. Stable inputs do not imply byte-identical binaries without separate evidence. Any native build-script download needs its own recorded treatment.

Upstream's [smoke check](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/build-aux/packaging/smoke-test.sh) installs with only declared runtime dependencies before adding test tools. It checks startup, askpass, schemas and desktop metadata. BookiE should reuse that ordering around its existing richer package/upgrade cases. Xvfb smoke does not replace native Hyprland/Wayland use.

### Attribution and dependency maintenance

Upstream's [notice generator](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/build-aux/update-third-party-licenses.sh) pins cargo-about and rejects a missing original license file rather than silently emitting generic SPDX text. The generated notice graph feeds installed package metadata and About. UP-7 ([#1145](https://github.com/cozyGarage/BookiE/issues/1145)) first inventories what BookiE's GUI, agentd, askpass, optional/native components and vendored crates actually ship. Cargo-deny policy and a complete attribution inventory serve different purposes.

Upstream's [custom-code decision](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/docs/decisions/0005-supply-chain-policy.md) records why maintained crates do not suffice, a reproduction, rejected alternatives and a trigger to revisit the decision. This is a useful maintenance habit. BookiE already checks pristine-crate-plus-patch equality and has [upstream patch proposals](../proposals/upstream-patches.md). Reuse those canonical records and keep exact contract tests as retirement criteria. Upstream's refusal of forks and single crypto provider do not authorize removing BookiE's security/value fixes or forcing its different driver graph into one provider.

## Contribution, documentation and release cycle

Upstream prefers small PRs and requires a changelog fragment, generated catalogue refresh and before/after screenshots for UI changes. BookiE already requires focused regressions and one-lane ownership. The useful additions are evidence that reviewers can inspect, not a longer checklist repeating the same rules.

UP-9 ([#1147](https://github.com/cozyGarage/BookiE/issues/1147)) evaluates [towncrier fragments](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/towncrier.toml) against actual shared-Unreleased conflicts. Preserve Keep a Changelog output, user-impact prose and current history. Define PR-number timing, docs/test-only exemptions, security notes and maintenance branches. Until a convention change lands, contributors continue to edit CHANGELOG.md as AGENTS requires.

UP-10 ([#1148](https://github.com/cozyGarage/BookiE/issues/1148)) considers the bounded [documentation-symbol checker](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/scripts/check-doc-symbols.sh) and deterministic gettext refresh. BookiE's link checker proves path existence but not symbol existence or supported command syntax. Start with active architecture/developer pages and test explicit exceptions for historical, optional/generated and external SDK references. The upstream shell extractor is heuristic and should not be transplanted wholesale. GIR-dependent checks must report unavailable inventories honestly and stay outside a GUI-free documentation gate where appropriate.

The upstream [release guide](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/docs/releasing.md) separates release metadata, tag publication, downstream package builds, package-only revisions and maintenance branches. Its PPA/COPR success cannot be inferred from a successful webhook/upload. The transferable practice is a pinned release input and separate observable outcomes at each service boundary. BookiE need not adopt those distribution services to gain it.

## Decision and tracking

UP-1 ([#1149](https://github.com/cozyGarage/BookiE/issues/1149)) tracks the selected packets on Project #3; the [ledger](../known-issues.md) maps UP IDs to issues. Post-0.2.0 order is in the [backlog](../backlog.md). Each issue states its lane, BookiE existing coverage, upstream pin, scope, acceptance layers and what remains a decision. Source changes take the existing local and Forgejo path.

Reuse existing owners for server messages, stream budgets, active edits, diagnostics, UI accessibility, dependency patches and lab capacity. Full export, a UI framework change, crypto-provider consolidation and wholesale driver replacement remain separate decisions. Review upstream Linux weekly and before release qualification; select one case, adapt it, prove it, then send a narrowly scoped fix upstream when it applies to both trees and the maintainer authorizes that contribution.
