# Spool-backed PostgreSQL result pager evidence

This packet verifies issue [#1273](https://github.com/cozyGarage/BookiE/issues/1273) after the spool-backed page reload merged in [#1660](https://github.com/cozyGarage/BookiE/pull/1660). The SQL result uses one PostgreSQL execution and 150,000 ordered rows with a 2 KiB payload per row. The pager displayed 30 pages. In both dark and light themes, the installed GTK scenario visited all pages backwards, checked each page's ordinal range and first row value, returned to row 1, and verified the transaction marker had not changed.

## Screenshots

| Theme | First page | Last page |
| --- | --- | --- |
| Dark | [Rows 1-5000](screenshots/postgres-stream-150000-prefer-dark-first-page.png) | [Rows 145001-150000](screenshots/postgres-stream-150000-prefer-dark-last-page.png) |
| Light | [Rows 1-5000](screenshots/postgres-stream-150000-prefer-light-first-page.png) | [Rows 145001-150000](screenshots/postgres-stream-150000-prefer-light-last-page.png) |

The screenshots show one result view with Previous/Next controls, not a page-tab strip. The progress notice says earlier pages can be loaded from temporary storage. At 5,000 rows, the existing [light and dark grid captures](../large-result-grid-2026-10-24/README.md) show the single-page result layout. The PostgreSQL pager's previous visual packet covers a 15,000-row stream in both themes; this packet covers a 150,000-row stream.

## Run

The scenario now defaults to the 150,000-row acceptance size; `TABLEPRO_GTK_STREAM_ROWS` can override it with a multiple of 5,000 that is at least 10,000. The screenshots in this packet were captured with the installed CI-profile binary from the merged #1660 head (`bf712c67d9b7e54cbf23664b66d851c6a8af3026`, SHA-256 `7b01573fe466c3d5354e861910c02d49380e5894f22d0646b781fe54520f1fb0`). Its stream pager and spool implementation files are unchanged through the Linux tip `636011dd8aa38b6b7ba9a17c54594c9d5247f903`.

```sh
PATH=/usr/bin:/bin:/home/trung/.cargo/bin \
TABLEPRO_GTK_BINARY=/path/to/installed/tablepro-app \
TABLEPRO_GTK_SCENARIO=postgres_large_stream_pages_round_trip_from_spool \
TABLEPRO_GTK_ARTIFACT_DIR="$PWD/docs/evidence/stream-result-pager-2026-10-25/screenshots" \
ADW_DEBUG_COLOR_SCHEME=prefer-dark \
bash scripts/test-gtk-postgres.sh
```

The final dark run passed in 42.257 seconds. The final light run passed in 41.836 seconds. Both produced `status: passed`; the most recent raw scenario result and stderr are preserved beside the screenshots. Xvfb/Cairo screenshot timing is host-specific and is not a rendering-speed claim.
