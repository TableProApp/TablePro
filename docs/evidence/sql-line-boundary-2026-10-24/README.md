# SQL file line-layout boundary

Related: [#1299](https://github.com/cozyGarage/BookiE/issues/1299). Historical heap attribution in the [release qualification](../release-0.2.0-2026-10-21/README.md) isolated the GiB-scale single-line allocation to GTK/Pango/HarfBuzz rather than database execution.

## Calibration

The [bounded standalone probe](probe-widget.py) renders a SQL comment line under private Xvfb/Cairo, SQL syntax highlighting and GtkSourceView. [Samples](calibration.json) record peak RSS and 100 ms event-loop heartbeats.

| UTF-8 line bytes | Content | Peak RSS | First heartbeat | Maximum subsequent gap |
| --- | --- | --- | --- | --- |
| 65,536 | ASCII | 128.9 MiB | 100 ms | 101 ms |
| 262,144 | ASCII | 166.0 MiB | 109 ms | 100 ms |
| 1,048,576 | ASCII | 312.3 MiB | 445 ms | 261 ms |
| 262,142 | Emoji | 131.7 MiB | 100 ms | 102 ms |

These short synthetic measurements support a conservative 256 KiB physical-line admission limit for SQL files. They are not a universal safe memory ceiling or native desktop qualification. Probe construction precedes heartbeat scheduling, so the first heartbeat excludes initial buffer construction. Each probe uses a fresh process.

## Regression and behavior

Two file-reader regressions failed before the fix: chooser/restoration admission and dropped-file admission both accepted an overlong line. All nine file tests pass afterward. Coverage preserves exact UTF-8 and CRLF content at the boundary, an 8 MiB file with short lines, invalid UTF-8 refusal, oversized-file refusal and exact saving of an existing overlong editor draft.

The file reader and dropped-file reader share line validation before passing the file content to GTK. The user sees the offending line number and instructions to split it externally. Saving existing editor contents remains available to avoid losing work.

## Installed application

The [build identity](build.json) identifies the development executable built from the recorded base plus this uncommitted fix. The registered installed scenario opens an 8 MiB single-line file through the file chooser, requires a refusal, verifies unchanged editor text and tab count, checks the file byte-for-byte, and runs a sentinel query afterward.

Three repeated refusals passed without retries in a 14.936-second scenario. [Owned-process samples](refusal-cycles.json) show chooser-to-refusal durations of 1.028, 0.897 and 0.849 seconds. Peak RSS reached 230.1 MiB. RSS rose from about 203 MiB before the first cycle to 230 MiB after the third; this short run does not establish leak freedom, a plateau or allocator ownership. The historical GiB-scale layout allocation did not occur.

## Limits and remaining work

This is a file-loading mitigation. It does not bound paste, programmatic buffer updates or restored drafts. The file-size and line checks do not claim a process-wide resource ceiling. Native Wayland, prolonged editing and general long-line editing remain unverified. Keep #1299 open for those paths.

Full preflight passed (2,075 unit tests, 2,088 sandbox tests and the separate Redis check), strict application Clippy passed, and all 158 isolated GTK tests passed. Remote Forgejo acceptance is pending. No resource limit or guardrail test was weakened.


## Dropped-file concatenation follow-up

Three additional regressions failed before the follow-up: two individually admissible lines formed an overlong line, cumulative drops exceeded the total editor budget, and invalid UTF-8 byte cursor positions were admitted. All twelve file/drop tests pass with post-insertion validation. The complete candidate text is checked before any buffer mutation; the existing file reader still bounds the incoming file separately.

The registered isolated GTK regression requires a rejected insertion to leave both editor text and cursor unchanged. An accepted Unicode insertion must preserve exact text and undo in one action. It passed under fatal GTK criticals. The [updated inventory](ignored-test-inventory.txt) records its registration. Strict application Clippy passed. Full follow-up preflight passed again (2,075 unit tests, 2,088 sandbox tests and the separate Redis check), and all 159 isolated GTK tests passed. Forgejo acceptance remains pending.

This follow-up changes drop admission only. It does not intercept arbitrary paste or truncate persisted drafts.
