# Grid search focus, October 23

Local validation is complete on the merged Linux head recorded in [validation.json](validation.json). The fix addresses [#1319](https://github.com/cozyGarage/BookiE/issues/1319). GitHub review and the maintainer-run Forgejo, installed-package and native Wayland gates remain pending.

## Cause and change

Accepting Jump to Column or Find in Loaded Rows attempted to focus the result grid while the search dialog was still modal. After the dialog closed, focus could remain on a toolbar control or land on selectable cell text, so keyboard navigation did not reach the selected row or column.

Both searches now share a close-time handoff. It holds weak widget references, waits until the dialog releases focus, and skips the handoff if the view is hidden or a newer focus choice has been made. The selected target is applied before grid navigation focus. Read-only cells expose a focusable GTK grid-cell wrapper whose row and column identity follows recycled cells.

This follows [ADR 0008](../../decisions/0008-connection-and-session-ownership.md) and the main-context rules. No driver, value, policy or dependency contract changed. User behavior is documented in the [SQL guide](../../user-guide.md#run-sql).

## Evidence

- The baseline executable from Linux `1a8ec3247` plus the #1471 build-script fix fails the 5,000-row search scenario at the first focused-row assertion. It reports keyboard focus on the grouping widget instead of row 1. Its binary hash and failure output are retained in the private investigation record.
- The merged-head executable passes the 5,000-row and 300-column installed GTK scenarios in light and dark appearance. Checks cover acceptance, Escape returning focus to the original row or column, Ctrl+Home/End reaching rows 1 and 5,000, exact row 2,500 selection, focused cells at columns 150/300/1, and column header/body alignment. Twelve X11 screenshots show the tested focus and scroll positions.
- Three new isolated widget tests cover close-time focus ownership, hidden views, weak view lifetime, and a 5,000-row virtualized grid. The GTK widget tier passed all 147 registered tests.
- Workspace preflight passed 386 harness checks, 2,070 unit tests, 2,082 sandbox tests and one Redis integration test. Strict app Clippy passed; app library tests passed 775 with 185 environment-gated tests ignored.

The local runtime used Arch Linux, private D-Bus/Xvfb, Cairo rendering and isolated SQLite fixtures. It was a source-built debug executable under X11, not an installed package or native Wayland run. These checks do not qualify screen-reader behavior or whole-application stability. No external database container was changed.

## Reproduction

From a source build, set `TABLEPRO_GTK_BINARY` to a private copy of the executable and run:

```bash
TABLEPRO_GTK_SCENARIO=grid_search_dialogs_return_keyboard_navigation_to_large_results bash scripts/test-gtk-safety.sh
TABLEPRO_GTK_SCENARIO=wide_result_jumps_by_keyboard_and_keeps_headers_over_their_cells bash scripts/test-gtk-safety.sh
```

Use a Python interpreter with `pyatspi`; the local matrix used `/usr/bin/python3` through `PATH=/usr/bin:/bin`. Set `ADW_DEBUG_COLOR_SCHEME=prefer-light` or `prefer-dark` and `TABLEPRO_GTK_ARTIFACT_DIR` to retain results and X11 screenshots.

## Review

The implementation received a separate self-review, not independent review. The initial parent-notify focusability attempt crashed while GTK recycled a virtualized list item; it was rejected. The regression test now exercises repeated focus changes across 5,000 virtualized rows, and the final lifecycle hook updates focusability only after mapping.
