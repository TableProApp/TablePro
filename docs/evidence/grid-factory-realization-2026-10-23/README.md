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
