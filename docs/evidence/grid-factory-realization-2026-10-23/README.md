# Grid factory realization measurement

Source: Linux `3723e7e0ed78ce2a990e85bb53fc903e4b606dc3`. GTK 4.24.1, libadwaita 1.10.0, GtkSourceView 5.22.0. Unoptimized Cargo test binary, Xvfb 1920 by 1200, Cairo renderer. No database connection or desktop unlock was needed.

Test-only counters were attached to the actual column factory setup and bind callbacks. A synthetic result contained 100 rows of short text, with 16, 64 or 256 columns, inside an application grid with menus. Each grid was presented for at least two seconds at window sizes 800 by 600 and 1600 by 1000. The six-case test completed successfully.

| Columns | Setup calls | Bind calls | Window sizes |
| --- | --- | --- | --- |
| 16 | 1,600 | 1,600 | Both |
| 64 | 6,400 | 6,400 | Both |
| 256 | 25,600 | 25,600 | Both |

Every column received 100 setup and bind calls in this workload. The smaller viewport did not reduce construction. This establishes substantial initial factory work for the measured application path. It does not prove all cell widgets remain live, whether GTK recycled any widgets later, general behavior for larger row counts, or that horizontal virtualization alone would eliminate the cost. Counts include initialization and layout, not only final visible cells. No timing or memory comparison is claimed.

The instrumentation patch and test source are stored here as experimental artifacts, not compiled product code. Reproduce in an isolated checkout of the source commit: apply instrumentation.patch, copy factory_probe.rs.txt to apps/linux/app/src/ui/grid/factory_probe.rs, then run the exact test ui::grid::factory_probe::profile_factory_realization with cargo test -p tablepro-app --lib under isolated Xvfb, using --ignored --exact --nocapture --test-threads=1. Set GDK_BACKEND=x11, GSK_RENDERER=cairo and isolated XDG directories. Results are in results.json.

Next distinguish transient measurement/setup from retained widgets: capture setup, bind, unbind and teardown with live and maximum-live counters; compare short and long row counts, scroll vertically and horizontally, and compare the editor grid to this standalone harness. Preserve keyboard interaction, selection, editing, copy/export and accessibility before changing presentation. Related work: [#1315](https://github.com/cozyGarage/BookiE/issues/1315).

## Lifecycle follow-up

A second six-case run added unbind and teardown counters and explicitly detached the model and dropped the test windows. All cases completed. While open, every case had zero unbinds and teardowns after the settling interval. After closure, every setup had a matching teardown and every bind a matching unbind, including all 25,600 cells for 256 columns at both window sizes. This supports substantial simultaneously retained factory-item setup in the measured open grid, followed by balanced factory lifecycle cleanup. It does not prove that every related allocation is freed, editor-tab teardown is equivalent, or that the complete application has no leaks.

Exact follow-up source and results are stored in lifecycle-instrumentation.patch, lifecycle-probe.rs.txt and lifecycle-results.json. Reproduce as above using those follow-up artifacts. The counters measure factory events rather than byte ownership; a separate heap profile is still required for memory attribution.

## Larger row counts and vertical bounds

A follow-up at 64 columns and an 800 by 600 window compared 100, 500 and 2,000 source rows. The 100-row grid realized 6,400 cells. Both larger inputs realized 13,120 cells, exactly 205 per column, with no unbind/teardown before closing. Every bind/setup again balanced with unbind/teardown after closing. The test passed. Exact results and test source are in larger-row-results.json and larger-row-probe.rs.txt; use lifecycle-instrumentation.patch for its callbacks.

This shows bounded vertical realization in the measured initial layout. It contradicts an inference that the grid creates widgets for every row of an arbitrarily large result. It also shows the wide-column multiplier: the prefetched row window is constructed for every column, even at a narrow viewport. Scrolling and the actual editor layout remain unmeasured here.

The supported [GTK 4.24.1 list-view source](https://github.com/GNOME/gtk/blob/4.24.1/gtk/gtklistview.c) sets a 200-item anchor maximum with extra tracked items. The [ColumnView implementation](https://github.com/GNOME/gtk/blob/4.24.1/gtk/gtkcolumnview.c) derives its internal column list view from GtkListView. This is consistent with bounded realization, but the observed 205 is a measurement of this case, not a public API guarantee.
