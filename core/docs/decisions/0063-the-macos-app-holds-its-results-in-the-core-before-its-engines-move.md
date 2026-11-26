# 0063: The macOS app holds its results in the core's store before its engines move

- **Status**: Accepted; amends 0010 and 0003
- **Date**: 2026-11-26

## Context

[0010](0010-macos-on-the-core.md) moves the Mac app to the core in slices and puts engines last, in slice 5. Until then the Mac keeps every result in Swift: each cell a `PluginCellValue` enum of 24 bytes, a heap string for each text over 15 UTF-8 bytes, and a heap array per row. 0010 also leaves the engines out of the Apple library ("No engines in the Apple library").

A measured pass over the app (#4559) found the result path costs more than the data it holds:

- **Memory.** One 1M x 20 result raised phys_footprint from 573 to 1,262 MB on PostgreSQL and from 257 to 856 MB on MySQL (#4521).
- **The main thread.** A held sort, masking, the JSON, Map and Chart views, copy, type-select, Display As and select-all walk every row on the main actor (#4521, #4531). Freeing 1M x 10 rows took 55 to 206 ms in a scratch binary with the app's types, and every path that frees a result runs on the main actor (#4527).
- **A cap.** `PluginRowLimits.emergencyMax` stops every read at 5,000,000 rows. Fetch All reads past it, keeps 5,000,000 rows and shows them as complete (#4524).
- **No bound across tabs.** Every background tab, every result of a multi-statement run and every pinned result keeps its rows until the user closes or re-runs it (#4556).

The core already holds results in the right shape. `ResultStore` keeps chunked columns of 65,536 rows (`core/crates/ffi/src/results/store.rs`), and the Windows app reads it one window at a time through `tablepro_cursor_fetch` ([0003](0003-result-windows-for-native-grids.md)). The Mac cannot reach it: the Swift module's header comes from UniFFI alone, so no `tablepro_cursor_*` function reaches Swift, and only a core session fills a store. As it stands the store also spends 17 bytes per cell on overhead and copies each batch about three times (#4522).

0003 left open whether pending edits, client sort, filter and find live in the core or in each app.

The maintainer decided on 2026-11-26 (#4559, Decisions) to move the Mac's result data path onto the core now.

## Decision

The Mac app holds every result in the core's `ResultStore` now, in a slice of its own ahead of slice 5, and its engines follow one at a time as 0010 has them. The core's store is the one result store for macOS, Windows and Linux.

The slice, numbered 10 after 0043's 6 to 8 and 0044's 9, waits for no other slice:

- **The store first.** It lands as #4522 leaves it: drivers decode into a batch builder in `tablepro-core`, fixed-width kinds sit in typed lanes with a validity bitmap, and fixed-width cells are formatted only when a window is packed. The window ABI stays as it is.
- **The Apple library links the store and its window ABI, still without the `engines` feature.** The build generates a C header for `window_abi.rs` into the `TableProFFIC` module. A Swift cursor owns a `TpCursor`, and the grid fetches the visible rows and columns, plus a margin, off the main actor.
- **The host fills it.** With no engine in the library, the host opens a store and appends batches to it. A Swift plugin feeds it through the frozen `[[PluginCellValue]]` path, converted batch by batch at the host boundary, until the plugin adopts the column-batch sink of #4523 and until its engine moves in slice 5.
- **Fetch All and Execute Without Limit stream into the store** and keep the truncated flag the read reports (#4524).
- **The app's row store goes.** `ContiguousArray<Row>` and the rows in `[[PluginCellValue]]` leave the app. Result views read windows instead of holding the buffer, and a dropped result frees O(chunks) buffers, so #4527's hand-off goes.

0003's open point is settled: pending edits, inserted rows, client sort, value filters and find live in the core.

- Edits and inserted rows sit in an overlay keyed by row id.
- Masks apply when a window is read, not in storage.
- A sort installs a permutation, the view `ResultSet::sorted` gives ([0007](0007-sorting-a-result.md)).
- Sort, value-filter distinct values, find, the inspector and display-format changes are store calls that run off the main thread and can be cancelled.

Two app rules hold with the slice:

- **The macOS 13 floor stays** (0010, The floor). `@Observable` needs macOS 14, so the per-tab invalidation of #4528, #4529 and #4531 is built by hand with `ObservableObject`: one model per tab, which publishes only when what it holds changes.
- **No app-imposed row limit.** The editor row limit stays a user setting, and Fetch All and Execute Without Limit are the user's choice to pass it. Once the store holds results, no read stops at `emergencyMax`, and the 50,000-row cut on a copied selection goes (#4531). Memory is bounded by the store's cost per cell and by one app-wide budget for results held off screen (#4556), which spills full chunks to a file and never evicts a result on screen.

## Rationale

- **The cost is in the result path, not the engines.** A driver fetch is 5 to 15 ms of a 228 to 275 ms table open (#4528); the memory, the main-thread walks and the cap all sit in how the app holds rows. Waiting for slice 5 keeps that cost until the last engine moves.
- **One home for whole-result work.** With results moving engine by engine, sort, filter, find, masks and edits would live in Swift for some engines and in the core for others until the last one moved. Settling 0003's open point in the core gives each of them one implementation, with Rust tests, off the main thread.
- **The store exists and Windows already reads it.** The window ABI does not change, so the Windows app needs no change, and the store builds without the engines, so 0010's reason for leaving them out still holds.
- **Plugins keep loading.** The frozen path stays and the column-batch sink is additive, so every plugin built before keeps working.
- **No other slice gates it.** A result keys on a session the plugin opened, not on the library, the connections or the history, so it does not wait for slices 1b to 4.
- **A cap hides a cost.** The plan fixes the cause each measurement shows (#4559). A row cap leaves the per-cell cost in place and drops data the user asked for, while a smaller store and an off-screen budget bound memory and keep every row.

## Consequences

- 0010's "What stays Swift" no longer holds a result's rows. Every engine's plugin still stays Swift until slice 5.
- `ResultStore` gains an append the host calls, outside a core session, and a read of the bytes it holds for #4556's budget.
- 0020's byte limit stays as 0020 has it. #4522 amends 0020 to charge the bytes the store keeps, and revisits there the 10,000-row default and the Windows clamp of the user's row limit to 1,000,000.
- `PluginRowLimits.emergencyMax` stays in PluginKit as a symbol, since removing a public symbol stops built plugins from loading (`.claude/rules/plugin-system.md`, ABI). Each plugin stops applying it in the release that drops its uses; a plugin built before that keeps cutting at 5,000,000 rows until it is updated.
- The sink of #4523 is a PluginKit ABI change: it sets `TABLEPRO_PLUGINKIT_VERSION` and passes `check-pluginkit-abi.sh` as additive.
- Until a plugin adopts the sink, its rows are converted once at the host boundary, a pass the frozen path cannot avoid.
- Results are not persisted, so 0010's rule that a slice keeps its Swift store readable by the previous stable release has nothing to keep here. The spill files of #4556 live in the caches directory and are no store.
- The Windows app keeps its own edit overlay over windows until it moves to the core's. The Linux grid keeps its `GridRow` slots until a change of its own moves it to the store; this ADR does not schedule either.
- The iOS app links the same XCFramework, so the store and its header reach it; when its results move is not decided here.

## Verification

The slice ships when the measures in #4521, #4522, #4524 and #4527 pass, among them:

- A 1M x 20 result on PostgreSQL and MySQL costs under 150 MB of phys_footprint, and persistent allocations per result drop to O(columns x chunks).
- A 10M-row result opens in full, and a column sort on it has no main-thread hang over 100 ms.
- Closing a tab or re-running a query that holds 1M rows runs no free over 5 ms on the main thread.
- The grid's scroll hitches on a 200-column table do not regress.
- `core.yml` builds the Apple library without the engines and runs the `TableProFFI` tests against the cursor.

## Alternatives considered

- **Keep 0010's order, results with each engine.** The memory, the main-thread walks and the cap stay until the last engine moves, and whole-result work has two homes in the meantime.
- **A compact Swift row store.** #4444 deferred it (16d), and it would be a second columnar store beside the core's, with its own sort, filter and find, and nothing the Windows and Linux apps share.
- **Lay edits, sort, filter and find over each window in the app** (0003's other option). Each app would build them again, and the Mac's would walk rows on the main thread as it does today.
- **Raise the floor to macOS 14 for `@Observable`.** It drops the users still on macOS 13 for a change the app can build by hand.
- **Keep a cap above the old one.** It moves the point where data is lost instead of removing it.
