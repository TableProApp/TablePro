# 0003: The core owns the result set, and a native grid pulls windows of text

- **Status**: Accepted; amended by 0007; the row limit as the bound on memory superseded by 0020
- **Date**: 2026-11-02

## Context

Each app keeps its own grid: an `NSTableView` on macOS, GtkColumnView on Linux ([Linux ADR 0027](../../../linux/docs/decisions/0027-one-data-grid.md)), and a WinUI 3 control on Windows. With one core running every query, rows have to cross FFI to C# and Swift fast enough for a million rows while more are still arriving.

Neither app streams rows into its grid today, and both cap results. macOS keeps 10,000 rows by default (100 to 500,000, or none) as arrays of `PluginCellValue`, and formats them on the main actor. Linux keeps 10,000 rows per statement and 100,000 per run as `Vec<Arc<[Value]>>`, with a 32-byte `Value`, and shows a batch only when its statement ends.

A spike on 2026-11-02 measured three ways across FFI on an Apple M4 Pro with macOS 27.0.1: Rust 1.98.1 with arrow 60.1.0, .NET 10.0.402 with Apache.Arrow 23.0.0, and Swift 6.4 built with `-O -wmo`. The data was 1,000,000 synthetic rows of 20 columns with nulls, `Decimal128(38,10)` values over 28 digits, dates outside years 1 to 9999, long mixed-script text, JSON and binary.

- (a) The core packs one window of display text per call.
- (b) The core exports Arrow C Data and the UI formats every value.
- (c) The UI calls the core once per cell.

## Decision

The core keeps each result set in columnar memory and formats exact, locale-free text, and a grid pulls one packed UTF-8 window per visible range, learns of new rows from one coalesced callback, and adds locale and styling itself.

## Rationale

- **Speed does not decide.** A 50 x 20 window made into native strings costs 63 to 76 us at p50 on .NET and Swift for (a), for (c), and for (b) with .NET formatters. That is under 1% of an 8.3 ms frame.
- **Correctness does.** When the UI formatted typed values itself, values changed:
  - .NET `Decimal128Array.GetValue` rounded 636 of 62,290 `Decimal(38,10)` values, so `2553875341786898348777948.6813196487` became `...948.6813`. `System.Decimal` overflows at 1e29.
  - .NET `DateOnly` cannot hold a date outside years 1 to 9999: 1,708 failures in 20,000 windows.
  - Foundation `DateFormatter` rounded microseconds to milliseconds in 23,776 of 25,000 timestamp cells (`07:23:02.304865` became `07:23:02.305000`), and printed a BC date without its era and four days off.
- **One snapshot.** (a) reads rows and the row count under one read lock per window. (c) takes 1,000 lock round trips per window and gives no snapshot.
- **Columnar memory.** Arrow chunks of 65,536 rows held 1M rows in 820 MiB, 6.9% over the 767 MiB payload. The Linux row shape held the same rows in 1,570 MiB, 104.5% over.
- **UTF-8 on every platform.** It suits Swift `String` and GTK. UTF-16 is cheaper for .NET to read, but Rust's `encode_utf16` made the pack 28 us slower than .NET saved (79.3 against 66.1 us in all).

The formatting split:

- **Core:** integers, exact decimals, floats as the shortest round trip, ISO dates and timestamps with era and offset, booleans and UUIDs. Text and JSON are cut at a character boundary at a cap, with control characters made spaces so a cell is one line. Binary is `0x` hex of the leading bytes. Each cell also carries a null flag, a truncated flag and a `raw` integer: the value, the timestamp in microseconds, the day number or the full byte length.
- **UI:** anything with words or locale. The NULL placeholder, byte counts, the ellipsis, alignment, colours and fonts. Locale dates and number grouping, when the user picks them, come from `raw` or the core's exact decimal text, and fall back to the core's text when the platform type cannot hold the value. The OS keeps the user's regional overrides this way.
- The full value for the detail pane, the editor and copy comes from a separate call. A window carries display text only.

## Consequences

- One window call takes a cursor, the first row and row count, the first column and column count, and a character cap. It returns a type tag per column, a null bitmap, a truncated bitmap, `raw` per cell, `n_cells + 1` offsets and the UTF-8 bytes, column by column. The buffers stay valid until the cursor's next fetch, and each UI thread has its own cursor. The column range keeps column virtualization open.
- Rows arrive at wire speed into the core's store, not at the grid's pace as `ResultSink` takes them today. The row limit bounds memory.
- After an append, the core calls the UI's callback only when no wake is pending. The UI moves to its main thread, acknowledges, then reads the row count, so no append is lost. A final call marks the end. In the product the callback means "events pending", and the UI drains typed events (set started, columns resolved, rows, finished, notice, error) with one pull call.
- Arrow C Data export stays for bulk readers: export, charts and a later ADBC path. The window call does not expose Arrow, so the store can change without touching any UI.
- Linux calls the same Rust API directly and reads `&str` without FFI. Its grid holds one `GridRow` GObject per row today. A million of them was not measured, and a lazy `GListModel` sized by the row count is the likely change.
- Open:
  - 7 of the 22 `Value` variants need a columnar form: `Interval`, `Array`, `WideInt`, `Bits`, `TimeTz`, `Other` and `Undecodable`. A text column with a kind tag is the fallback.
  - Pending edits, client sort, filter and find live in each app today. Either that state moves into the core, or the UI lays it over each window. Not designed yet.
  - Streamed 1,000-row chunks cost 8% more memory (886.9 against 820.1 MiB) until they are compacted, and compaction is not built. Arrow builders grow by doubling, so buffers shrink once a chunk is built: 1,157.8 MiB was requested before shrinking.
- arrow 60.1.0 brings 27 crates. The spike's library was 785 KB.

## Alternatives considered

- **(b) Arrow C Data to the UI.** The transport costs 5.5 to 7 us per window, but each language formats on its own and the values above changed. Swift with Foundation formatters took 444 to 458 us per window and 9.5 to 14 s to scroll through 1M rows.
- **(c) A call per cell.** As fast as (a) at p50, but 1,000 lock round trips per window and no snapshot.
- **UTF-16 windows for .NET.** Slower in all today. A SIMD transcoder in the core might change that; not measured.
- **The Linux row shape in the core.** Twice the memory of the columnar store.
- **Locale formatting in the core with a CLDR library.** It would not see the user's OS regional overrides (unverified, from how `CultureInfo` and `Locale.current` behave).

## Measurements

One visible window of 50 rows x 20 columns at random rows over 1M, 20,000 windows, including making every non-null cell a native string. p50 values agreed across two runs within 10 to 20%. The machine was loaded (load average 8 to 37, swap in use), so p99 is an upper bound.

| Path | p50 us | p99 us |
|---|---|---|
| Core only, (a) UTF-8 pack | 32.5 | 67.9 |
| Core only, (b) Arrow slice export and release | 5.5 | 8.5 |
| .NET, (a) UTF-8 to `string` | 66.1 | 308.6 |
| .NET, (a) UTF-16 to `string` | 79.3 | 250.9 |
| .NET, (c) `LibraryImport` per cell | 68.5 | 219.4 |
| .NET, (b) slice, import and .NET formatting | 76.2 | 323.4 |
| Swift, (a) UTF-8 to `String` | 69.5 | 331.8 |
| Swift, (a) UTF-8 to `NSString` | 143.8 | 526.0 |
| Swift, (c) per cell to `String` | 73.1 | 310.6 |
| Swift, (b) slice and Foundation formatting | 457.5 | 2933.0 |

Scrolling through all 1M rows as 20,000 windows took 1.42 s on .NET (a) and 1.34 s on Swift (a), against 0.56 s in the core alone. A window carried 45,217 UTF-8 bytes on average at a 1,000-character cap, and .NET allocated 111,310 bytes of managed memory per window for (a).

Streaming 1M rows in batches of 1,000:

| | .NET, stand-in UI thread | Swift, main queue |
|---|---|---|
| Wakes for 1,000 batches | 989 | 1,001 |
| Core publish to UI thread, p50 / p99 | 13.2 / 2229.4 us | 15.2 / 269.6 us |
| Random window while appending, p50 | 82.3 us | 102.3 us |

With the UI thread busy 8 ms per wake, 1,000 batches gave 196 wakes and every row showed.
