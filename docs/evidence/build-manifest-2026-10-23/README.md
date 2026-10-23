# Build-script manifest ownership, October 23

Status: focused regressions, real resource build, preflight, strict app Clippy and documentation checks pass locally. Hosted acceptance remains pending. Refs [#1470](https://github.com/cozyGarage/BookiE/issues/1470).

The GUI build script captured its manifest directory when compiled. Reusing that executable in another checkout could compile the earlier checkout’s schemas, or fail after that checkout was removed. This occurred after completed worktree cleanup on Linux `1a8ec3247`.

The script now reads Cargo’s manifest directory when it executes, preserving native path handling and returning an error when the runtime variable is missing. Schema and GResource contents are unchanged.

Three harness tests compile the production script for checkout A and execute it for checkout B, whose path contains a space. They inspect compiled schema output, repeat after removing A, and reject missing runtime input. All three fail [before the fix](before.txt) and pass [after it](after.txt). The [manifest](manifest.json) records source and log digests. The fixture substitutes the external schema compiler and resource helper; a real locked GUI build also passes with installed GLib tooling and the shared target cache that reproduced the defect. No GTK widget or driver behavior changed.

The script harness discovers these tests automatically. Review is a separate self-review, not independent review. Hosted CI, Forgejo and installed-package acceptance remain separate.

Preflight passed 386 harness tests, 2,070 unit tests, 2,082 sandbox tests and the Redis cancellation test. See the [validation record](validation.json) and [compressed preflight log](preflight.log.gz).

[Strict app Clippy](clippy.txt) passed with warnings denied. Runtime widget behavior and resource contents are unchanged; the widget suite was not rerun for this build-script-only change. No dependency changed.
