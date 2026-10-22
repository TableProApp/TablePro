# Bounded visible cell previews, October 22

The maintainer approved limiting oversized, non-inline-editable text and JSON cell previews to 512 Unicode characters before GTK layout. The 8 KiB backing sample and full source value are unchanged. The existing byte-count suffix identifies the full source size; View Value, Copy Value and export continue to use their existing exact-value paths.

Two regressions failed before the correction: an 8 KiB Text/JsonText sample still produced an 8 KiB label, and a multibyte sample included characters beyond the chosen limit. The correction chooses a UTF-8 boundary after 512 Unicode scalar values, then applies the existing visible NUL substitution to that prefix. Binary previews and ordinary inline-editable cells are unchanged. This branch includes the preceding NUL-preview fix #1314 and should be reviewed after that dependency.

The motivation is the [stream-cache comparison in PR #1322](https://github.com/cozyGarage/BookiE/pull/1322) recorded on a separate branch under [#1032](https://github.com/cozyGarage/BookiE/issues/1032): a smaller retained window reduced memory but increased CPU; perf attributed most work to GTK text layout. Attribution to a specific UI transition is not established. All 31 non-ignored display tests, all 103 isolated GTK cases, full preflight and app all-target Clippy passed. The optimized follow-up below completed; native visual acceptance and Forgejo acceptance remain pending.

## Optimized follow-up

The [source/binary manifest](preview-manifest.json) identifies the integration candidate containing the frame, metadata, byte-budget and bounded-preview fixes. The [measurements](preview-comparison.json) cover six 50,000-row queries with 8,193-byte payloads, each followed by replacement and tab close, then 15 seconds idle. PostgreSQL 17.11, private D-Bus/Xvfb 1280×1024, Cairo and the same process-accounting helper were used. No local Cargo build/test was active. Two unrelated containers were present and sampled nearly idle before this follow-up; they were left untouched. They were absent from the earlier paired capture, so this is an additional follow-up rather than a fully controlled crossover.

| Configuration | Peak RSS | App CPU |
| --- | --- | --- |
| Earlier original baseline | 499.44 MiB | 54.12 s |
| Earlier byte budget only | 361.05 MiB | 70.74 s |
| Byte budget plus bounded preview | 276.75 MiB | 23.38 s |

All six follow-up queries reported success and the expected retained range 45001–50000, with all 50,000 rows received. Query times were 1.35–2.83 seconds. The scenario exited 0 in 84.307 seconds without a safety abort. Perf exited -2, so CPU totals use process accounting rather than perf's exit status. CPU accounting did not advance during the final 15-second idle period. After-close RSS ranged from 274.44 to 276.75 MiB. The owned PostgreSQL fixture was stopped afterward.

Relative to the earlier original baseline, sampled peak RSS was 44.59% lower and app CPU was 56.80% lower in this workload. This supports bounding visible preview layout alongside retained bytes. It does not establish statistical significance, native Wayland behavior, long-duration leak freedom or a process-memory ceiling. A repeated order-reversed comparison remains useful before making broader claims.

## Remaining routing scope

Browse grids enable long-value previews only when primary-key indices are present; RowObject::preview_long_values returns early without them. Streamed SQL results use a separate result-preview path. The 512-character limit therefore applies to preview-enabled cells, not every unkeyed table cell. Unkeyed browse layout needs a separate reproduction and safe full-value-access check before changing its path. This source distinction is recorded on #1032; it is not a measured keyless-table regression.

## Current Linux refresh

Merged Linux through `c3b2a054e`, including the accepted PostgreSQL terminal-page metadata fix and nonblocking GTK stderr capture. Full preflight and all 103 registered GTK widget tests passed again at merge head `bca4ef6876dce2bc64d00e2c0fa263d10e552f4a`. Documentation links, issue ledger and ignored-test inventory checks also passed. The owning issue remains open for the remaining resource scenarios and keyless browse coverage. Forgejo acceptance is pending; the retained-byte change must be accepted together with bounded preview layout.

## Inspector regression found during aggregate validation

The aggregate app-unit run executed 718 tests: 717 passed and the existing `long_value_inspection_shows_the_sample_and_native_byte_count` regression failed. The shared preview formatter had also shortened the row inspector sample from 8 KiB to 512 characters. The correction applies the 512-character limit at grid CellView construction and preserves the inspector formatter’s complete stored sample. The existing inspector regression is unchanged; the Unicode limit assertion now exercises grid CellView construction directly. The failed aggregate is not eligible for gating, and its manifest must be rebuilt with the corrected constituent head after validation.

After the correction, all 716 non-ignored app unit tests passed, including the unchanged inspector sample regression and the grid’s Text/JsonText and Unicode preview-limit checks. App all-target Clippy also passed. Refreshed preflight, GTK widget tests and rebuilt aggregate acceptance remain pending at this checkpoint.
