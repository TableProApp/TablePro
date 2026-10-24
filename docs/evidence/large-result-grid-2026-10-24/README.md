# Large result grid evidence

This run records the installed GTK application's ordinary SQLite result grid at 5,000 and 150,000 rows in light and dark color schemes. The checkout was `a82c1ad2c462404ac8510fc8adc0ea941ab3970b`; the GTK toolkits were GTK 4.24.1, libadwaita 1.10.0 and GtkSourceView 5.22.0. The CI-profile executable was built from this checkout with `scripts/gtk-test-binary.sh` and Rust 1.98.

The four scenarios passed `profile_large_result_in_the_grid`. Each one captured the start, middle, end and return-to-start row ranges. The visible ranges were correct for both sizes. Peak resident memory was about 196–211 MiB at 5,000 rows and 258–259 MiB at 150,000 rows, including the application baseline of about 165 MiB. The 150,000-row results appeared in 1.33–1.41 seconds. Scroll traversal took 25–74 seconds under Xvfb/Cairo; this varies with host load and is not a native-rendering latency result.

A separate PostgreSQL GTK scenario created 15,000 rows with 4,500-byte payloads. It passed in 5.1 seconds in light mode and 5.2 seconds in dark mode. Each run showed three received pages and the retained range `5001-15000`, displayed `Rows 10001-15000`, navigated to `Rows 5001-10000`, then returned to the last page. The screenshots show the pager and retained-range notice:

- [Light, last retained page](screenshots/postgres-stream-prefer-light-retained-last-page.png)
- [Light, previous retained page](screenshots/postgres-stream-prefer-light-retained-previous-page.png)
- [Dark, last retained page](screenshots/postgres-stream-prefer-dark-retained-last-page.png)
- [Dark, previous retained page](screenshots/postgres-stream-prefer-dark-retained-previous-page.png)

| Scheme | Rows | Peak RSS | First result | Screenshot |
| --- | ---: | ---: | ---: | --- |
| Light | 5,000 | 210.7 MiB | 0.66 s | [grid](screenshots/large-result-grid-prefer-light-5000.png) |
| Dark | 5,000 | 196.2 MiB | 0.79 s | [grid](screenshots/large-result-grid-prefer-dark-5000.png) |
| Light | 150,000 | 259.1 MiB | 1.33 s | [grid](screenshots/large-result-grid-prefer-light-150000.png) |
| Dark | 150,000 | 258.0 MiB | 1.41 s | [grid](screenshots/large-result-grid-prefer-dark-150000.png) |

Raw RSS and row-range samples are in the matching `profile-*.jsonl` files. The test and screenshots can be reproduced from this checkout with:

```sh
TABLEPRO_GTK_BINARY=/path/to/target/installed-ci/usr/bin/tablepro \
  bash docs/evidence/large-result-grid-2026-10-24/run.sh
```

The PostgreSQL pager scenario is reproducible with (set `ADW_DEBUG_COLOR_SCHEME=prefer-dark` for dark captures):

```sh
TABLEPRO_GTK_SCENARIO=postgres_large_stream_pages_show_retained_range_and_navigate \
TABLEPRO_GTK_ARTIFACT_DIR="$PWD/docs/evidence/large-result-grid-2026-10-24/screenshots" \
  bash scripts/test-gtk-postgres.sh
```

The SQLite profiling measurements do not exercise streamed cursor paging or the retained-row notice. The PostgreSQL scenario covers those behaviors under Xvfb. Native Wayland and high-DPI checks remain open.
