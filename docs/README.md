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
| Contributors writing code | [AGENTS.md](../AGENTS.md), [architecture](../ARCHITECTURE.md) (including [where new code goes](../ARCHITECTURE.md#where-new-code-goes) and the boundary checklist), [code conventions](code-conventions.md), [adding drivers](adding-drivers.md), [static driver capabilities](driver-capabilities.md), [state management](state-management.md), [value contract rules](value-contract-rules.md), [connections](connections.md), [disconnection contracts](disconnection-contracts.md), [storage](storage.md), [error handling](error-handling.md) |
| Releases | [Release process](release-process.md): tags, packages, release notes |
| Contributors testing | [Validation playbook](validation-playbook.md) (including [CI tiers](validation-playbook.md#ci-tiers): GitHub cheap vs Forgejo merge), [testing](testing.md) ([GTK](testing-gtk.md), [CI](testing-ci.md), [quality and performance](testing-quality-and-performance.md)), [test design rules](test-design-rules.md), [performance and acceptance scenarios](performance-acceptance-scenarios.md), [test-oracle review](oracle-review.md), ignored-test inventory (`scripts/inventory-ignored-tests.py`, generated, not committed), [manual verification](manual-verification-0.2-features.md) |
| Planning and status | [0.2.0 completion and continuation](bookie-0.2-sprint.md), [backlog](backlog.md), [unselected feature candidates](0.2-feature-comparison.md), [known limitations](known-limitations.md), [Project #3](https://github.com/users/cozyGarage/projects/3), [ledger index](known-issues.md), [B3 board pointer](type-contract-strategy.md), [B4 board pointer](b4-task-board.md), [value evidence index](value-contracts.md), [changelog](../CHANGELOG.md) |
| Product context and specs | [PRODUCT.md](../PRODUCT.md), [user contexts](personas.md), [PRINCIPLES.md](../PRINCIPLES.md), [SECURITY.md](../SECURITY.md), [capability specs](../specs/README.md) (descriptive drafts until architect review; AGENTS and ADRs rank above them) |
| Decisions | [ADRs](decisions/README.md), [decision checklist](decisions/checklist.md), [proposal index](proposals/README.md) |
| Proof and history | [evidence](evidence/), [archive](archive/), [evidence branch migration proposal](proposals/evidence-branch.md), [external code review](upstream-sync.md) |

## Where each fact belongs

| Fact | Owner | Update rule |
| --- | --- | --- |
| A rule for every change | [AGENTS.md](../AGENTS.md) | One copy; tool-specific files point to it |
| Product constraints, users and outcomes | [PRODUCT.md](../PRODUCT.md), [personas](personas.md), [PRINCIPLES.md](../PRINCIPLES.md) | Keep aligned with shipped behaviour; product constraints are not implementation status |
| Current capability behaviour extracted from code | [specs/](../specs/README.md) | Descriptive only; when a spec and the code disagree, fix the spec |
| An architecture or behaviour decision | An [ADR](decisions/README.md) | Proposed, then Accepted by the maintainer; change a decision explicitly in a new or amended ADR; keep the [checklist](decisions/checklist.md) row in sync |
| Which forks already have an answer | The [decision checklist](decisions/checklist.md) | Link, N/A, or open item; do not invent a decision to fill a cell |
| A design not yet decided | [proposal index](proposals/README.md) | Becomes an ADR or is deleted; aggregate Forgejo trains are accepted in [ADR 0020](decisions/0020-aggregate-forgejo-trains.md) |
| An open issue, its status and lane | [Project #3](https://github.com/users/cozyGarage/projects/3); ID map in the [ledger index](known-issues.md) | Status and Lane on the project; keep the index ID→issue→Lane table in sync; `scripts/check-known-issues.py` checks format offline, while `scripts/check-github-issue-status.py` reports live issue state |
| Milestone completion and subsequent order | [Completion and scope](bookie-0.2-sprint.md), [backlog](backlog.md) | Record maintainer completion separately from publication; keep issue acceptance on Project #3 and dated proof in the archive |
| B3 remaining work | Project #3 Lane B3; [B3 board pointer](type-contract-strategy.md) | Issues on the project; pointer keeps accepted refusals and the case record |
| B4 implementation and acceptance | Project #3 Lane B4; [B4 board pointer](b4-task-board.md) | Issues on the project; acceptance checklists stay in the archived board |
| Type and consumer proof lookup | The [value evidence index](value-contracts.md) | Link to the case; detailed logs belong in evidence or history |
| Distros, toolchain, packages, Flathub, accessibility | [Platforms](platforms.md) | One toolkit floor ([ADR 0021](decisions/0021-toolkit-floor.md)) |
| Commands, layers, gates, handoff format | The [validation playbook](validation-playbook.md) | Reuse existing layers; say whether a result was local, Forgejo or installed |
| Crates, request pipeline, where new code goes, DAG, rename boundary, CI gate split | [Architecture](../ARCHITECTURE.md) (Mermaid map, trait boundaries, ownership table) | Match the manifests and [AGENTS.md](../AGENTS.md); cheap vs Forgejo detail stays in the [validation playbook](validation-playbook.md#ci-tiers) |
| A user-visible change | A `Release-Note:` line in the PR body and squash commit ([ADR 0022](decisions/0022-release-notes-from-merge-commits.md)) | One line of user impact, or `none`; no test or evidence notes. `CHANGELOG.md` is frozen until the next release cut |
| What a user can do and how | The [user guide](user-guide.md) | Update with the feature that changes it |
| What BookiE does, by task, with screenshots | The [feature list](features.md) | Update with the feature that changes it; screenshots follow the [brand guide](brand/README.md#screenshots) |
| Name, logo, colours and image files | The [brand guide](brand/README.md) | Change the guide and the files together |
| Run-specific proof (manifests, focused logs) | `evidence/<topic>[-<sha>]-<YYYY-MM-DD>/` | A `manifest.json` or concise `README.md`, with only the artifacts needed to check the claim; link it from the owning row or board |
| A finished review, audit or long history | [archive/](archive/) | Dated file name; corrections to links or neutral wording must preserve the recorded evidence, dates and decisions |

The [runner maintenance and isolation proposal](proposals/runner-maintenance-and-isolation.md) records repository safeguards and the remaining deployment and isolated-runner acceptance under #573. It does not describe a deployed environment.

## Adding a document

- Look for the owner in the table above first; most new facts are a row, a section or an ADR, not a new file.
- A new reference document goes in `docs/` with a lowercase, hyphenated name and a line in the audience table above. Keep it under about 3,000 words and split by concern before it grows past that. A single-audience reference that is read top to bottom, such as the [user guide](user-guide.md) and the [validation playbook](validation-playbook.md), may run to about 4,000 words, because splitting it would scatter one path across files.
- Number ADRs sequentially (`decisions/NNNN-title.md`) and add them to the ADR index with their status.
- New evidence directories are named `<topic>[-<sha>]-<YYYY-MM-DD>` and hold only what a reviewer needs to check a claim. Use a manifest for structured evidence or a concise README for a focused local report. Keep large or raw logs in the PR or CI run. Keep current acceptance evidence at stable paths until the [proposed evidence-branch migration](proposals/evidence-branch.md) passes its retrieval pilot. Obsolete historical packets with no current test, code or acceptance consumer may move to `archive/evidence/` after all narrative links are updated; preserve their bytes and source identity.
- When a document stops being current, move it to `archive/` with its date in the name, update links (`scripts/check-doc-links.py` finds the broken ones) and leave its open items on Project #3.
- Do not move or rename a current document casually: scripts, CI and other lanes link to these paths.

## Archive starting points

[archive/](archive/) holds dated reviews, audits, inventories and long histories. They are source-pinned evidence, not instructions; open items from them live on [Project #3](https://github.com/users/cozyGarage/projects/3). Use the archive starting points below to locate a record, then verify current behavior and status in active docs and issues.

[Archive claim verification, October 20](evidence/archive-claim-verification-2026-10-20/README.md) records an inventory baseline for archived Markdown at that review, with an October 21 supplement. It traces explicit BookiE issue links and source symbols and lists the focused current-source tests rerun then; later archive additions are outside its inventory. Research completion, issue closure and runtime acceptance are separate claims.

- [Sprint history](archive/bookie-0.2-history.md) (includes 2026-10-08/09 continuation snapshots)
- [0.1.x implementation history](archive/changelog-history-0.1.x-2026-10-23.md) (archived from the changelog to keep it focused on release notes)
- [B4 history](archive/b4-history.md) (includes superseded tip checkpoints, [completed local slices](archive/b4-history.md#archived-completed-local-slices-2026-10-10-consolidation) and [remaining-task prose](archive/b4-history.md#archived-remaining-task-prose-2026-10-10-pass-4))
- [Evidence directory index](archive/evidence-index-2026-10-10.md) (October 10 snapshot; current inventory and migration status are in the [evidence-branch proposal](proposals/evidence-branch.md))
- [Archived evidence packets](archive/evidence/) (dated artifacts retained after reference triage; the separate-branch migration remains a [proposal](proposals/evidence-branch.md), and these files remain in Git)
- [PostgreSQL session outcome regressions, October 20](evidence/postgres-session-outcomes-375253c-2026-10-20/README.md): audit, typed commit and GTK evidence for #1186 and #1187.
- [Performance review and first phases, October 22–23](archive/performance-review-2026-10-23.md): measured changes that landed, the remaining performance plan and follow-ups.
- [Installed native Wayland run, October 23](evidence/installed-wayland-0.2.0-2026-10-23/README.md): oracle-checked end-to-end flows on Hyprland and the defects filed from them.
- [Installed Arch profile, October 24](evidence/installed-arch-profile-2026-10-24/README.md): package integrity, automated test results, native PostgreSQL UI checks and resource samples.
- [Forgejo nightly #778 terminal inventory, October 20](evidence/nightly-778-selective-rerun-2026-10-20/README.md): dated record of completed, cancelled and OOM-interrupted jobs; it is not current runner guidance.
- [Workspace unit coverage, October 24](evidence/workspace-unit-coverage-9d61c7a-2026-10-24/README.md): 61.42% line coverage on Linux `9d61c7a` against the 59% floor, with the command and its scope.
- [Current Linux PostgreSQL streaming workload, October 24](evidence/postgres-stream-current-2026-10-24/README.md): exact-head ten-column query, repeated bounded-memory measurements, and cancellation/session-recovery outcomes.
- [Native Wayland PostgreSQL streaming profile, October 25](evidence/postgres-stream-native-wayland-2026-10-25/README.md): source-built release run on Omarchy, memory samples, and the observed retained-row range.
- [GitHub merge-order screening, October 25](evidence/merge-order-audit-2026-10-25/README.md): a dated 190-PR screen for merge-before-check completion, with exact observed candidate timestamps and limitations; it does not establish Forgejo outcomes.
- [Capability evidence audit](archive/capability-evidence-2026-09-07.md) (historical September snapshot; current behavior is in [features](features.md) and [known limitations](known-limitations.md), with selected work in the backlog and Project #3)
- [B3 board narrative](archive/type-contract-history.md#archived-b3-board-narrative-2026-10-09-consolidation-pass-2) and [value-contracts narrative](archive/value-contract-history.md#archived-value-contracts-narrative-2026-10-09-consolidation-pass-2) (2026-10-09 pass 2)
- [Release audit, October 3](archive/release-audit-2026-10-03.md)
- [Remaining-gap acceptance, October 15](archive/remaining-gaps-2026-10-15.md) (dated evidence for completed distro, SQL proposal and disconnect-cache findings)
- [Offline release input audit, October 19](archive/offline-release-input-audit-2026-10-19.md) (current Arch candidate evidence and remaining offline inputs)
- [Third-party notice inventory, October 19](archive/third-party-notice-inventory-2026-10-19.md) (dated package inventory and generator requirements)
- [Changelog fragment evaluation, October 19](archive/changelog-fragment-evaluation-2026-10-19.md) (kept the current workflow because commit volume did not establish conflict cost)
- [Development feedback-loop proposal, October 23](archive/devops-feedback-loop-2026-10-23.md) (dated proposal snapshot; active work and priority live in the backlog and Project #3)
- [Workstation test reuse plan, October 20](archive/workstation-test-reuse-2026-10-20.md) (dated local pilot and execution plan; current validation commands are in the playbook)
- [Architecture review](archive/architecture-consistency-review-2026-10-03.md) and its [inventory companion](archive/architecture-consistency-2026-10-03-inventory.md)
- [AUD-10 DuckDB read-only file access](archive/duckdb-read-only-aud10-2026-10-10.md)
- [App layer audit](archive/app-layer-external-audit-2026-10-06.md): UI layering, request ownership and test-boundary findings
- [Grid memory and fetch action plan](archive/grid-memory-and-fetch-action-plan-2026-10-07.md)
- [Settings and icon review, October 14](archive/ui-refresh-upstream-review-2026-10-14.md)
- [Upstream main](archive/upstream-main-review-2026-10-03.md) ([inventory](archive/upstream-main-review-2026-10-03-inventory.md)) and [older releases](archive/upstream-older-releases-review-2026-10-03.md) ([inventory](archive/upstream-older-releases-2026-10-03-inventory.md))
- [External audit and post-0.2 plan](archive/external-audit-2026-10-06.md) and its [implementation review](archive/external-audit-client-review-2026-10-06.md)

## Keep context bounded

Record a rule once in an ADR and a task once on Project #3. Do not copy old test counts into a current claim. Keep ignored `target/quality` paths as plain text, and when output is unavailable, say so instead of leaving a dead link.

## Engineering review records

The dated October 2026 engineering catalog is preserved in the [archive](archive/engineering-review-records-2026-10.md). The archived records prove only their recorded source and environment.
