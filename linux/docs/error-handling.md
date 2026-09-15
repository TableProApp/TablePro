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

Domain errors are exhaustive enums:

```rust
#[derive(Debug, thiserror::Error)]
pub enum DriverError {
    #[error("connection refused")]
    ConnectionRefused,

    #[error("authentication failed")]
    AuthFailed,

    #[error("TLS handshake failed: {0}")]
    Tls(String),

    #[error("query failed: {message}")]
    Query { message: String, sqlstate: Option<String> },

    #[error("connection closed unexpectedly")]
    Disconnected,

    #[error("driver internal error: {0}")]
    Internal(String),
}
```

Rules:

- Variants are stable. Once shipped, do not rename or remove. Add new variants at the end.
- Avoid wrapping arbitrary `Box<dyn Error>` inside variants. Map underlying errors into specific variants. The `Internal(String)` variant is the escape hatch for cases that genuinely cannot be classified — use it sparingly.
- The `#[error]` message is for logs and developer-facing surfaces. The UI builds its own message based on the variant.

## Driver-side error mapping

Each driver crate maps the underlying crate's errors:

```rust
fn map_sqlx_error(err: sqlx::Error) -> DriverError {
    use sqlx::Error::*;
    match err {
        Database(e) => DriverError::Query {
            message: e.message().to_string(),
            sqlstate: e.code().map(|c| c.to_string()),
        },
        Io(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => DriverError::ConnectionRefused,
        Tls(e) => DriverError::Tls(e.to_string()),
        PoolClosed | PoolTimedOut => DriverError::Disconnected,
        other => DriverError::Internal(format!("{other}")),
    }
}
```

The driver does not pass through `sqlx::Error` to callers. Callers see only `DriverError`.

## UI display

`app` translates `DriverError` and `StorageError` into user-facing messages with full context. The mapping lives in `app::ui::error_message`:

```rust
fn message_for(err: &DriverError) -> String {
    match err {
        DriverError::ConnectionRefused => "Could not reach the database. Is it running?".into(),
        DriverError::AuthFailed => "Username or password is wrong.".into(),
        DriverError::Tls(detail) => format!("TLS handshake failed: {detail}"),
        DriverError::Query { message, sqlstate: Some(s) } => format!("Query failed (SQLSTATE {s}): {message}"),
        DriverError::Query { message, .. } => format!("Query failed: {message}"),
        DriverError::Disconnected => "The connection was closed. Try reconnecting.".into(),
        DriverError::Internal(detail) => format!("Internal driver error: {detail}"),
    }
}
```

Do not display raw `Debug` or `Display` output for domain errors. Always go through this layer.

## Logging

Use the `tracing` crate. `app::logging::init` installs a `tracing_subscriber` that writes to **stderr**, which the GNOME session journals for both Flatpak and system installs. Panic output goes to the same place, so a panic and the log lines around it stay in order. There is no `tracing-journald` writer and no custom panic hook.

The filter comes from `RUST_LOG`. Without it the level follows the build profile: `debug` for a development build, `info` otherwise. A `RUST_LOG` that does not parse falls back to the profile default and logs a warning saying so, rather than silently dropping to the default.

```sh
RUST_LOG=debug ./_build/crates/app/tablepro
RUST_LOG=tablepro_app::ui=trace,info ./_build/crates/app/tablepro
journalctl --user -f -t tablepro
```

Levels:

- `error!` — something the user must see, or a contract was violated.
- `warn!` — recoverable but suspicious.
- `info!` — significant lifecycle events: app start, driver registered, connection opened.
- `debug!` — verbose internal flow.
- `trace!` — query bodies, network frames. Off by default.

Never log passwords, secret tokens, or full query parameters at any level above `trace!`. The lint enforces this in CI by grepping for known sensitive identifiers.

## `unwrap` and `expect`

Banned in production paths. The only legitimate uses:

- `OnceLock::get_or_init` initialisers that genuinely cannot fail.
- Test code.
- Single-call type conversions on values whose validity is locally provable (e.g. `"5432".parse::<u16>().expect("constant literal")`).

In every other case, propagate the error. If a function "cannot fail", make it `infallible` by typing.

## Anti-patterns flagged in review

- `Result<T, Box<dyn Error>>` in a public function. Use a `thiserror` enum.
- `anyhow::Error` returned from `core` or `storage`. Those crates expose typed errors only.
- `unwrap()` after a `Result` from a fallible operation. Always handle or propagate.
- `match err { _ => "Something went wrong" }`. Always exhaustive.
- A `String` error type. We have one shipped product; use the proper enum.
