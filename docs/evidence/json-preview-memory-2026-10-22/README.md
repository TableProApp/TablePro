# Parsed JSON preview allocation, October 22

PostgreSQL JSONB becomes parsed Json; ordinary JSON remains JsonText. The shared row preview path checked parsed JSON size, serialized the entire document into a String, then copied its 8 KiB prefix. This transient allocation was independent of the shorter visible grid label.

Three functional tests were added first and passed on the original code. They pin an 8 MiB source string, its exact serialized byte count and 8 KiB sample, escaped multibyte JSON and the exact preview threshold. The isolated large-value test was then traced with heaptrack. Its peak heap was 25.42 MB, including a 16.78 MB serializer allocation traced through preview_value. This confirms a temporary allocation; it is not a leaked value.

The correction keeps the existing small-document size check. Large documents serialize into a writer that retains only the first 8 KiB and counts every byte. The sample ends at a valid UTF-8 boundary. Count overflow is refused. Stored values, preview type, exact byte count, inspector sample, copy and export paths remain unchanged. Additional tests pin the writer’s retained capacity and overflow outcome.

All 12 focused row-object tests passed. The same isolated large-value test passed under heaptrack after the correction: peak heap 8.66 MB, and the filtered preview allocation was 8.19 KB. Peak RSS including instrumentation was 61.73 MB before and 63.55 MB afterward, so this trace does not establish lower process RSS. Runtime outstanding allocations reported at exit were identical; they are not classified as application leaks here. CPU comparisons are deferred because another local checkout was compiling.

The [manifest](manifest.json) records source and test-binary hashes. Raw traces and source snapshots remain in the persistent local profiling artifact directory, outside Git. Commands used the copied test binaries with the exact test name, --test-threads=1 and heaptrack --record-only, followed by heaptrack_print with allocation/temporary tables disabled. The corrected preview was also inspected with --filter-bt-function preview_value. An initial report command selected .gz, but this heaptrack version emits .zst; the report was rerun against the actual artifact.

Full app tests, preflight, app Clippy, GTK checks and Forgejo acceptance are pending at this checkpoint. This branch depends on #1330 and must be refreshed after that aggregate is accepted. The wider resource issues #1032 and #1272 remain open.

All 723 app unit tests and app all-target Clippy subsequently passed. Function-size, comment-line, formatting and documentation-link checks also passed. Refreshed preflight and the isolated GTK widget suite remain active; no acceptance or CPU/RSS improvement is inferred from those pending checks.

## Completed local validation

Full preflight, all 723 app unit tests, app all-target Clippy and all 105 isolated GTK widget tests passed. Source and binary hashes in the manifest identify the allocation trace. Forgejo acceptance remains pending after the parent resource train is accepted. The maintainer clarified that documentation-only Linux movement may retain that train’s exact runtime gate result, with explicit source and expected-tree checks recorded on #1330.
