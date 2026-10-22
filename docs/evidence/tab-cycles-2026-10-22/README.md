# Repeated editor close cycles, 2026-10-22

Related: [#1333](https://github.com/cozyGarage/BookiE/issues/1333), [#1336](https://github.com/cozyGarage/BookiE/pull/1336).

Six isolated Xvfb cycles opened four editor tabs, executed a small local SQLite query in each, closed all four, and clicked the allocated empty-state Open SQL editor button using an X11 pointer event. Each reopening exposed Run again. A final query also completed. The [scenario result](repeated_editor_close_cycles-result.json) passed. This does not reproduce the reported native transient freeze or identify its cause.

[Samples](samples.json) record process RSS and high-water RSS. Initial RSS was 164,772 KiB; after the first close cycle it was 182,496 KiB; after six close cycles it was 187,936 KiB; final RSS after reopening, querying and three seconds idle was 187,940 KiB. Later close cycles continue to increase RSS. This is an observation requiring allocation/lifetime tracing, not proof of a leak. GTK caches, allocator retention and application state have not been separated.

The optimized saved binary predates the branding and packaging merges. Its source identity and checksum are in the [manifest](manifest.json). This is a candidate measurement, not an installed 0.2.0 release claim. The [reproducer](reproduce.py) imports the repository GTK safety harness, uses fixture-only data and an isolated session bus, and stores raw artifacts under the local test directory. It must run inside Xvfb with the harness prerequisites and the saved binary supplied as its first argument. Do not run it against the native desktop.

No CPU benchmark was taken. No native screenshot or desktop input was used. The application and its isolated display exited after the scenario. More cycles and Heaptrack are required to determine whether growth plateaus and which objects remain.
