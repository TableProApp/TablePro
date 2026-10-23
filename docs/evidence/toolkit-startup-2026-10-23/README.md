# Toolkit startup ordering, October 23

Status: focused startup regression, preflight and strict app Clippy pass locally. The initial full widget suite stopped at a narrow-toolbar regression; current-Linux validation is running after its separate fix in #1466; GitHub, Forgejo and installed-package acceptance are pending. Refs [#1465](https://github.com/cozyGarage/BookiE/issues/1465).

Linux `e483fe07b` reads libadwaita versions before GTK initialization. The Rust binding requires GTK initialization, so production startup panics before opening a window. The 300-column installed-GTK harness reached this failure before any scenario actions.

The initial fresh-process regression calls production startup. It fails on the original code with the initialization assertion, as recorded in [before.log](before.log). The fix initializes GTK before reading library versions, preserves the version floors and reports an unavailable display as a startup failure.

The positive regression was strengthened to wait for a mapped main window, quit from the application loop and assert that the window was observed. This regression passes, as recorded in [after.log](after.log). Test builds provide clean application arguments so GTK does not parse the Rust test runner options.

The test runs under private D-Bus and Xvfb with Cairo rendering and isolated configuration. Source-built evidence does not establish native Wayland, packaging or Forgejo acceptance. Review is a separate self-review, not independent review.

## Broader local validation

Preflight passed 379 harness tests, 2,070 unit tests, 2,077 sandbox tests and the Redis cancellation test. App Clippy passed with warnings denied. The widget suite stopped at `editor_actions_fit_narrow_rows_with_running_and_retry_controls`: the toolbar requests 616 px at a 600 px large-text width. That test constructs its editor directly and does not call the changed startup path. Its assertion is preserved; [#1461](https://github.com/cozyGarage/BookiE/pull/1461) already contains the Session-button shrinking correction. This packet does not claim a green full widget suite.

Linux subsequently merged [#1466](https://github.com/cozyGarage/BookiE/pull/1466), the existing Session-button correction. The startup branch includes that newer Linux head; the recorded widget failure belongs to the earlier base and is not attributed to the startup change. Combined-head validation is pending.
