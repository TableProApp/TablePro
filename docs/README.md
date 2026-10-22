# Documentation map

Read this page before loading long plans or evidence. Rules for agents and contributors are in the repository [AGENTS.md](../AGENTS.md). The completion page records milestone status and the backlog sets subsequent work order; accepted ADRs set technical rules. A dated result proves only its recorded source, environment and consumer.

## Minimum context for a task

1. [AGENTS.md](../AGENTS.md).
2. [Completion and continuation](bookie-0.2-sprint.md), then the selected [post-0.2.0 backlog](backlog.md) issue.
3. Your lane's issues on [Bookie Project #3](https://github.com/users/cozyGarage/projects/3) (filter by **Lane**). The [ledger index](known-issues.md) maps ledger IDs to issues.
4. The governing [ADR](decisions/README.md); for every type or value change, [ADR 0007](decisions/0007-type-and-value-preservation.md).
5. The affected checks in the [validation playbook](validation-playbook.md).

Do not load archives as mandatory context. Look up the heading, test selector or SHA you need, and recheck current source before trusting words such as "next", "current" or "pending" in a dated document.

## Documents by audience

| Audience | Documents |
|---|---|
| People using BookiE | [User guide](user-guide.md), [feature list](features.md), [platforms](platforms.md), [root README](../README.md) |
| Maintainers reviewing capability scope | [Capability review](capability-review.md) |
| Contributors writing code | [AGENTS.md](../AGENTS.md), [architecture](../ARCHITECTURE.md) (including [where new code goes](../ARCHITECTURE.md#where-new-code-goes) and the boundary checklist), [code conventions](code-conventions.md), [adding drivers](adding-drivers.md), [state management](state-management.md), [connections](connections.md), [disconnection contracts](disconnection-contracts.md), [storage](storage.md), [error handling](error-handling.md) |
| Releases | [Release process](release-process.md): tags, packages, release notes |
| Contributors testing | [Validation playbook](validation-playbook.md) (including [CI tiers](validation-playbook.md#ci-tiers): GitHub cheap vs Forgejo merge), [testing](testing.md), ignored-test inventory (`scripts/inventory-ignored-tests.py`, generated, not committed), [manual verification](manual-verification-0.2-features.md) |
| Planning and status | [Sprint](bookie-0.2-sprint.md), [0.2.0 scope](0.2.0-scope.md), [backlog](backlog.md), [known limitations](known-limitations.md), [Project #3](https://github.com/users/cozyGarage/projects/3), [ledger index](known-issues.md), [B3 board pointer](type-contract-strategy.md), [B4 board pointer](b4-task-board.md), [value evidence index](value-contracts.md), [ROADMAP](../ROADMAP.md), [changelog](../CHANGELOG.md) |
| Product context and specs | [PRODUCT.md](../PRODUCT.md), [user contexts](personas.md), [PRINCIPLES.md](../PRINCIPLES.md), [SECURITY.md](../SECURITY.md), [capability specs](../specs/README.md) (descriptive drafts until architect review; AGENTS and ADRs rank above them) |
| Decisions | [ADRs](decisions/README.md), [decision checklist](decisions/checklist.md), [proposals](proposals/) |
| Proof and history | [evidence](evidence/), [archive](archive/), [external code review](upstream-sync.md) |

## Where each fact belongs

| Fact | Owner | Update rule |
| --- | --- | --- |
| A rule for every change | [AGENTS.md](../AGENTS.md) | One copy; tool-specific files point to it |
| Product constraints, users and outcomes | [PRODUCT.md](../PRODUCT.md), [personas](personas.md), [PRINCIPLES.md](../PRINCIPLES.md) | Keep aligned with shipped behaviour; product constraints are not implementation status |
| Current capability behaviour extracted from code | [specs/](../specs/README.md) | Descriptive only; when a spec and the code disagree, fix the spec |
| An architecture or behaviour decision | An [ADR](decisions/README.md) | Proposed, then Accepted by the maintainer; change a decision explicitly in a new or amended ADR; keep the [checklist](decisions/checklist.md) row in sync |
| Which forks already have an answer | The [decision checklist](decisions/checklist.md) | Link, N/A, or open item; do not invent a decision to fill a cell |
| A design not yet decided | [proposals/](proposals/) | Becomes an ADR or is deleted; aggregate Forgejo trains are accepted in [ADR 0020](decisions/0020-aggregate-forgejo-trains.md) |
| An open issue, its status and lane | [Project #3](https://github.com/users/cozyGarage/projects/3); ID map in the [ledger index](known-issues.md) | Status and Lane on the project; keep the index ID→issue→Lane table in sync; `scripts/check-known-issues.py` checks format offline, while `scripts/check-github-issue-status.py` reports live issue state |
| Milestone completion and subsequent order | [Completion](bookie-0.2-sprint.md), [scope](0.2.0-scope.md), [backlog](backlog.md) | Record maintainer completion separately from publication; keep issue acceptance on Project #3 and dated proof in the archive |
| B3 remaining work | Project #3 Lane B3; [B3 board pointer](type-contract-strategy.md) | Issues on the project; pointer keeps accepted refusals and the case record |
| B4 implementation and acceptance | Project #3 Lane B4; [B4 board pointer](b4-task-board.md) | Issues on the project; acceptance checklists stay in the archived board |
| Type and consumer proof lookup | The [value evidence index](value-contracts.md) | Link to the case; detailed logs belong in evidence or history |
| Distros, toolchain, packages, Flathub, accessibility | [Platforms](platforms.md) | Keep the build/CI floor and GNOME 50 package line distinct ([ADR 0002](decisions/0002-rust-gtk4-libadwaita.md)) |
| Commands, layers, gates, handoff format | The [validation playbook](validation-playbook.md) | Reuse existing layers; say whether a result was local, Forgejo or installed |
| Crates, request pipeline, where new code goes, DAG, rename boundary, CI gate split | [Architecture](../ARCHITECTURE.md) (Mermaid map, trait boundaries, ownership table) | Match the manifests and [AGENTS.md](../AGENTS.md); cheap vs Forgejo detail stays in the [validation playbook](validation-playbook.md#ci-tiers) |
| A user-visible change | The [changelog](../CHANGELOG.md) | One line of user impact; no test or evidence notes |
| What a user can do and how | The [user guide](user-guide.md) | Update with the feature that changes it |
| What BookiE does, by task, with screenshots | The [feature list](features.md) | Update with the feature that changes it; screenshots follow the [brand guide](brand/README.md#screenshots) |
| Name, logo, colours and image files | The [brand guide](brand/README.md) | Change the guide and the files together |
| Run-specific proof (manifests, focused logs) | `evidence/<topic>[-<sha>]-<YYYY-MM-DD>/` | A `manifest.json` or concise `README.md`, with only the artifacts needed to check the claim; link it from the owning row or board |
| A finished review, audit or long history | [archive/](archive/) | Dated file name; corrections to links or neutral wording must preserve the recorded evidence, dates and decisions |

The [runner maintenance and isolation proposal](proposals/runner-maintenance-and-isolation.md) records the observed cleanup risks and the staged mini PC runner migration. It is not deployed acceptance.

## Adding a document

- Look for the owner in the table above first; most new facts are a row, a section or an ADR, not a new file.
- A new reference document goes in `docs/` with a lowercase, hyphenated name and a line in the audience table above. Keep it under about 3,000 words; split by concern before it grows past that.
- Number ADRs sequentially (`decisions/NNNN-title.md`) and add them to the ADR index with their status.
- Evidence directories are named `<topic>[-<sha>]-<YYYY-MM-DD>` and hold only what a reviewer needs to check a claim. Use a manifest for structured evidence or a concise README for a focused local report. Large or raw logs stay in the PR or CI run.
- When a document stops being current, move it to `archive/` with its date in the name, update links (`scripts/check-doc-links.py` finds the broken ones) and leave its open items on Project #3.
- Do not move or rename a current document casually: scripts, CI and other lanes link to these paths.

## Archive starting points

[archive/](archive/) holds dated reviews, audits, inventories and long histories. They are source-pinned evidence, not instructions; open items from them live on [Project #3](https://github.com/users/cozyGarage/projects/3). The [changelog engineering history index](../CHANGELOG.md#historical-engineering-records) locates dated records.

[Archive claim verification, October 20](evidence/archive-claim-verification-2026-10-20/README.md) inventories every archived document, traces explicit BookiE issue links and source symbols, and identifies the focused current-source tests actually rerun. Research completion, issue closure and runtime acceptance are separate claims.

- [Sprint history](archive/bookie-0.2-history.md) (includes 2026-10-08/09 continuation snapshots)
- [B4 history](archive/b4-history.md) (includes superseded tip checkpoints, [completed local slices](archive/b4-history.md#archived-completed-local-slices-2026-10-10-consolidation) and [remaining-task prose](archive/b4-history.md#archived-remaining-task-prose-2026-10-10-pass-4))
- [Evidence directory index](archive/evidence-index-2026-10-10.md) (failed / incomplete / retest vs historical pass; do not delete red manifests)
- [PostgreSQL session outcome regressions, October 20](evidence/postgres-session-outcomes-375253c-2026-10-20/README.md): audit, typed commit and GTK evidence for #1186 and #1187.
- [Forgejo nightly #778 selective rerun plan, October 20](evidence/nightly-778-selective-rerun-2026-10-20/README.md): preserve completed jobs and isolate OOM-interrupted shards before the next run.
- [Capability evidence audit](archive/capability-evidence-2026-09-07.md) (historical September capability snapshot; current status is in the sprint)
- [B3 board narrative](archive/type-contract-history.md#archived-b3-board-narrative-2026-10-09-consolidation-pass-2) and [value-contracts narrative](archive/value-contract-history.md#archived-value-contracts-narrative-2026-10-09-consolidation-pass-2) (2026-10-09 pass 2)
- [Release audit, October 3](archive/release-audit-2026-10-03.md)
- [Offline release input audit, October 19](archive/offline-release-input-audit-2026-10-19.md) (current Arch candidate evidence and remaining offline inputs)
- [Third-party notice inventory, October 19](archive/third-party-notice-inventory-2026-10-19.md) (dated package inventory and generator requirements)
- [Changelog fragment evaluation, October 19](archive/changelog-fragment-evaluation-2026-10-19.md) (kept the current workflow because commit volume did not establish conflict cost)
- [Architecture review](archive/architecture-consistency-review-2026-10-03.md) and its [inventory companion](archive/architecture-consistency-2026-10-03-inventory.md)
- [AUD-10 DuckDB read-only file access](archive/duckdb-read-only-aud10-2026-10-10.md)
- [App layer audit](archive/app-layer-external-audit-2026-10-06.md): UI layering, request ownership and test-boundary findings
- [Grid memory and fetch action plan](archive/grid-memory-and-fetch-action-plan-2026-10-07.md)
- [Settings and icon review, October 14](archive/ui-refresh-upstream-review-2026-10-14.md)
- [Upstream main](archive/upstream-main-review-2026-10-03.md) ([inventory](archive/upstream-main-review-2026-10-03-inventory.md)) and [older releases](archive/upstream-older-releases-review-2026-10-03.md) ([inventory](archive/upstream-older-releases-2026-10-03-inventory.md))
- [External audit and post-0.2 plan](archive/external-audit-2026-10-06.md) and its [implementation review](archive/external-audit-client-review-2026-10-06.md)

## Keep context bounded

Record a rule once in an ADR and a task once on Project #3. Do not copy old test counts into a current claim. Keep ignored `target/quality` paths as plain text, and when output is unavailable, say so instead of leaving a dead link.

## Engineering review records (October 2026)

- [Stream page construction, October 22](evidence/stream-frame-2026-10-22/README.md): regression for grids built before their first frame, CPU attribution and partial optimized acceptance.

- [Editor toolbar rows, October 21](evidence/editor-toolbar-rows-2026-10-21/README.md): reproduced minimum-width mismatch, bounded action rows and headless allocation regression.

- [0.2.0 release qualification, October 21](evidence/release-0.2.0-2026-10-21/README.md): candidate package checks, functional and profiling observations, with final publication and desktop acceptance recorded separately.
- [Installed 0.2.0 GTK safety run, October 21](evidence/installed-gtk-0.2.0-2026-10-21/README.md): 93 source-matched installed-package scenarios passed under Xvfb/AT-SPI; native Wayland visual acceptance remains separate.

- [PostgreSQL gate repair, October 21](evidence/postgres-gate-repair-2026-10-21/README.md): deterministic pooled-reset regression, installed retired-session acceptance and the successful 29-job gate.

- [Large SQL editor analysis, October 21](evidence/large-sql-editor-analysis-2026-10-21/README.md): bounded advisory snapshots, deferred diagnostics and remaining full-document costs.
- [Large-query rendering, October 21](evidence/large-query-rendering-2026-10-21/README.md): deferred hidden grids, lifecycle regression and external rendering lessons.

- [Bounded SQL result pager, October 21](evidence/stream-result-pager-2026-10-21/README.md): retained-page navigation, row-range regression and remaining visual acceptance.

- [Initial SQL editor focus, October 21](evidence/editor-focus-2026-10-21/README.md): failing-then-passing GTK focus regression and remapping behavior.
- [Grid lifetime and memory investigation, October 21](evidence/grid-lifetime-2026-10-21/README.md): reproduced GTK ownership cycles, original/fixed heap profiles, PostgreSQL RSS probe and remaining manual acceptance.

- [Public documentation language review, October 21](evidence/public-documentation-language-2026-10-21/README.md): repository-wide Markdown screening, neutral wording corrections and independent adoption criteria.

- [TablePro adoption and collaboration, October 21](archive/tablepro-collaboration-2026-10-21.md): current Linux performance, SSH, export and translation changes, PostgreSQL behavior candidates and concrete upstream contribution routes.
- [Beekeeper Studio live UX observation, October 22](archive/beekeeper-studio-live-ux-observation-2026-10-22.md): connection form, filter modes, schema/type presentation, sidebar affordances and export scope, compared with current BookiE behavior.

- [dbx architecture and regression follow-up, October 21](archive/dbx-follow-up-2026-10-21.md): changes since the prior pin, PostgreSQL session/restore lessons, current architecture guards and qualified regression candidates.

- [Newest-code and upstream follow-up, October 20](archive/upstream-next-slices-2026-10-20.md): PostgreSQL transaction outcome gaps, native/savepoint and CI diagnostic probes, current upstream changes and proposed next slices.
- [TablePro and dbx deep review, October 20](archive/tablepro-dbx-review-2026-10-20/README.md): full feature, architecture and fix-commit mapping of TablePro `3222542a4` and dbx `d1e88ab4b` against BookiE `7c4cb3929`, with Wave 0 defects to confirm and a ranked roadmap of candidates.
- [Upstream main analysis, October 20](archive/upstream-main-analysis-2026-10-20.md): pinned Linux and Apple changes, current adoption status, transferable regression cases and integration costs.

- [Linux code adoption and development workflow](archive/upstream-linux-adoption-2026-10-18.md), with the [source movement audit](archive/upstream-linux-movement-2026-10-18.md): code, CI, conventions and closed post-0.2.0 tracker [#1149](https://github.com/cozyGarage/BookiE/issues/1149).
- [0.2.0 completion handoff](archive/bookie-0.2-completion-handoff-2026-10-18.md): maintainer completion statement, publication boundary and previous scope/sprint snapshots.

- [Code and UI audit, October 18](archive/code-and-ui-audit-2026-10-18.md): dated source evidence for pending-state cues, high contrast and responsiveness.
- [Capability review](capability-review.md): general evaluation method and BookiE's current technical boundaries.
- [Database-client architecture, CI and operation-outcome review, October 15](archive/2026-10-15-dbx-review.md): source-specific evidence is preserved in the dated archive; current general evaluation criteria are in the [capability review](capability-review.md).
- [Issue-derived database-client regression patterns, October 20](archive/tablepro-issue-review-2026-10-20.md): dated source references and BookiE checks; use the [capability review](capability-review.md) for current general guidance.
- [Peer-review delivery tracker](https://github.com/cozyGarage/BookiE/issues/1026) and its lane-owned slices are the current work queue for the review below.
- [Linux documentation update plan and peer review, October 16](archive/linux-peer-review-2026-10-16.md): source reconciliation, architecture boundaries, and regression candidates.
- [Linux peer review, October 17](archive/linux-peer-review-2026-10-17.md): dated source checks and applicable regression-test lessons.
- [PostgreSQL edge-case research archive](archive/2026-10-15-postgresql-client-research/review.md), with its [scenario catalogue](archive/2026-10-15-postgresql-client-research/cases.csv) and [probe evidence](archive/2026-10-15-postgresql-client-research/manifest.json). These are dated source-comparison records; current BookiE contracts are summarized in the [capability review](capability-review.md).

- [Agent tooling review, October 20](archive/agent-tooling-review-2026-10-20.md): TablePro and dbx agent skills, rules and reviewer agents, and what BookiE adopted (the `fix-issue` skill) or left for gated follow-ups.

- [Workstation test reuse proposal](proposals/workstation-test-reuse.md): bounded local execution, build metadata reuse, cache ownership and post-nightly adoption order.

- [Zed editor and panel review, October 22](archive/zed-editor-panel-review-2026-10-22.md): completed research, existing PR dependencies and issue-owned results/error/message panel follow-ups.
- [GPUI client review, October 22](archive/gpui-client-review-2026-10-22.md): completed source research including dbdelve; open adoption proposals remain on their issues.
- [Transaction-control proposal review, October 22](archive/transaction-control-review-2026-10-22.md): completed DBF-5 verification against existing shared-connection and owned-session guards.

- [Browse inspector callback lifetime, October 22](evidence/inspector-cycle-2026-10-22/README.md): failing then passing GTK weak-reference regression for a selection-to-inspector ownership cycle.

- [Query row decoding budget, October 22](evidence/query-row-budget-2026-10-22/README.md): pre-decode row checks, measured PostgreSQL client RSS reduction and remaining allocation limits.
- [Borrowed row identity checks, October 22](evidence/row-key-borrowing-2026-10-22/README.md): reduced copying during stale-edit validation, with key contract tests and allocation measurements.

- [Linux follow-up review, October 22](archive/linux-follow-up-review-2026-10-22.md): merged result-memory fixes, corrected evidence status and nonduplicating UI acceptance order.

- [Arch wrapper release date, October 22](evidence/arch-wrapper-date-2026-10-22/README.md): mandatory-date forwarding, boundary regressions and real isolated package upgrade/removal evidence.
- [Dedicated-session opening guard, October 22](evidence/session-opening-guard-2026-10-22/README.md): standalone held-open regression and current-Linux source checks.
