# Large-result profile, October 22

This is a historical measurement of the recorded source, not current acceptance. Later driver repairs and PostgreSQL measurements are recorded in [query row decoding budget](../../../evidence/query-row-budget-2026-10-22/README.md); later editor-scroll measurements are recorded in [editor scrolling resources](../../../evidence/editor-scroll-resources-2026-10-23/README.md).

## Setup

- Source: Linux `ad9bb1447163c848919616773ab0971c5a2d2135`.
- Release binary SHA-256: `b049aaa53235694b09ac5451f73a9fe06ba3ee376b9f7ea0a9f986c9ec9b0674`.
- GTK/AT-SPI ran under Xvfb with the Cairo renderer and an isolated D-Bus session.
- Workload: SQLite query returning 100,000 rows across six moderate-width columns. The existing GTK profile traversed the result to its midpoint, end and back to the top.

## Results

| Measurement | Result |
| --- | ---: |
| Reported query completion | 395 ms |
| First-result observation | 1.03 s |
| App RSS before query | 163.2 MiB |
| RSS after load | 245.9 MiB |
| RSS at midpoint | 248.9 MiB |
| RSS at end | 251.1 MiB |
| RSS after returning to top | 251.2 MiB |
| Visible row range at end | 99,994–100,000 |
| Scroll traversal, midpoint / end / top | 17.022 / 17.221 / 28.652 s |
| `perf stat` task clock / wall time | 60.485 / 72.737 s |

`perf stat` wrapped the Xvfb, D-Bus, accessibility test process and application. Its CPU counters are aggregate and do not attribute that task time to BookiE alone. The recorded app RSS rose about 88 MiB from the pre-query sample and stayed near 251 MiB after scrolling back. This one query and traversal did not show continued RSS growth, but does not prove leak freedom or represent larger and wider results.

The first full safety-suite attempt used the raw Cargo binary path. Two process-detection scenarios expected an installed `/usr/bin/tablepro` or `/usr/bin/bookie` path and failed before collecting measurements. The isolated profile was rerun with the release binary installed at the expected path and passed. No product source was changed for this harness setup issue.

## Reproduction

From the source base above, build the release binary and install it at a path ending in `/usr/bin/tablepro`. Then run:

```sh
TABLEPRO_GTK_SCENARIO=profile_large_result_in_the_grid \
TABLEPRO_PROFILE_ROWS=100000 \
TABLEPRO_PROFILE_SCROLL_STEPS=1000 \
TABLEPRO_PROFILE_OUT=/path/to/profile.jsonl \
TABLEPRO_GTK_BINARY=/path/to/installed/usr/bin/tablepro \
bash scripts/test-gtk-safety.sh
```
