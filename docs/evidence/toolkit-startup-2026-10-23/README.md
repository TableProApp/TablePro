# Toolkit startup ordering, October 23

Status: [#1468](https://github.com/cozyGarage/BookiE/pull/1468) merged; [#1465](https://github.com/cozyGarage/BookiE/issues/1465) is closed. Local validation passed on the exact PR head `65b9fb85f2739c3fa21c9450fb82150a099d0450`. Hosted checks, Forgejo and installed-package acceptance are separate results.

## Cause and regression

Linux `e483fe07b` reads libadwaita versions before GTK initialization. The Rust binding requires initialization, so production startup panics before opening a window. The initial fresh-process regression reproduces this in [before.log](before.log).

The fix initializes GTK before reading toolkit versions, preserves the version floors and reports an unavailable display explicitly. The positive regression invokes production startup, waits for a mapped main window, then quits through the application loop. It passes in [after.log](after.log). Test builds provide clean application arguments so GTK does not parse Rust test-runner options; production arguments are unchanged.

## Validation

The [final record](validation.json) pins the tested head and commands. Preflight passed 383 harness tests, 2,070 unit tests, 2,077 sandbox tests and the Redis cancellation test. Strict app Clippy passed. All 144 registered isolated GTK tests passed, including startup and the narrow-toolbar regression. Logs: [preflight](final-preflight.log.gz), [Clippy](final-clippy.log.gz), [GTK widgets](final-widgets.log.gz). The [manifest](manifest.json) records source and artifact hashes.

The [initial run](initial-validation.json) stopped at the unchanged narrow-toolbar test, which requested 616 px at a 600 px large-text width. Its [failure log](widget-failure.log) is historical. Linux separately fixed it in [#1466](https://github.com/cozyGarage/BookiE/pull/1466); the successful combined run includes that fix. No assertion was weakened.

## Scope

Arch Linux, source-built debug tests, private D-Bus/Xvfb, Cairo rendering and isolated configuration. These results do not establish native Wayland, installed-package or Forgejo acceptance. Linux subsequently also merged the independent storage change in #1467; this packet does not claim to validate that change. Review was a separate self-review, not independent review.
