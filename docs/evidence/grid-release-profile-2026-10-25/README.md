# Release grid profile, October 25, 2026

This profile measures large text cells and a wide SQL result on the current Linux source. CPU timing and Heaptrack allocation capture used separate, fresh application processes. The build and synthetic SQLite workloads are identified in [build.json](build.json) and [measurements.json](measurements.json). The [probe](probe.py) reproduces the GTK scenarios. Run it with the system Python from a private D-Bus/Xvfb session like `scripts/test-gtk-safety.sh`, setting `TABLEPRO_PROFILE_REPO`, `TABLEPRO_PROFILE_OUT`, `TABLEPRO_GTK_SCENARIO`, and `TABLEPRO_TEST_MCP_HTTP_PORT`, then pass `target/release/tablepro-app` as its argument. Set `TABLEPRO_PROFILE_HEAP_RAW` for a separate allocation capture. Build the binary with the command recorded in `build.json` first.

## Results

The 8 MiB text result reached its accessible header in 0.98 seconds wall and 0.98 seconds application CPU, with a 22.83 MiB RSS increase. The keyless table browse path displayed 10,023 characters from the same 8 MiB cell in 0.50 seconds wall and 0.46 seconds CPU. A 16 MiB keyless cell displayed 10,024 characters in 0.48 seconds wall and 0.46 seconds CPU. These are single samples; the CPU interval includes query or table-open work and GTK accessibility observation.

For a 100-row result with 257 columns, three uninstrumented fresh-process runs measured 8.67–8.78 seconds wall and 9.00–9.10 seconds application CPU from query start until the last column header appeared. The median RSS increase was 396.45 MiB and median PSS increase was 396.05 MiB. This is a synthetic SQLite result on a local Arch host, not a PostgreSQL or packaged-app benchmark.

## Allocation capture

Heaptrack ran separately from the CPU samples on the same optimized source and workloads. The 8 MiB text result produced 3,112,580 allocation calls, 399,208 temporary allocations and 62.81 MiB peak tracked heap. The 257-column result produced 19,832,688 allocation calls, 2,052,305 temporary allocations and 390.53 MiB peak tracked heap. Heaptrack added substantial runtime overhead; these timings are excluded from CPU comparisons. Its peak includes application startup and the result left open at process exit. Reported outstanding memory is not a leak finding.

The wide-grid allocation stacks repeatedly pass through `setup_readonly_cell`, GTK label construction and result-grid construction. The capture contains 25,700 result cells. This confirms that the remaining wide-grid cost is dominated by GTK cell setup and grid construction after the existing shared menu-controller work. It does not identify an exclusive owner for all GTK allocations.

## Existing contracts

Current source keeps the full values behind bounded previews. [`copying_a_previewed_cell_copies_the_full_value`](../../../apps/linux/app/src/ui/grid/context_menu_tests.rs) checks clipboard input, and [`arbitrary_query_previews_can_recover_full_values_from_the_shared_result`](../../../apps/linux/app/src/ui/row_store.rs) checks that text, bytes and JSON remain available intact through the shared result. [`a_dropped_result_grid_releases_its_page`](../../../apps/linux/app/src/ui/grid/lifetime_tests.rs) checks that dropping a result grid releases the page reference. The isolated GTK widget tier passed all 165 tests on this source head, including the copy and dropped-grid tests. The current tests do not directly assert that `export_snapshot` exports the original value after preview creation; the release path uses `complete_row_at` and `RowObject::complete_cells`, which the shared-result test covers separately.

The keyless browse path has no primary-key indices, so it skips `RowObject`'s 8 KiB preview cache and goes through [`truncate_for_display`](../../../apps/linux/app/src/ui/grid/display.rs). That function bounds the label to 10,000 characters, but computes an exact remaining-character count by scanning the suffix. The measured 8 MiB and 16 MiB cases did not show a material delay in this fixture. The implementation still performs work proportional to the cell length, so the issue's strict no-full-scan criterion remains open. `display.rs` is also being changed by [PR #1625](https://github.com/cozyGarage/BookiE/pull/1625); any follow-up must account for that ownership before editing it.

## Limits

- The wide-grid timing covers one synthetic data shape and three runs. It is not a cross-engine or native-Wayland result.
- The large-cell CPU samples are single runs; the elapsed interval includes query or browse work and accessibility polling.
- Heaptrack traces include startup, toolkit allocations and a result left open at process exit. They establish peak tracked allocation, not leaks or post-close retention.
- No behavior change is proposed from this profile alone. The remaining wide-grid cost needs a focused GTK ownership/virtualization design, preserving keyboard, pointer, editing, selection and accessibility behavior.
