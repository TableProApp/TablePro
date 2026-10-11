# Grid memory and fetch action plan, 2026-10-07

**Status:** Completed the scroll profile and validated a weak cache for clean
shared rows. The measured change is implemented in `RowStore`; query paging
and ODBC remain separate work.

This plan turns the RowStore and ODBC review into bounded next steps. Profiling
confirmed that strong row caching grew with scroll distance, so the safe weak
cache candidate was implemented and profiled against the previous version.
The proposed transient index wrapper and ODBC integration were not adopted.

## Background and constraints

PR [#104](https://github.com/cozyGarage/BookiE/pull/104) introduced `RowStore`:
it shares the result with its owner and creates a `RowObject` when requested.
The runner profile recorded a drop from 308 MB to 240 MB RSS at 100k rows, and
from 339 MB to 254 MB at 300k capped rows. The local release profile at baseline
`400e09bb9453c343162a6e017adf52db131f8405` measured increases of 81 MB at 100k
and 94 MB at 300k. Those results support the change for initial display.

The initial-load profiles did not establish a viewport memory bound.
`RowStore::item` permanently replaced shared slots with strong `RowObject`
references, retaining cloned cells until a row was removed or the result was
replaced. The scroll profile below confirmed that memory grew with traversal.

The refreshed BookiE `linux` branch includes PR
[#115](https://github.com/cozyGarage/BookiE/pull/115), which added 5,000-row
paged full-table CSV/JSON export. Do not rebuild that feature. Snapshot
consistency remains tracked separately as UI-13b.
The proposed ODBC sample has value-conversion, buffer truncation, handle
ownership and cancellation problems described by [ADR 0007](../decisions/0007-type-and-value-preservation.md),
[ADR 0005](../decisions/0005-server-side-cancellation.md) and
[ADR 0008](../decisions/0008-connection-and-session-ownership.md).

## Profile result

The new `scripts/profile-row-retention.sh` runs a release GTK build in a clean
app process for each sample, using the existing six-column SQLite row shape.
Each run checks the accessible vertical scrollbar, walks 1,000 evenly spaced
positions from top to bottom and back, verifies the visible row range at the
middle and bottom, and samples RSS after load, at those points, and after
returning to the top. The 300k request reaches row 120,019 and is therefore
byte-capped; truncation is inferred from the generated row number because the
grid's accessibility status does not expose `QueryResult::truncated`.

The table gives medians of three runs on the same local machine. `scroll
growth` is RSS at the bottom minus RSS after load. The automated scroll time
includes AT-SPI and settling delays; compare it only within this harness.

| Requested rows | Rows loaded | Strong-cache RSS after load / bottom | Weak-cache RSS after load / bottom | Scroll growth before → after |
| ---: | ---: | ---: | ---: | ---: |
| 10,000 | 10,000 | 193.2 / 200.8 MB | 193.7 / 195.2 MB | 7.9 → 1.6 MB (80% lower) |
| 100,000 | 100,000 | 247.0 / 317.9 MB | 249.0 / 253.7 MB | 69.8 → 5.2 MB (93% lower) |
| 300,000 | 120,019 (capped) | 259.6 / 343.9 MB | 260.9 / 266.7 MB | 84.4 → 5.8 MB (93% lower) |

RSS remained at the bottom value after returning to the top with the strong
cache. The weak-cache prototype stayed within 1.6, 5.2, and 5.8 MB of its
post-load RSS respectively. Median automated scroll time did not regress
(36.5 → 36.0 s, 126.5 → 124.1 s, and 147.3 → 144.8 s). Initial result time
was also effectively unchanged. These results justify adopting weak caching
for rows backed by the immutable shared result.

The profile does not export a production live-GObject counter. The focused
RowStore tests use the test-only `materialized()` count and verify that a shared
row remains identical while a caller holds it, then becomes releasable when
all callers drop it. Draft and replacement objects remain strongly owned.

## Actions and disposition

### 1. Measure row retention while scrolling — DONE

Added `scripts/profile-row-retention.sh` and a focused GTK scenario. It reuses
the six-column SQLite row shape and measures 10k, 100k and byte-cap-limited
inputs in three clean-process repetitions each.

Keep the initial-load measurement already recorded as the baseline. The GTK
profile measures first-result time, loaded row count inferred from the bottom
visible generated row, RSS at the load/middle/bottom/top checkpoints, and
automated scroll time. The harness cannot read `QueryResult::truncated` or an
exact live-GObject count; test-only `materialized()` assertions cover whether
the model retains a row after all callers release it.

**Decision gate passed:** strong-cache scroll growth was 7.9–84.4 MB and
remained after returning to the top. `RowStore`'s strong slots retained each
materialized object; the test-only count confirmed a requested row remained
materialized after its caller released it. Proceeded to the bounded-cache
prototype.

### 2. Prototype bounded clean-row caching — IMPLEMENTED AND PROFILED

Kept `RowStore` as the `gio::ListModel` and `RowObject` as its item type.
Shared result slots now hold a `glib::WeakRef<RowObject>` plus the immutable
source index. Requests upgrade the weak reference while another consumer still
holds the object, preserving identity; after all consumers release it, the
model recreates the row from the shared result. Draft and replacement rows
remain strong model-owned objects.

The consumer trace covered selection, sort/filter, focus restoration, context
menus, change tracking, edits, draft insert/remove and row refresh. The
[GListModel contract](https://docs.gtk.org/gio/iface.ListModel.html) remains
covered by the held-reference identity regression.

Compared the prototype with the same release profile. Outcomes:

- shared-row slots hold no strong `RowObject` reference; test-only live count
  returns to zero after the last caller releases the row;
- held objects remain valid and stable, drafts retain their IDs and values, and
  the GTK browse-edit-save scenario passes;
- RSS growth after scrolling improves in all three repeated sizes, with no
  material change in first-result or automated scroll time;
- the full app library suite passes (536 passed; 38 ignored by declared
  Docker/GTK requirements).

The end-to-end profile did not measure an exact viewport object count, and
focus restoration was not exercised by a dedicated GTK scenario. Those remain
verification limits. Do not replace identity with a bare row-position integer;
inserts, removals and sorting make positions move.

### 3. Keep query paging as a separate design task

PERF-8 concerns arbitrary editor results, not the already merged table export.
When scheduled, design bounded result pages through `core`, each driver and
`PolicyGuard`. Specify session ownership, authorization and masking, audit
lifecycle, cancellation confirmation, timeout, late-result rejection, expiry,
metadata and the retained-page budget before implementing a driver. Appending
every page forever is still unbounded memory. Re-running arbitrary SQL with
`LIMIT`/`OFFSET` is not a safe substitute for a retained query session.

Keep PR #115's UI-13b snapshot-consistency issue visible. Paged export must not
claim a consistent snapshot while rows can change between page requests.

### 4. Revisit ODBC only for a named engine gap

Do not add unixODBC or `odbc-api` for this performance task. Existing engines
already have native drivers, and columnar block fetch does not bound memory if
the application collects every row into a `Vec`. If a specific unsupported
engine justifies ODBC later, scope one driver and prove its type mappings,
metadata, long-value handling, TLS, secrets, policy, native cancellation and
installation requirements. Preserve ADR 0007 outcomes: exact typed support,
exact text fallback, explicit refusal or untested. Never map failed decoding to
`NULL` or coerce decimal values to `f64` without proof.

## Evidence and boundaries

The earlier profile measured initial grid load only. This profile is a local
Xvfb/Cairo run, not a GPU or installed-desktop measurement. Scroll steps are
spaced across the scrollbar range, so RSS samples show real GtkColumnView
requests but do not count every unique row object directly.

Historical PR CI outcomes remain historical evidence only. This work started
from the freshly fetched BookiE `linux` tip `4d0ee77d1`; that is the profile
baseline, not the current integration tip. The current fetched `fork/linux` tip
is tracked in the [sprint](../bookie-0.2-sprint.md). Local evidence at the time
included all 574 app library tests (536 passed, 38 ignored), the GTK browse
edit/save scenario, the three-repetition before/after profile, documentation
checks and `git diff --check`. The profile has not been rerun on the newer tip.
No ODBC/vendor or installed Wayland profile was run.
