# Table-browse resource profile, October 22

## Headless SQLite profile

Source: `a070efdd235e5586185b43806f9ddbdb06e8c619`, with the local paginator-feedback change. The optimized app binary was built with Rust 1.98.1 and SHA-256 `ec9a83aa0c70e404cc00aa5062c2b5207d043fb7a177bc47c1619c83d9a9da7b`. The run used Xvfb, Cairo, a private D-Bus session and AT-SPI. It did not use the logged-in desktop display.

The GTK fixture created a SQLite table with 5,000 rows and one 16 KiB text cell per row. Its test preferences set the browse page size to 100 rows; this is smaller than the shipped default of 1,000. The full cell payload in the table was about 78.1 MiB. The app's RSS was sampled after inserting the fixture, then three seconds after opening the table.

| Measurement | Result |
| --- | ---: |
| App RSS before opening the table | 167.4–167.9 MiB across three repetitions |
| App RSS change after opening 100 rows | +16.8–21.6 MiB; median +20.8 MiB |
| Observation after opening | 3.09–3.10 s |
| Whole headless fixture command | 8.13 s wall, 1.91 s user + system CPU |

The RSS delta includes decoded cell values, grid/widget allocation and other work done while opening the browse tab. It is not an estimate of retained payload alone. The RSS figures summarize three sequential repetitions; CPU time covers one complete fixture command and is not app-only. This is not a leak test or a controlled before/after comparison. The local `gtk_safety.py` fixture uses 100 rows per page, so this does not model the default 1,000-row setting or a custom 10,000-row page.

Reproduce from the source tree with a release build and installed-path test binary:

```sh
CARGO_TARGET_DIR="$PWD/target" cargo build --release --offline --locked -p tablepro-app --bin tablepro-app
install -Dm755 target/release/tablepro-app target/installed/usr/bin/tablepro
/usr/bin/time -v env \
  TABLEPRO_PROFILE_ROWS=5000 \
  TABLEPRO_PROFILE_CELL_BYTES=16384 \
  TABLEPRO_PROFILE_OUT=/tmp/bookie-table-browse-profile.jsonl \
  TABLEPRO_GTK_SCENARIO=profile_large_result_in_the_grid \
  TABLEPRO_GTK_BINARY="$PWD/target/installed/usr/bin/tablepro" \
  bash scripts/test-gtk-safety.sh
```

## Regular query grid profile

The same release build ran a synthetic six-column SQLite query at 10,000, 50,000 and 100,000 rows, twice per size. Each run opened the result, traversed to the middle and end with 500 AT-SPI scrollbar updates per leg, then returned to the top. RSS below was measured three seconds after load and at the maximum observed during scrolling.

| Rows | RSS increase after load | Peak increase after scroll | Time to first result |
| ---: | ---: | ---: | ---: |
| 10,000 | 29.8–30.5 MiB | 32.1–32.9 MiB | 0.67–0.70 s |
| 50,000 | 53.5–55.5 MiB | 56.6–57.8 MiB | 0.90–0.92 s |
| 100,000 | 83.7–84.9 MiB | 88.9–90.0 MiB | 1.02–1.03 s |

The query completion labels reported 41–45 ms, 196–202 ms and 384–403 ms respectively. Time to first result includes GTK result presentation. These queries used SQLite, which does not exercise PostgreSQL's server cursor path. The 100,000-row result was not truncated. RSS grew with retained result size; scrolling added 2.3–5.2 MiB and did not prove a leak. The scroll timings are synthetic AT-SPI traversal, not a measure of human scrolling. CPU time was not isolated for the application.

This confirms substantial memory cost for regular query results even at 100,000 rows, while not identifying a leak or correctness defect in that path. The core result budget counts decoded value storage and is not a cap on total process RSS. A PostgreSQL-specific profile is still needed to measure cursor fetch and page retention. Docker was installed but its socket was inaccessible to this session, and no local PostgreSQL server was running.

## Truncation feedback defect

SQLite's browse fetch passes through `QueryResultBudget`; an oversized page can return fewer rows with `QueryResult::truncated` set. `BrowseTab` retained that result, but its paginator displayed only the row range and did not explain that the page had hit the byte limit. The user could see a shorter range, but not why it was shorter.

The local fix appends the existing “result truncated” notice to the paginator summary, including when the page contains no rows. Two unit regressions cover both cases. The full preflight passed: 2,055 unit tests, 2,058 sandbox tests and the Redis cancellation test. App all-target Clippy passed, as did all 106 GTK widget tests and the documentation and ignored-test inventory checks.

The fix changes only paginator text, so the measured browse data path is unchanged.

## Limits

This establishes three browse-page RSS samples and six regular-query samples on SQLite. It does not establish process-wide leak freedom, native Wayland performance, PostgreSQL behavior, or the resource cost at the shipped 1,000-row browse page size. A controlled browse profile should compare 100, 1,000 and 10,000 rows per page with the same cell-width distribution and several repetitions.
