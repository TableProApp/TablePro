# Inspector preview resource investigation

Tracker: [#1370](https://github.com/cozyGarage/BookiE/issues/1370).
[Source and trace hashes](measurements.json) identify the matched builds.

## Verified mechanism and change

The single-row inspector materialized every cell before checking preview
metadata. It formatted values and then overwrote previewed fields. Text output
was already bounded, but input scanning and full row cloning still occurred;
JSON formatting can serialize the full value. The selection callback performs
this work even when the inspector sidebar is hidden.

The candidate reads existing previews first and borrows remaining cells. It
preserves field names/types, null and missing distinctions, preview byte counts
and exact stored values. Hidden widget construction is unchanged.

## Matched headless measurement

Both debug binaries use the same baseline and test. The baseline adds only the
fixture. It uses an integer key, 8 MiB text, 8 MiB binary, a null and an unfetched
cell. Eight refreshes assert preview output and intact source text. The fixture
pins existing behavior; it does not assert an allocation threshold.

| Metric | Baseline | Candidate |
| --- | ---: | ---: |
| Peak heap, MB | 33.86 | 17.08 |
| Peak RSS including Heaptrack, MB | 85.44 | 65.73 |
| Instrumented process time, seconds | 0.21 | 0.05 |

Three alternating uninstrumented pairs are in [direct measurements](direct-measurements.json).
Elapsed process time was 0.13–0.16 seconds before and 0.05–0.07 after. Peak
RSS was 76,932–78,592 KiB before and 61,340–61,560 after. These are short debug
fixture runs on a shared host, including process startup, not whole-app or
native desktop latency claims. No display or database is needed by this fixture.

Raw traces, saved binaries, reports and logs remain under
`~/bookie-test/inspector-preview/`. To reproduce the measurement, build the test
binary for each source, save it, then run `heaptrack --record-only` with
`--exact ui::row_inspector::tests::wide_row_fields_preserve_previews_nulls_missing_cells_and_source_values --test-threads=1`.
Use `heaptrack_print -f <trace>` to inspect the captured allocation report.

## Validation

The fixture passed on both versions. All three inspector unit tests pass on the
candidate. The initial branch passed full preflight, including 2,053 non-GTK
unit tests and the sandbox tier, plus 719 application unit tests and 104
isolated GTK widget tests. After merging Linux
`ad9bb1447163c848919616773ab0971c5a2d2135`, refreshed preflight passed all
2,054 tests (64 skipped), and all 105 isolated GTK widget tests passed.
App all-target Clippy, documentation links, issue ledger and ignored-test
inventory pass. Forgejo acceptance and native desktop responsiveness are not
yet checked.

## Separate lifecycle candidate

The browse selection callback retained the inspector and created an ownership
cycle through the grid. A GTK regression reproduced it, and the weak-reference
fix is under review in [#1373](https://github.com/cozyGarage/BookiE/pull/1373),
tracked by [#1333](https://github.com/cozyGarage/BookiE/issues/1333). This
preview-allocation change does not alter that graph.
