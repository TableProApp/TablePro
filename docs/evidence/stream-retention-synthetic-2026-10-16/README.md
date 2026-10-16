# Synthetic retained-stream memory profile

Measured 2026-10-16 in a local `tablepro-app` test process. The cache, pin, row-object, and result-budget source files matched fetched Linux `9c23bc80` at measurement time.

The temporary ignored probe built four pinned results plus one active result, with four unique pages per result. Each page held one `Value::Text` of length `MAX_QUERY_RESULT_BYTES - 1,024`; `QueryResultBudget::admit` accepted every page. It then created one shared `RowObject` preview per page and dropped the result owners. The probe patch is included here for reruns. It allocates about 1.25 GiB and is not part of the normal test suite.

Apply `profile-probe.patch`, run the command from the repository root, then apply the patch in reverse:

```sh
git apply docs/evidence/stream-retention-synthetic-2026-10-16/profile-probe.patch
cargo test --locked -p tablepro-app --lib profile_maximum_stream_and_pin_retention -- --ignored --nocapture
git apply -R docs/evidence/stream-retention-synthetic-2026-10-16/profile-probe.patch
```

The measured resident set and ownership result were:

```text
baseline_rss_mib=38
four_pins_rss_mib=1067
four_pins_plus_active_rss_mib=1323
twenty_visible_previews_rss_mib=1325
live_pages_after_owners_drop=0
```

The requested text payload across 20 pages is 1,342,156,800 bytes (1,279.98 MiB). RSS rose by 1,285 MiB with four pins and one active stream, and 1,287 MiB after the 20 previews. The preview objects used weak references to their source results; all 20 source pages were released after the result owners dropped.

This is a configured-page stress case, not a normal workload or a process-memory ceiling. It did not include database wire buffers, a real PostgreSQL cursor, other editor tabs, full GTK cell rendering, export, or cancellation overlap. The result supports profiling and budgeting the full lifecycle under #554; it does not choose a production budget.
