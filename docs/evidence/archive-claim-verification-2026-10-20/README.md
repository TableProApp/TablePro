# Archive claims and upstream research completion, 2026-10-20

**Research status: complete.** The upstream main analysis, hardware inspection and execution plan have been recorded. Its implementation proposals remain owned by their existing issues. Completing a review does not complete those features or certify a release.

**Verification source:** BookiE Linux `8c92a24456e455899c0760f8ef8d39b2eb791b7f`. All source traces and runtime results below refer to this revision. The later changes in this contribution are documentation only. Original external repository pins remain those recorded by each archived review; no new upstream audit is claimed.

## Completion and scope

- [x] Inventory all 64 archived Markdown documents and all four companion artifacts at the verification source.
- [x] Snapshot all 39 explicitly linked BookiE issues, plus the existing owners of the upstream analysis follow-ups.
- [x] Trace 520 documented symbol references to declarations in current Rust source. This counts matches across documents, not unique functions or behavioral proof.
- [x] Rerun focused current-source headless, harness and real PostgreSQL cases; record each selector and its result below.
- [x] Mark the upstream analysis as completed research and correct the stale nightly and nextest planning language.
- [ ] Requalify every historical database, UI, package, performance and mutation assertion on a new candidate. Those results retain their original SHA, environment and limits; this review does not label them current passes.

The [archive inventory](archive-inventory.json) records each document's baseline content hash, source pins, linked BookiE issue states, checkbox counts, evidence links and matching current declarations. The [companion inventory](companion-inventory.json) covers the PostgreSQL research corpus and probe files. A source-symbol match establishes that a declaration exists, not that the archived scenario remains covered. Bare issue numbers can refer to external repositories, PRs or CI runs; only explicit BookiE issue URLs were automatically resolved. The [issue snapshot](issue-snapshot.json) includes the additional manually identified owners below. Issue closure alone is not runtime acceptance.

The uncommitted documentation/privacy work in the original checkout is outside this baseline and has been preserved. Historical unchecked boxes remain unchanged. Current work belongs to the backlog, issue and ADR owners, rather than being reopened from an old archive.

## Claim-to-test evidence

| Archived claim or recommendation | Current check | What this proves |
| --- | --- | --- |
| Explicit core values, policy outcomes and headless application boundaries | 1,275 Core, policy, PostgreSQL decoder and app-services unit tests through nextest; [focused log](headless-tests.txt) | Existing assertions pass on the recorded source. This is not an independent oracle review of every assertion. |
| Lost-ack writes must not replay; cancellation and restart must leave usable resources | All 10 `disconnection::` Docker tests; [log](postgres-disconnection.txt) | Real PostgreSQL lost acknowledgement, server restart, retired sessions, streams, cancellation, timeout and rollback paths. The restart test explicitly retries; application automatic read replay remains unqualified. |
| Exact values need native server oracles and multiple consumers | Native-oracle, wide-numeric, temporal and decoded-text selections; individual logs and counts in the [runtime manifest](runtime-manifest.json) | Selected integer/text/bytea/JSON, wide numeric, calendar and decoded-text contracts. No complete pgvector/PostGIS or universal consumer corpus claim. |
| Reverse keyset navigation needs identity, gaps and a real plan | Three `reverse_keyset_paging::` tests; [log](postgres-reverse-keyset.txt) | Composite identity, empty/exact/partial pages and deep-page index-plan assertions. No UI latency or million-row memory certification. |
| Pooler cancellation must not affect another client | Three pool-cancellation tests; [log](postgres-pooler-cancellation.txt) | Session/transaction pool cancellation isolation against the fixture, including another client's write. No arbitrary deployment qualification. |
| Earlier PostgreSQL stale-plan and quoted-completion defects were closed | Stale-plan and completion selections; [manifest](runtime-manifest.json) | Application errors do not replay sequence effects, prepared SELECT sees changed columns, and completion metadata preserves catalog identity. The full rendered completion interaction is outside this run. |
| Architecture and workflow guards should be executable | 280 Python harness tests plus existing script, catalogue and source guards; [log](harness-tests.txt) | Existing guard contracts pass. Debian package validation was skipped because `dpkg-deb` is unavailable. |
| Repeating selected cases should reuse built binaries | One current-source PostgreSQL test binary, then eight direct filtered executions; identical binary hashes in the [manifest](runtime-manifest.json) | No Cargo or compiler invocation between those selections. The initial build did compile changed artifacts. This does not measure physical NVMe writes or sccache hits. |

The Docker tests were explicitly activated with `--ignored` and serialized with `--test-threads=1`. A preliminary invocation without `--ignored` selected zero runnable tests; it is not counted as passing evidence. The unit selection used four nextest processes and at most six Cargo compilation jobs. The existing warm target was copied with Btrfs reflinks into this worktree's owned target, then built normally for current source. No shared target was concurrently written, no broad clean was run, and no coverage or mutation binary was substituted for a normal test binary.

Commands for the current-source builds:

```bash
CARGO_BUILD_JOBS=6 CARGO_TARGET_DIR="$PWD/target" cargo nextest run --locked \
  -p tablepro-core -p tablepro-policy -p tablepro-driver-postgres \
  -p tablepro-app-services --lib --test-threads 4 --no-tests=fail
CARGO_BUILD_JOBS=6 CARGO_TARGET_DIR="$PWD/target" cargo test --locked \
  -p tablepro-driver-postgres --test integration disconnection:: \
  -- --ignored --test-threads=1
bash scripts/test-harness.sh
```

The subsequent selectors and binary hash are recorded in the manifest. They were executed directly against the built binary with `--ignored --test-threads=1`; refresh the build before reusing them after source, dependency, feature, toolchain or build-environment changes.

## Completed work and remaining owners

| Research outcome | Current issue state | Completion boundary |
| --- | --- | --- |
| Headless no-GTK guard and nextest headless pilot | #887 and #892 closed | Guard/pilot work is complete; other driver and GTK tiers still use libtest. |
| Lossless MCP numeric boundary, structured outcomes and annotations | #895, #896 and #897 closed | Earlier proposals have implementation closure; this run did not requalify every MCP transport path. |
| PostgreSQL retry classification and completion | #900, #901, #923, #933 and #934 closed | Focused native regression evidence above supplements issue state. |
| UP-2 through UP-10 adoption children | #1140–#1148 closed | Parent #1149 remains open. Do not recreate closed children from the October 18 reports. |
| Reconnect/lost acknowledgement and application connection paths | #593 and #590 open | Existing driver assertions pass; application-level lifecycle/replay acceptance remains with these issues. |
| Shared value oracle corpus and extension qualification | #594 and #902 open | Selected native cases passed; complete consumer/extension qualification remains open. |
| Crash during grid save, resource retention and outcome reconciliation | #1029, #1032, #554 and #947 open | No new crash-process, calibrated memory or reconciliation result is claimed here. |
| Accessibility, translated next steps and large catalogs | #561, #575 and #580 open | Rendered UI, native desktop, accessibility and catalog-scale acceptance remain outstanding. |

## Every archived document

These rows are navigation and evidence disposition, not a blanket behavioral certification. "Source traced" means at least one documented declaration still exists. Historical runtime claims remain limited to their original source unless the claim-to-test matrix above explicitly reruns them. Issue states are the snapshot at this review.

| Archived document | Baseline lines | Current declaration matches | Explicit BookiE issue state | Disposition |
| --- | ---: | ---: | --- | --- |
| [2026-10-15-dbx-review.md](../../archive/2026-10-15-dbx-review.md) | 194 | 0 | 5 closed / 3 open | Historical record; no current runtime claim |
| [2026-10-15-postgresql-client-research/review.md](../../archive/2026-10-15-postgresql-client-research/review.md) | 154 | 1 | 8 closed / 4 open | Source traced; historical runtime scope |
| [agent-tooling-review-2026-10-20.md](../../archive/agent-tooling-review-2026-10-20.md) | 63 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [app-layer-external-audit-2026-10-06.md](../../archive/app-layer-external-audit-2026-10-06.md) | 263 | 1 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [architecture-consistency-2026-10-03-inventory.md](../../archive/architecture-consistency-2026-10-03-inventory.md) | 137 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [architecture-consistency-review-2026-10-03.md](../../archive/architecture-consistency-review-2026-10-03.md) | 147 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [b3-review-2026-10-01.md](../../archive/b3-review-2026-10-01.md) | 425 | 16 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [b3-test-scenario-survey.md](../../archive/b3-test-scenario-survey.md) | 168 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [b4-history.md](../../archive/b4-history.md) | 969 | 15 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [b4-release-wrapup-review-2026-10-11.md](../../archive/b4-release-wrapup-review-2026-10-11.md) | 158 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [b4-task-board-pre-project-migration-2026-10-12.md](../../archive/b4-task-board-pre-project-migration-2026-10-12.md) | 163 | 7 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [baseline-review-2026-09-17.md](../../archive/baseline-review-2026-09-17.md) | 155 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [bookie-0.2-completion-handoff-2026-10-18.md](../../archive/bookie-0.2-completion-handoff-2026-10-18.md) | 170 | 1 | 0 closed / 3 open | Source traced; historical runtime scope |
| [bookie-0.2-history.md](../../archive/bookie-0.2-history.md) | 2488 | 22 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [bug-consistency-2026-09.md](../../archive/bug-consistency-2026-09.md) | 69 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [capability-evidence-2026-09-07.md](../../archive/capability-evidence-2026-09-07.md) | 38 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [changelog-fragment-evaluation-2026-10-19.md](../../archive/changelog-fragment-evaluation-2026-10-19.md) | 20 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [ci-audit-2026-09-27.md](../../archive/ci-audit-2026-09-27.md) | 103 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [code-and-ui-audit-2026-10-18.md](../../archive/code-and-ui-audit-2026-10-18.md) | 74 | 3 | 0 closed / 3 open | Source traced; historical runtime scope |
| [connections-history.md](../../archive/connections-history.md) | 314 | 2 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [disconnection-contracts-history-2026-10-01.md](../../archive/disconnection-contracts-history-2026-10-01.md) | 12 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [duckdb-read-only-aud10-2026-10-10.md](../../archive/duckdb-read-only-aud10-2026-10-10.md) | 19 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [evidence-index-2026-10-10.md](../../archive/evidence-index-2026-10-10.md) | 67 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [external-audit-2026-10-06.md](../../archive/external-audit-2026-10-06.md) | 430 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [external-audit-client-review-2026-10-06.md](../../archive/external-audit-client-review-2026-10-06.md) | 222 | 4 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [grid-memory-and-fetch-action-plan-2026-10-07.md](../../archive/grid-memory-and-fetch-action-plan-2026-10-07.md) | 157 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [known-issues-pre-project-migration-2026-10-12.md](../../archive/known-issues-pre-project-migration-2026-10-12.md) | 295 | 125 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [linux-peer-review-2026-10-16.md](../../archive/linux-peer-review-2026-10-16.md) | 189 | 3 | 0 closed / 4 open | Source traced; historical runtime scope |
| [linux-peer-review-2026-10-17.md](../../archive/linux-peer-review-2026-10-17.md) | 78 | 2 | 1 closed / 3 open | Source traced; historical runtime scope |
| [mongodb-consistency-2026-10-03.md](../../archive/mongodb-consistency-2026-10-03.md) | 35 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [offline-release-input-audit-2026-10-19.md](../../archive/offline-release-input-audit-2026-10-19.md) | 17 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [performance-2026-09.md](../../archive/performance-2026-09.md) | 44 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [production-audit.md](../../archive/production-audit.md) | 124 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [reconciliation-2026-09-26.md](../../archive/reconciliation-2026-09-26.md) | 63 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [regression-audit-2026-09-29.md](../../archive/regression-audit-2026-09-29.md) | 151 | 1 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [release-0.1.4.md](../../archive/release-0.1.4.md) | 65 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [release-audit-2026-10-03.md](../../archive/release-audit-2026-10-03.md) | 266 | 3 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [sprint-2026-09-14.md](../../archive/sprint-2026-09-14.md) | 110 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [sprint-review-2026-09-28.md](../../archive/sprint-review-2026-09-28.md) | 191 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [stabilization-2026-09.md](../../archive/stabilization-2026-09.md) | 87 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [tablepro-dbx-review-2026-10-20/README.md](../../archive/tablepro-dbx-review-2026-10-20/README.md) | 181 | 2 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [tablepro-dbx-review-2026-10-20/a-tablepro-linux-features.md](../../archive/tablepro-dbx-review-2026-10-20/a-tablepro-linux-features.md) | 251 | 2 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [tablepro-dbx-review-2026-10-20/b-tablepro-fixes.md](../../archive/tablepro-dbx-review-2026-10-20/b-tablepro-fixes.md) | 119 | 31 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [tablepro-dbx-review-2026-10-20/c-tablepro-macos-ux.md](../../archive/tablepro-dbx-review-2026-10-20/c-tablepro-macos-ux.md) | 369 | 2 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [tablepro-dbx-review-2026-10-20/d-dbx-features.md](../../archive/tablepro-dbx-review-2026-10-20/d-dbx-features.md) | 212 | 3 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [tablepro-dbx-review-2026-10-20/e-dbx-backend-fixes.md](../../archive/tablepro-dbx-review-2026-10-20/e-dbx-backend-fixes.md) | 175 | 110 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [tablepro-dbx-review-2026-10-20/f-dbx-ux-fixes.md](../../archive/tablepro-dbx-review-2026-10-20/f-dbx-ux-fixes.md) | 86 | 35 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [tablepro-issue-review-2026-10-20.md](../../archive/tablepro-issue-review-2026-10-20.md) | 46 | 0 | 0 closed / 1 open | Historical record; no current runtime claim |
| [testing-history.md](../../archive/testing-history.md) | 98 | 10 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [third-party-notice-inventory-2026-10-19.md](../../archive/third-party-notice-inventory-2026-10-19.md) | 21 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [type-contract-history.md](../../archive/type-contract-history.md) | 1768 | 45 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [type-contract-strategy-pre-project-migration-2026-10-12.md](../../archive/type-contract-strategy-pre-project-migration-2026-10-12.md) | 83 | 14 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [ui-refresh-upstream-review-2026-10-14.md](../../archive/ui-refresh-upstream-review-2026-10-14.md) | 43 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [upstream-adoption.md](../../archive/upstream-adoption.md) | 73 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [upstream-linux-adoption-2026-10-18.md](../../archive/upstream-linux-adoption-2026-10-18.md) | 84 | 0 | 9 closed / 1 open | Historical record; no current runtime claim |
| [upstream-linux-movement-2026-10-18.md](../../archive/upstream-linux-movement-2026-10-18.md) | 227 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [upstream-main-analysis-2026-10-20.md](../../archive/upstream-main-analysis-2026-10-20.md) | 125 | 2 | 0 closed / 1 open | Research complete; selected claims rerun above; implementation open |
| [upstream-main-review-2026-10-03-inventory.md](../../archive/upstream-main-review-2026-10-03-inventory.md) | 275 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [upstream-main-review-2026-10-03.md](../../archive/upstream-main-review-2026-10-03.md) | 218 | 7 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [upstream-older-releases-2026-10-03-inventory.md](../../archive/upstream-older-releases-2026-10-03-inventory.md) | 146 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [upstream-older-releases-review-2026-10-03.md](../../archive/upstream-older-releases-review-2026-10-03.md) | 125 | 1 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [upstream-u1-sql-server-2026-10-03.md](../../archive/upstream-u1-sql-server-2026-10-03.md) | 103 | 1 | No explicit BookiE issue URL | Source traced; historical runtime scope |
| [validation-history.md](../../archive/validation-history.md) | 49 | 0 | No explicit BookiE issue URL | Historical record; no current runtime claim |
| [value-contract-history.md](../../archive/value-contract-history.md) | 6492 | 49 | No explicit BookiE issue URL | Source traced; historical runtime scope |

## Limits and next work

No application feature was changed by this contribution. Historical GTK, Wayland, Secret Service, non-PostgreSQL drivers, extension matrices, crash-save, retained-memory limits, distribution floors, package installation, advisory scans and mutation totals were not rerun. Their archived passes, failures, cancellations and uncertainty remain intact. The [workstation plan](../../proposals/workstation-test-reuse.md) and [nightly recovery inventory](../nightly-778-selective-rerun-2026-10-20/README.md) own the existing reuse and selective rerun plans. This documentation update starts no new heavy gate.
