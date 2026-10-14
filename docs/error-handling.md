# Error handling

This page settles how failures cross crate and UI boundaries. [AGENTS.md](../AGENTS.md) and [code conventions](code-conventions.md#errors) state the short rules; this document is the working guide. When advice from the wider Rust ecosystem conflicts with a rule here, follow this page.

The ecosystem split is settled and matches this repository: **`thiserror` for library and domain APIs that callers match on; opaque application errors only where no caller branches on the failure mode.** BookiE keeps typed errors further into the app than a typical CLI, because the GTK layer selects recovery text from variants ([error_text](../apps/linux/app/src/ui/error_text.rs)).

## Layer table

| Layer | Error type | Why |
|---|---|---|
| `core` (traits, contracts, `DriverError`) | `thiserror` enums | Stable variants; every consumer matches on them. |
| `policy`, `storage`, `transport`, `ssh` | `thiserror` enums | Cross crate boundaries; need exhaustive matching. |
| `drivers/<engine>` | Map the engine crate into `core::DriverError` | Native errors never leak past the driver. |
| `mcp`, `agentd` | Protocol or tool outcomes built from the same typed guard/driver path | Scopes, allowlists and `PolicyGuard` stay typed; do not invent a parallel stringly API. |
| `app` (UI handlers, services, glue) | Prefer the domain enum the caller already has; `Result<T, String>` only where [state-management](state-management.md) already does | The UI matches variants. Do not erase them into an opaque error before [error_text](../apps/linux/app/src/ui/error_text.rs). |
| Tests | Domain `Result` or the shortest honest form | Prefer asserting a variant or observable outcome, not message text. |

`anyhow` is listed in the workspace manifest for optional composition, but production crates and the app do not use it today. Do not introduce `anyhow::Error` at a public domain boundary. Inside a throwaway binary or a one-off tool that never matches variants, it is acceptable; that is not the GTK app's database path.

Mixing a typed domain error and an opaque catch-all at the same boundary is a review red flag.

## Choose `Result`, not panic

- Recoverable failure (bad input, network, policy denial, missing row): return `Result`.
- A broken program invariant that types should have made impossible: fix the types. Do not paper over it with `unwrap` or `expect` in production paths.
- A dependency panic on hostile input is not your panic. [ADR 0006](decisions/0006-driver-panic-containment.md) catches it in `PolicyGuard` and turns it into `DriverError` (`Internal` for reads, `OperationOutcomeUnknown` for writes).

## Designing a `thiserror` enum

Variants name what failed **in the caller's vocabulary**, not the library's (`Tls`, not `RustlsError`; `AuthFailed`, not `SqlxError::Configuration`).

Rules that improve both human and agent debugging:

1. **One variant per decision the caller makes.** If the UI or policy branches differently, it needs its own variant (or a field the match can read).
2. **Preserve the cause.** Prefer a field named `source` or marked `#[source]` over formatting the lower error into a `String`. Walk `source()` when classifying (as the PostgreSQL TLS path does). Formatting early loses the chain.
3. **`#[from]` only when conversion is unambiguous.** One source type may map to at most one `#[from]` variant. When the same I/O error can mean "refused" or "disconnected", use `map_err` and pick the variant with context. Blind `#[from]` on a foreign crate error at a public boundary is usually wrong.
4. **Context belongs in fields, not only in the Display string.** Paths, statement indexes, SQLSTATE and similar stay in structured fields so matches and tests do not scrape text.
5. **`#[error]` text is for logs and developers.** The UI builds its own copy from the variant. Never put secrets, SQL, parameters or unmasked data in Display, Debug, or error fields.
6. **Do not wrap `Box<dyn Error + Send + Sync>` in a public domain variant** when a specific variant exists. `DriverError::Internal(String)` is the escape hatch; use it sparingly and only when classification truly failed.
7. **Stability.** Once a public variant ships, do not rename or remove it. Add new variants. Callers (and `error_text`) match exhaustively on purpose.

### What not to copy from generic guides

| Common internet advice | BookiE choice |
|---|---|
| `#[non_exhaustive]` on every public error enum | **Do not** put it on `DriverError` or other enums the UI and policy match exhaustively. Adding a variant is a deliberate, compile-breaking change that forces the message layer to handle it. |
| `anyhow` everywhere in the binary | Keep typed errors through assembly until [error_text](../apps/linux/app/src/ui/error_text.rs) (or an MCP/tool response). Opaque errors hide recovery. |
| `miette` / fancy diagnostics | Not used. GTK and MCP have their own surfaces. |
| `Result<T, Box<dyn Error>>` at crate boundaries | Forbidden for public domain APIs. |
| Return foreign crate errors (`sqlx::Error`, `russh::Error`) from workspace crates | Forbidden. Map at the driver or owning crate boundary. |

## Mapping at boundaries

Map at the edge that understands the native failure. Follow the production mapping for the affected driver or crate; do not invent a generic "everything is Internal" helper.

- Connect refusal, established loss, authentication failure and certificate failure are different `DriverError` variants. They must stay distinct.
- Certificate verification often surfaces as I/O in sqlx. The PostgreSQL driver walks the error chain and reports hostname or authority mismatch as `DriverError::Tls`. Reporting those as `Internal` tells the user the wrong story.
- Drivers never pass `sqlx::Error`, `tiberius` errors or similar to callers. Callers see only `DriverError`.
- When wrapping, prefer `map_err` into a variant with `source` over `map_err(|e| … e.to_string())` unless the foreign type cannot be kept and the string is already redacted.

## Ambiguous outcomes

`DriverError::OperationOutcomeUnknown` means an interrupted or dispatched operation whose terminal outcome cannot be confirmed. Controlled reads can return it; only a governed write poisons write state. Pre-dispatch refusal is a known outcome. An ambiguous write must not become a plain failure (`Query`, `Internal`, or a bare `Err` that claims the server rejected the change). See [code conventions](code-conventions.md#errors) and [ADR 0006](decisions/0006-driver-panic-containment.md).

Transaction helpers:

- `Transaction` means a statement failed and rollback was confirmed.
- `TransactionRollbackFailed` means the statement failed and rollback also failed; the UI must not claim the database is clean.

## UI display

`app` translates domain errors into recovery messages in [error_text](../apps/linux/app/src/ui/error_text.rs). Preserve typed categories through assembly and wrappers before selecting the user-facing message.

Do not display raw `Debug` or `Display` for domain errors. Always go through that layer (or the equivalent MCP/tool mapping). Exhaustive matches are required: a new variant without a message is a compile error, which is the point.

## Logging

Use the `tracing` crate. `app::logging::init` installs a `tracing_subscriber` formatter that writes to stderr; the GNOME session journals that for both Flatpak and system installs, so panics and logs interleave in order without a journald writer. `RUST_LOG` overrides the per-profile default level. Levels:

- `error!`: something the user must see, or a contract was violated.
- `warn!`: recoverable but suspicious.
- `info!`: significant lifecycle events such as app start, driver registration, or a connection opening.
- `debug!`: verbose internal flow.
- `trace!`: structural diagnostics and timings. Off by default; the same privacy rules apply.

Log the **variant and safe fields**, not a hope that `Display` is clean. Prefer `tracing` fields (`error = ?classified`, `sqlstate = %code`) over interpolating a full error string that might grow sensitive detail later.

Never log passwords, secret tokens, connection strings, SQL text, query parameters, unmasked results or raw panic payloads at any level. Dependency panic payloads and raw network frames can contain the same data; do not treat them as safe diagnostics. The app and `agentd` install a hook that always withholds panic messages, and `PolicyGuard` withholds caught driver panic payloads while reporting the operation and payload byte count. Set `TABLEPRO_DEBUG_PANICS=1` to capture a backtrace without exposing the panic message; `RUST_BACKTRACE=1` also requests a backtrace. Both modes retain the source location and stack frames. [#666](https://github.com/cozyGarage/BookiE/issues/666) tracks the installed-launch investigation. Nothing enforces general log privacy automatically: no lint or CI step greps for sensitive identifiers, so it remains a review obligation. `print!`, `println!`, `eprint!`, `eprintln!` and `dbg!` are denied by the workspace lints, which keeps application logging on `tracing`; protocol output that must reach stdout writes through an explicit `std::io::stdout` handle instead.

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
- `anyhow::Error` returned from `core`, `policy`, `storage`, `transport`, `ssh` or a driver. Those crates expose typed errors only.
- Erasing a `DriverError` (or other domain enum) into a string or opaque error before the UI or MCP mapping layer.
- `unwrap()` / `expect()` after a `Result` from a fallible operation in production code.
- `match err { _ => "Something went wrong" }`. Always exhaustive on domain enums the product surfaces.
- `#[from]` on a foreign crate error that belongs behind a mapping function with several outcomes.
- Formatting a source with `to_string()` and dropping the typed cause when the cause could have been kept.
- A `String` error type at a public domain boundary where callers need to distinguish outcomes. Internal persistence acknowledgements currently use strings; changing those requires a consumer review, not a mechanical replacement. See [state-management.md](state-management.md).
- Putting SQL, passwords, tokens or unmasked rows into error Display, audit fields or logs.

## Quick checklist for a new fallible API

1. Who matches on failure: UI, policy, another crate, or only a log line?
2. If anyone branches, add or reuse a `thiserror` variant in the owning crate's vocabulary.
3. Map foreign errors at the boundary; keep `source` when possible.
4. Ensure denied, cancelled, timed-out and unknown-outcome paths still produce their terminal audit state where policy applies.
5. Add or update the UI / MCP message mapping when a new public variant can reach a user.
6. Add a regression that asserts the variant or observable outcome, not the Display string.
