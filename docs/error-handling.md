# Error handling

Two error styles, applied per layer. Mixing them is a review red flag.

## Rule

| Layer | Error type | Why |
|---|---|---|
| `core` (traits, contracts) | `thiserror` enums | Stable variants; consumers match on them. |
| `core::DriverError`, `storage::StorageError` | `thiserror` enums | Cross crate boundaries; need exhaustive matching. |
| `drivers/<engine>` | `thiserror` enum mapping the underlying crate's error into `core::DriverError` | Underlying crate's errors do not leak. |
| `storage` (internal) | `thiserror` enum, `StorageError` | Same reasoning. |
| `app` (UI handlers, services, internal glue) | `anyhow::Result` | Composition. Errors are mostly displayed and dropped. |
| Tests | `anyhow::Result` or `?` against domain errors | Whatever is shortest. |

`anyhow` is fine for a function that wraps several different error sources and forwards them to a UI dialog or a log line. It is wrong for a public API that callers must reason about.

## `thiserror` patterns

Use the actual [DriverError](../crates/core/src/error.rs) and
[StorageError](../crates/storage/src/error.rs) variants. Keep examples from
becoming a second enum definition that omits cancellation/unknown outcomes.

Rules:

- Variants are stable. Once shipped, do not rename or remove. Add new variants at the end.
- Avoid wrapping arbitrary `Box<dyn Error>` inside variants. Map underlying errors into specific variants. The `Internal(String)` variant is the escape hatch for cases that genuinely cannot be classified. Use it sparingly.
- The `#[error]` message is for logs and developer-facing surfaces. The UI builds its own message based on the variant.

## Driver-side error mapping

Map underlying errors into the existing domain variants. Follow the production
mapping for the affected driver rather than copying a generic SQLx example;
connect refusal, established loss, authentication and certificate failure have
different meanings. Keep native negative controls in the owning driver tier.

The driver does not pass through `sqlx::Error` to callers. Callers see only `DriverError`.

Certificate verification failures reach sqlx as I/O errors, so the PostgreSQL driver walks the error chain and reports a hostname or authority mismatch as `DriverError::Tls`. Reporting them as `Internal` would tell the user "internal driver error" for a wrong hostname or an untrusted CA.

## UI display

`app` translates domain errors into recovery messages in
[error_text](../crates/app/src/ui/error_text.rs). Preserve typed categories
through assembly and wrappers before selecting the user-facing message.

Do not display raw `Debug` or `Display` output for domain errors. Always go through this layer.

## Logging

Use the `tracing` crate. `app::logging::init` installs a `tracing_subscriber` formatter that writes to stderr; the GNOME session journals that for both Flatpak and system installs, so panics and logs interleave in order without a journald writer. `RUST_LOG` overrides the per-profile default level. Levels:

- `error!`: something the user must see, or a contract was violated.
- `warn!`: recoverable but suspicious.
- `info!`: significant lifecycle events such as app start, driver registration, or a connection opening.
- `debug!`: verbose internal flow.
- `trace!`: structural diagnostics and timings. Off by default; the same privacy rules apply.

Never log passwords, secret tokens, connection strings, SQL text, query parameters, or unmasked results at any level. Dependency panic payloads and raw network frames can contain the same data; do not treat them as safe diagnostics. The current panic logger still needs the privacy follow-up in [the architecture review](archive/architecture-consistency-review-2026-10-03.md#remaining-source-risks). Nothing enforces this automatically: no lint or CI step greps for sensitive identifiers, so it is a review obligation. `print!`, `println!`, `eprint!`, `eprintln!` and `dbg!` are denied by the workspace lints, which keeps application logging on `tracing`; protocol output that must reach stdout writes through an explicit `std::io::stdout` handle instead.

## `unwrap` and `expect`

Denied in production paths by the workspace lints in `Cargo.toml`, together with `panic!`, `todo!` and `unimplemented!`. This is a compiler error under `-D warnings`, not a review convention, so there is no list of tolerated exceptions to argue about.

Test code is exempt in two different ways, because Clippy treats the two kinds of test differently:

- Unit tests in a `#[cfg(test)]` module are covered by `allow-unwrap-in-tests`, `allow-expect-in-tests` and `allow-panic-in-tests` in `clippy.toml`.
- Integration tests under a crate's `tests/` directory are separate crates that those settings do not reach, so each file carries `#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]` on its first line. A new integration test file needs that header or the build fails.

Crates that exist only to support tests (`tablepro-driver-tls-tests`, `tablepro-release-tests`) set the allowances in their own manifests, since their `src/` is test scaffolding.

Two mechanisms enforce this, and both must pass. The workspace lints are semantic and run with Clippy. `scripts/check-panic-sites.sh`, run by `preflight.sh` and `ci-local.sh`, is a text scan with the same exclusion model: not inside a `#[cfg(test)]` item, not under a `tests/` directory, not in a `*-tests` support crate. Keep the two lists aligned when either changes; `unreachable!` is covered by both.

When a value's validity is locally provable, express that in the types or restructure so the impossible case cannot be written, rather than asserting it at runtime. Making a construction infallible is usually a smaller change than it looks: a widget handle that must exist by construction belongs in the struct as a plain field, not behind a cell that has to be unwrapped at every use.

## Anti-patterns flagged in review

- `Result<T, Box<dyn Error>>` in a public function. Use a `thiserror` enum.
- `anyhow::Error` returned from `core` or `storage`. Those crates expose typed errors only.
- `unwrap()` after a `Result` from a fallible operation. Always handle or propagate.
- `match err { _ => "Something went wrong" }`. Always exhaustive.
- A `String` error type at a public domain boundary where callers need to distinguish outcomes. Internal persistence acknowledgements currently use strings; changing those requires a consumer review, not a mechanical replacement. See [state-management.md](state-management.md).
