# Engineering review records, October 2026

This dated catalog preserves evidence links from the October 2026 review cycle. It is historical navigation, not current task status. See the [current documentation map](../README.md), [completion page](../bookie-0.2-sprint.md) and [backlog](../backlog.md) for current direction.


- [Database-client refresh, October 23](../archive/database-client-review-2026-10-23.md): all 14 named clients, source/release pins, pagination reversal, FK comparison semantics and ranked BookiE follow-ups.

- [Saved connection row layouts, October 23](../evidence/saved-connection-row-2026-10-23/README.md): light/dark narrow/normal widget captures, allocation checks and the remaining GTK measurement warning.

- [Merge baseline validation, October 23](evidence/merge-baseline-validation-2026-10-23/README.md): workspace-test compile repair, scoped local validation and the independent completion-popup timeout.

- [Table-browse resource profile, October 22](../evidence/table-browse-resource-2026-10-22/README.md): measured a wide SQLite page headlessly and exposed missing truncation feedback.

- [Stream page construction, October 22](../evidence/stream-frame-2026-10-22/README.md): regression for grids built before their first frame, CPU attribution and partial optimized acceptance.

- [Editor toolbar rows, October 21](../evidence/editor-toolbar-rows-2026-10-21/README.md): reproduced minimum-width mismatch, bounded action rows and headless allocation regression.

- [0.2.0 release qualification, October 21](../evidence/release-0.2.0-2026-10-21/README.md): candidate package checks, functional and profiling observations, with final publication and desktop acceptance recorded separately.
- [Installed 0.2.0 GTK safety run, October 21](../evidence/installed-gtk-0.2.0-2026-10-21/README.md): 93 source-matched installed-package scenarios passed under Xvfb/AT-SPI; native Wayland visual acceptance remains separate.

- [PostgreSQL gate repair, October 21](../evidence/postgres-gate-repair-2026-10-21/README.md): deterministic pooled-reset regression, installed retired-session acceptance and the successful 29-job gate.

- [Large SQL editor analysis, October 21](../evidence/large-sql-editor-analysis-2026-10-21/README.md): bounded advisory snapshots, deferred diagnostics and remaining full-document costs.
- [Large-query rendering, October 21](../evidence/large-query-rendering-2026-10-21/README.md): deferred hidden grids, lifecycle regression and external rendering lessons.

- [Bounded SQL result pager, October 21](../evidence/stream-result-pager-2026-10-21/README.md): retained-page navigation, row-range regression and remaining visual acceptance.

- [Initial SQL editor focus, October 21](../evidence/editor-focus-2026-10-21/README.md): failing-then-passing GTK focus regression and remapping behavior.
- [Grid lifetime and memory investigation, October 21](evidence/grid-lifetime-2026-10-21/README.md): historical four-page cache ownership evidence, original/fixed heap profiles, PostgreSQL RSS probe and remaining manual acceptance.

- [Public documentation language review, October 21](evidence/public-documentation-language-2026-10-21/README.md): repository-wide Markdown screening, neutral wording corrections and independent adoption criteria.

- [TablePro adoption and collaboration, October 21](../archive/tablepro-collaboration-2026-10-21.md): current Linux performance, SSH, export and translation changes, PostgreSQL behavior candidates and concrete upstream contribution routes.
- [Beekeeper Studio live UX observation, October 22](../archive/beekeeper-studio-live-ux-observation-2026-10-22.md): connection form, filter modes, schema/type presentation, sidebar affordances and export scope, compared with current BookiE behavior.

- [dbx architecture and regression follow-up, October 21](../archive/dbx-follow-up-2026-10-21.md): changes since the prior pin, PostgreSQL session/restore lessons, current architecture guards and qualified regression candidates.

- [Newest-code and upstream follow-up, October 20](../archive/upstream-next-slices-2026-10-20.md): PostgreSQL transaction outcome gaps, native/savepoint and CI diagnostic probes, current upstream changes and proposed next slices.
- [TablePro and dbx deep review, October 20](../archive/tablepro-dbx-review-2026-10-20/README.md): full feature, architecture and fix-commit mapping of TablePro `3222542a4` and dbx `d1e88ab4b` against BookiE `7c4cb3929`, with Wave 0 defects to confirm and a ranked roadmap of candidates.
- [Upstream main analysis, October 20](../archive/upstream-main-analysis-2026-10-20.md): pinned Linux and Apple changes, current adoption status, transferable regression cases and integration costs.

- [Linux code adoption and development workflow](../archive/upstream-linux-adoption-2026-10-18.md), with the [source movement audit](../archive/upstream-linux-movement-2026-10-18.md): code, CI, conventions and closed post-0.2.0 tracker [#1149](https://github.com/cozyGarage/BookiE/issues/1149).
- [0.2.0 completion handoff](../archive/bookie-0.2-completion-handoff-2026-10-18.md): maintainer completion statement, publication boundary and previous scope/sprint snapshots.

- [Code and UI audit, October 18](../archive/code-and-ui-audit-2026-10-18.md): dated source evidence for pending-state cues, high contrast and responsiveness.
- [Capability review](../capability-review.md): general evaluation method and BookiE's current technical boundaries.
- [Database-client architecture, CI and operation-outcome review, October 15](../archive/2026-10-15-dbx-review.md): source-specific evidence is preserved in the dated archive; current general evaluation criteria are in the [capability review](../capability-review.md).
- [Issue-derived database-client regression patterns, October 20](../archive/tablepro-issue-review-2026-10-20.md): dated source references and BookiE checks; use the [capability review](../capability-review.md) for current general guidance.
- [Peer-review delivery tracker](https://github.com/cozyGarage/BookiE/issues/1026) and its lane-owned slices are the current work queue for the review below.
- [Linux documentation update plan and peer review, October 16](../archive/linux-peer-review-2026-10-16.md): source reconciliation, architecture boundaries, and regression candidates.
- [Linux peer review, October 17](../archive/linux-peer-review-2026-10-17.md): dated source checks and applicable regression-test lessons.
- [PostgreSQL edge-case research archive](../archive/2026-10-15-postgresql-client-research/review.md), with its [scenario catalogue](../archive/2026-10-15-postgresql-client-research/cases.csv) and [probe evidence](../archive/2026-10-15-postgresql-client-research/manifest.json). These are dated source-comparison records; current BookiE contracts are summarized in the [capability review](../capability-review.md).

- [Agent tooling review, October 20](../archive/agent-tooling-review-2026-10-20.md): TablePro and dbx agent skills, rules and reviewer agents, and what BookiE adopted (the `fix-issue` skill) or left for gated follow-ups.

- [CI build speed proposal](../proposals/ci-build-speed.md): where Forgejo gate time goes, a `ci` build profile for GUI scenario jobs and sharded distro-floor scenarios, ordered after the ADR 0021 runner upgrade.
- [Workstation test reuse plan](workstation-test-reuse-2026-10-20.md): dated local execution plan and pilot evidence.

- [Zed editor and panel review, October 22](../archive/zed-editor-panel-review-2026-10-22.md): completed research, existing PR dependencies and issue-owned results/error/message panel follow-ups.
- [GPUI client review, October 22](../archive/gpui-client-review-2026-10-22.md): completed source research including dbdelve; open adoption proposals remain on their issues.
- [Transaction-control proposal review, October 22](../archive/transaction-control-review-2026-10-22.md): completed DBF-5 verification against existing shared-connection and owned-session guards.
- [Grid search focus, October 22](../evidence/grid-search-focus-2026-10-22/README.md): owned focus restoration and keyboard regression coverage for large and wide results.

- [Editor bottom panel desktop acceptance, October 22](../evidence/editor-bottom-panel-2026-10-22/README.md): source-built native Wayland, keyboard/pointer, error/timeout and layout evidence; package and Forgejo gates stay separate.
- [Selection statistics resource investigation, October 22](../evidence/selection-statistics-2026-10-22/README.md): borrowed-cell computation, numeric behavior tests and matched headless heap profiles.
- [Inspector preview resource investigation, October 22](../evidence/inspector-preview-2026-10-22/README.md): borrowed-cell previews, preserved field semantics and matched headless heap/timing measurements.
- [Browse inspector callback lifetime, October 22](evidence/inspector-cycle-2026-10-22/README.md): failing then passing GTK weak-reference regression for a selection-to-inspector ownership cycle.
- [Editor error navigation, October 22](../evidence/editor-error-navigation-2026-10-22/README.md): structured positions, exact statement origins, stale-action refusal and native PostgreSQL pointer/keyboard acceptance.

- [Query row decoding budget, October 22](../evidence/query-row-budget-2026-10-22/README.md): pre-decode row checks, measured PostgreSQL client RSS reduction and remaining allocation limits.
- [Borrowed row identity checks, October 22](../evidence/row-key-borrowing-2026-10-22/README.md): reduced copying during stale-edit validation, with key contract tests and allocation measurements.

- [Linux follow-up review, October 22](../archive/linux-follow-up-review-2026-10-22.md): merged result-memory fixes, corrected evidence status and nonduplicating UI acceptance order.

- [Session opening and SQL execution ordering, October 22](../evidence/session-opening-run-order-2026-10-22/README.md): held-open regression and shared execution readiness checks.
- [Arch wrapper release date, October 22](../evidence/arch-wrapper-date-2026-10-22/README.md): mandatory-date forwarding, boundary regressions and real isolated package upgrade/removal evidence.
- [Dedicated-session opening guard, October 22](../evidence/session-opening-guard-2026-10-22/README.md): standalone held-open regression and current-Linux source checks.

- [Completion popup initialization, October 22](../evidence/completion-popup-initialization-2026-10-22/README.md): reproduced missing GtkSourceView initialization, independent probe and startup regression.
- [Owned GTK process checks, October 22](../evidence/owned-gtk-process-2026-10-22/README.md): fixture PID/lifetime ownership for memory sampling and second launch, with two-process regressions and targeted GTK acceptance.

- [Evidence branch migration proposal](../proposals/evidence-branch.md): gradual artifact relocation, immutable source identity and a separately tested CI publisher.

- [Toolkit startup ordering, October 23](../evidence/toolkit-startup-2026-10-23/README.md): fresh-process regression for GTK initialization before library version checks.

- [Build-script manifest ownership, October 23](../evidence/build-manifest-2026-10-23/README.md): cross-checkout resource ownership and deleted-checkout regressions.

- [Optimized PostgreSQL fixture profile, October 23](../evidence/postgres-optimized-fixture-2026-10-23/README.md): optimized many-column RSS and timing observations with explicit artifact provenance.

- [Export snapshot allocation probe, October 23](../evidence/export-snapshot-sharing-2026-10-23/allocation-probe/README.md): matched synthetic allocation measurements for the merged snapshot-sharing repair.
- [Grid factory realization, October 23](evidence/grid-factory-realization-2026-10-23/README.md): initial layout, teardown, vertical bounds and scroll-rebinding counters.
- [Editor scrolling resources, October 23](../evidence/editor-scroll-resources-2026-10-23/README.md): actual visible row traversal and process RSS, with exact artifact identity.
- Historical October 22 probes: [large result scrolling](evidence/large-result-profile-2026-10-22/README.md) and [post-decode byte-budget overshoot](evidence/query-result-byte-budget-2026-10-22/README.md). These preserve older source observations; they do not supersede later repairs or measurements.

- [Pull request maintenance, October 22](evidence/pr-maintenance-2026-10-22/README.md): historical source inventory, prepared refreshes and validation limits.

- [Workspace restoration and cleanup privacy train, October 23](evidence/forgejo-train-1518-2026-10-23/README.md): exact-head Forgejo run 925, required GitHub checks and documentation-only post-merge source verification.

- [Read-only label selection cost, October 23](../evidence/grid-label-selection-cost-2026-10-23/README.md): controlled allocation experiment and the interaction/accessibility constraints on a future optimization.

- [Keyboard menu routing acceptance, October 23](../evidence/grid-keyboard-routing-acceptance-2026-10-23/README.md): exact-head Forgejo run 926 and post-merge source comparison for #1519.

- [Shared grid pointer routing, October 23](../evidence/grid-pointer-routing-2026-10-23/README.md): controlled allocation measurements and local interaction checks, with [gate acceptance](evidence/grid-pointer-routing-acceptance-2026-10-23/README.md).
- [Optimized PostgreSQL streaming investigation, October 23](../evidence/postgres-optimized-stream-2026-10-23/README.md): two explicit timeout observations, bounded retained rows, sampled RSS and a limited psql control.

- [Compact multiline previews, October 23](../evidence/compact-multiline-preview-2026-10-23/README.md): failing height regression and read-only cell layout correction with exact-text checks.
- [Stream page realization, October 23](../evidence/stream-page-realization-2026-10-23/README.md): optimized two-million-row comparisons and retained-page navigation checks.
- [Local resource profiling, October 23](../evidence/local-resource-profiling-2026-10-23/README.md): repeated query/close cycles, large saved SQL files, allocation tracing and paired early-close measurements.

- [Function-size regression discovery, October 23](../evidence/function-checker-discovery-2026-10-23/README.md): existing checker cases made discoverable by the coverage workflow, with unchanged assertions and explicit coverage limits.

- [X11 popup targeting, October 23](../evidence/x11-popup-target-2026-10-23/README.md): pointer and resize boundary regressions and a disposable Xvfb window experiment for GTK harness reliability.
- [Floor image APT network bounds, October 23](../evidence/floor-apt-network-bounds-2026-10-23/README.md): download retry and HTTP/HTTPS timeout configuration with image-contract coverage.
- [Published AppImage resources, October 23](../evidence/appimage-resource-check-2026-10-23/README.md): verified the published package loads bundled GtkSourceView language and style resources; rendering and clean-container launch remain unverified.
- [Dirty-file discard and final-tab recheck, October 23](../evidence/tab-close-recheck-2026-10-23/README.md): pinned-release Xvfb checks for discard, final-tab close, opening a fresh editor and narrow-toolbar widths; native Wayland freeze remains unresolved.

- [Original PostgreSQL streaming workload, October 23](../evidence/postgres-original-stream-2026-10-23/README.md): three full two-million-row runs, five server-confirmed cancellation cycles, and bounded heap/RSS observations on the release-profile build; installed-package and matched historical-baseline behavior remain unverified.
- [Combined resource validation, October 23](../evidence/performance-integration-2026-10-23/README.md): editor shutdown and streamed-result fixes tested together with a byte-bounded UTF-8 script and million-row workloads.
