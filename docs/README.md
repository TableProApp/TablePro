# Documentation map

Read this page before loading long plans or evidence. Rules for agents and contributors are in the repository [AGENTS.md](../AGENTS.md). The active sprint sets work order; accepted ADRs set technical rules. A dated result proves only its recorded source, environment and consumer.

## Minimum context for a task

1. [AGENTS.md](../AGENTS.md).
2. The [active sprint](bookie-0.2-sprint.md), including 0.2.0 readiness.
3. Your lane's rows in the [ledger](known-issues.md#owners-and-handoff).
4. The governing [ADR](decisions/README.md); for every type or value change, [ADR 0007](decisions/0007-type-and-value-preservation.md).
5. The affected checks in the [validation playbook](validation-playbook.md).

Do not load archives as mandatory context. Look up the heading, test selector or SHA you need, and recheck current source before trusting words such as "next", "current" or "pending" in a dated document.

## Documents by audience

| Audience | Documents |
|---|---|
| People using BookiE | [User guide](user-guide.md), [platforms](platforms.md), [root README](../README.md) |
| Anyone comparing clients | [0.2 feature comparison](0.2-feature-comparison.md) |
| Contributors writing code | [AGENTS.md](../AGENTS.md), [architecture](../ARCHITECTURE.md) (including [where new code goes](../ARCHITECTURE.md#where-new-code-goes) and the boundary checklist), [code conventions](code-conventions.md), [adding drivers](adding-drivers.md), [state management](state-management.md), [connections](connections.md), [disconnection contracts](disconnection-contracts.md), [storage](storage.md), [error handling](error-handling.md) |
| Contributors testing | [Validation playbook](validation-playbook.md) (including [CI tiers](validation-playbook.md#ci-tiers): GitHub cheap vs Forgejo merge), [testing](testing.md), [ignored-test inventory](ignored-tests.md) (generated), [manual verification](manual-verification-0.2-features.md), [capability evidence](capability-evidence.md) |
| Planning and status | [Sprint](bookie-0.2-sprint.md), [0.2.0 scope](0.2.0-scope.md), [backlog](backlog.md), [known limitations](known-limitations.md), [ledger](known-issues.md), [B3 board](type-contract-strategy.md), [B4 board](b4-task-board.md), [value evidence index](value-contracts.md), [ROADMAP](../ROADMAP.md), [changelog](../CHANGELOG.md) |
| Product context and specs | [PRODUCT.md](../PRODUCT.md), [personas](personas.md), [PRINCIPLES.md](../PRINCIPLES.md), [SECURITY.md](../SECURITY.md), [capability specs](../specs/README.md) (drafts until reviewed; AGENTS and ADRs rank above them) |
| Decisions | [ADRs](decisions/README.md), [decision checklist](decisions/checklist.md), [proposals](proposals/) |
| Proof and history | [evidence](evidence/), [archive](archive/), [upstream sync](upstream-sync.md) |

## Where each fact belongs

| Fact | Owner | Update rule |
| --- | --- | --- |
| A rule for every change | [AGENTS.md](../AGENTS.md) | One copy; tool-specific files point to it |
| What the product is and who it serves | [PRODUCT.md](../PRODUCT.md), [personas](personas.md), [PRINCIPLES.md](../PRINCIPLES.md) | Keep aligned with shipped behaviour; NEEDS REVIEW until a maintainer clears the draft |
| Current capability behaviour extracted from code | [specs/](../specs/README.md) | Descriptive only; when a spec and the code disagree, fix the spec |
| An architecture or behaviour decision | An [ADR](decisions/README.md) | Proposed, then Accepted by the maintainer; change a decision explicitly in a new or amended ADR; keep the [checklist](decisions/checklist.md) row in sync |
| Which forks already have an answer | The [decision checklist](decisions/checklist.md) | Link, N/A, or open item; do not invent a decision to fill a cell |
| A design not yet decided | [proposals/](proposals/) | Becomes an ADR or is deleted |
| An open issue, its status, evidence and owner | The [ledger](known-issues.md) | One row per issue; cross out only with the closing commit, PR or test; `scripts/check-known-issues.py` checks the format and owners |
| Milestones, order, acceptance, 0.2.0 readiness | The [sprint](bookie-0.2-sprint.md) | Compact current instructions; move dated progress to the archive |
| B3 remaining work | The [B3 board](type-contract-strategy.md) | One bounded case, outcome, evidence pointer and next action |
| B4 implementation and acceptance | The [B4 board](b4-task-board.md) | Update the owning task and integrated status |
| Type and consumer proof lookup | The [value evidence index](value-contracts.md) | Link to the case; detailed logs belong in evidence or history |
| Distros, toolchain, packages, Flathub, accessibility | [Platforms](platforms.md) | Keep the build/CI floor and GNOME 50 package line distinct ([ADR 0002](decisions/0002-rust-gtk4-libadwaita.md)) |
| Commands, layers, gates, handoff format | The [validation playbook](validation-playbook.md) | Reuse existing layers; say whether a result was local, Forgejo or installed |
| Crates, request pipeline, where new code goes, DAG, rename boundary, CI gate split | [Architecture](../ARCHITECTURE.md) (Mermaid map, trait boundaries, ownership table; peers under Studied from for document structure) | Match the manifests and [AGENTS.md](../AGENTS.md); cheap vs Forgejo detail stays in the [validation playbook](validation-playbook.md#ci-tiers) |
| A user-visible change | The [changelog](../CHANGELOG.md) | One line of user impact; no test or evidence notes |
| What a user can do and how | The [user guide](user-guide.md) | Update with the feature that changes it |
| Run-specific proof (manifests, focused logs) | `evidence/<topic>-<YYYY-MM-DD>/` | A `manifest.json` plus small text logs; link it from the owning row or board |
| A finished review, audit or long history | [archive/](archive/) | Dated file name; never edited after archiving except for broken links |

## Adding a document

- Look for the owner in the table above first; most new facts are a row, a section or an ADR, not a new file.
- A new reference document goes in `docs/` with a lowercase, hyphenated name and a line in the audience table above. Keep it under about 3,000 words; split by concern before it grows past that.
- Number ADRs sequentially (`decisions/NNNN-title.md`) and add them to the ADR index with their status.
- Evidence directories are named `<topic>-<YYYY-MM-DD>` and hold only what a reviewer needs to check a claim. Large or raw logs stay in the PR or CI run.
- When a document stops being current, move it to `archive/` with its date in the name, update links (`scripts/check-doc-links.py` finds the broken ones) and leave its open items in the ledger.
- Do not move or rename a current document casually: scripts, CI and other lanes link to these paths.

## Archive starting points

[archive/](archive/) holds dated reviews, audits, inventories and long histories. They are source-pinned evidence, not instructions; open items from them live in the ledger. The [changelog engineering history index](../CHANGELOG.md#historical-engineering-records) locates dated records.

- [Sprint history](archive/bookie-0.2-history.md) (includes 2026-10-08/09 continuation snapshots)
- [B4 history](archive/b4-history.md) (includes superseded tip checkpoints, [completed local slices](archive/b4-history.md#archived-completed-local-slices-2026-10-10-consolidation) and [remaining-task prose](archive/b4-history.md#archived-remaining-task-prose-2026-10-10-pass-4))
- [Evidence directory index](archive/evidence-index-2026-10-10.md) (failed / incomplete / retest vs historical pass; do not delete red manifests)
- [B3 board narrative](archive/type-contract-history.md#archived-b3-board-narrative-2026-10-09-consolidation-pass-2) and [value-contracts narrative](archive/value-contract-history.md#archived-value-contracts-narrative-2026-10-09-consolidation-pass-2) (2026-10-09 pass 2)
- [Release audit, October 3](archive/release-audit-2026-10-03.md)
- [Architecture review](archive/architecture-consistency-review-2026-10-03.md) and its [inventory companion](archive/architecture-consistency-2026-10-03-inventory.md)
- [App layer audit](archive/app-layer-external-audit-2026-10-06.md): GUI gaps and the TablePro and dbx comparison
- [Grid memory and fetch action plan](archive/grid-memory-and-fetch-action-plan-2026-10-07.md)
- [Upstream main](archive/upstream-main-review-2026-10-03.md) ([inventory](archive/upstream-main-review-2026-10-03-inventory.md)) and [older releases](archive/upstream-older-releases-review-2026-10-03.md) ([inventory](archive/upstream-older-releases-2026-10-03-inventory.md))
- [External audit and post-0.2 plan](archive/external-audit-2026-10-06.md) and its [client review](archive/external-audit-client-review-2026-10-06.md)

## Keep context bounded

Record a rule once in an ADR and a task once on its board or in the ledger. Do not copy old test counts into a current claim. Keep ignored `target/quality` paths as plain text, and when output is unavailable, say so instead of leaving a dead link.
