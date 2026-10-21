# Lazy completion proposals, October 21

Related work: [#580](https://github.com/cozyGarage/BookiE/issues/580). Source rationale: [October 21 TablePro review](../../archive/tablepro-collaboration-2026-10-21.md#2-large-catalog-responsiveness-with-lazy-sidebar-and-completion-rows). Base: `ec6f5b0f3`. This is an independent adaptation of the lazy-model technique, using the existing application RowStore and GListModel conventions; no upstream implementation file was copied.

## Scope

The completion provider previously constructed a GTK Proposal and insertion snapshot for every matching candidate before returning its model. An immutable GListModel now creates each proposal on item access and caches it for stable identity. Candidate computation, ordering, quoting, source replacement ranges and activation checks are unchanged. The captured generation belongs to model creation, so a proposal first requested after catalog invalidation remains retired.

The cache cannot contain more entries than the candidate list. It retains requested proposals until the model is released; it is not an eviction cache. Candidate strings and ranking still run eagerly on GTK. This slice does not establish a main-loop latency, peak-memory or complete many-schema acceptance result, and does not close #580. Off-thread ranking, lazy sidebar rows and driver catalog scoping remain separate work.

## Regression evidence

`large_catalog_materializes_only_requested_completion_proposals` uses 50,000 synthetic table names and requests only the first and last suggestions. It checks shared-source retention as a deterministic bound on materialized insertion snapshots, stable identity on repeated item access, candidate order, out-of-range requests and actual activation into the SQL buffer. With the original provider and the new test alone, it failed at the source-retention assertion. With the lazy model, it passed. This checks the current insertion ownership contract without constructor test hooks; it is not an allocator or RSS measurement.

`proposals_first_requested_after_catalog_retirement_do_not_edit_the_buffer` pins existing stale-generation behavior at the new deferred-construction boundary. The catalog is invalidated before the proposal is retrieved. Activation leaves the buffer unchanged. Both tests run as separate processes in the existing isolated GTK tier on Omarchy with Xvfb and Cairo; no database is required.

## Validation and review

The two narrow GTK cases passed. Full preflight passed: 290 Python harness tests, 2,022 unit tests, 2,023 sandbox tests and one Redis cancellation regression. All 83 isolated GTK cases passed, and app all-target Clippy passed with warnings denied. Documentation links, issue-index and ignored-test registration checks passed. A separate self-review found no additional defect; this was not an independent review. Forgejo run #838 passed all 29 jobs at implementation commit `76d58f5bb2d1f29364bf60a2c3ddb0de2cf90e21`. [PR #1275](https://github.com/cozyGarage/BookiE/pull/1275) contains the implementation. Current linux was merged as `453653a7a`; the branch's own diff under apps, crates and scripts was compared byte-for-byte before and after that merge and is unchanged. Preflight on the updated base also passed, including the expanded 321-test Python harness and the same Rust tiers. Documentation-only follow-up does not change the gated code or tests. GitHub PR checks remain required before merge. This document does not qualify native Wayland interaction or the final popover's timing.

## Landing order

Open PR #1236 changes the provider's session lexical-settings call and refresh logic, stacked after #1220. This slice retains the existing candidate-call seam and changes the returned model representation after matching. Whichever branch lands later must merge current linux and preserve both changes. Other open widget PRs also append isolated-test registrations; preserve every registered case when merging.
