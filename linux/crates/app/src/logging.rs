use std::error::Error;

use thiserror::Error as ThisError;
use tracing::Subscriber;
use tracing_subscriber::filter::{FilterExt, LevelFilter, Targets};
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer};

use crate::config::Profile;

/// The client libraries under the drivers, by target prefix. Each can
/// log what a user's database was sent or answered: tokio-postgres the
/// text of every statement at debug, sqlx every statement and a slow
/// one as a warning, tiberius rows at trace and server messages as
/// errors, the clickhouse crate exceptions that quote the query, and
/// deadpool the errors of the connections it recycles. The drivers map
/// and log what they need from these libraries themselves.
const CLIENT_LIBRARIES: &[&str] = &["tokio_postgres", "deadpool", "tiberius", "sqlx", "clickhouse"];

#[derive(Debug, ThisError)]
pub enum LoggingError {
    #[error("could not install the tracing subscriber: {0}")]
    Install(Box<dyn Error + Send + Sync>),
}

/// How a line is written.
///
/// The journal renders either, but only one of them can be read back by
/// a log shipper without guessing where a field ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogFormat {
    Text,
    Json,
}

/// The format `TABLEPRO_LOG_FORMAT` asks for.
///
/// `None` for a value that names no format, which the caller reports
/// rather than acting on, the same way an unparsable `RUST_LOG` does.
pub fn parse_format(requested: &str) -> Option<LogFormat> {
    match requested.trim().to_ascii_lowercase().as_str() {
        "" | "text" | "plain" => Some(LogFormat::Text),
        "json" => Some(LogFormat::Json),
        _ => None,
    }
}

/// A development build is noisy on purpose; an installed one keeps the
/// journal readable.
pub fn default_level(profile: Profile) -> &'static str {
    match profile {
        Profile::Development => "debug",
        Profile::Default => "info",
    }
}

/// Logs go to stderr, which the GNOME session journals for both Flatpak
/// and system installs. Panics land there too, so the two interleave in
/// order without a journald writer or a panic hook.
pub fn init(profile: Profile) -> Result<(), LoggingError> {
    let requested = std::env::var_os("RUST_LOG");
    let parsed = EnvFilter::try_from_default_env();
    let unparsable = requested.is_some() && parsed.is_err();
    let filter = parsed.unwrap_or_else(|_| EnvFilter::new(default_level(profile)));

    let asked = std::env::var("TABLEPRO_LOG_FORMAT").ok();
    let format = asked.as_deref().and_then(parse_format);
    let unknown_format = asked.as_deref().is_some_and(|value| parse_format(value).is_none());

    // Installing it also installs the `log` bridge, so the libraries
    // that log through `log` pass the same filter.
    subscriber(filter, format.unwrap_or(LogFormat::Text), std::io::stderr)
        .try_init()
        .map_err(|error| LoggingError::Install(Box::new(error)))?;

    if unparsable {
        tracing::warn!(
            "RUST_LOG could not be parsed; falling back to {}",
            default_level(profile)
        );
    }
    if unknown_format {
        tracing::warn!("TABLEPRO_LOG_FORMAT names no known format; writing text");
    }
    Ok(())
}

/// What `init` installs, writing to `writer`.
///
/// The client libraries are filtered beside `filter` rather than inside
/// it, so no `RUST_LOG` directive, however specific, turns them back on.
fn subscriber<W>(filter: EnvFilter, format: LogFormat, writer: W) -> impl Subscriber + Send + Sync + 'static
where
    W: for<'writer> MakeWriter<'writer> + Send + Sync + 'static,
{
    let output = tracing_subscriber::fmt::layer().with_writer(writer).with_target(false);
    let output = match format {
        // One object per line, so a shipper reads a field rather than a
        // position in a sentence.
        LogFormat::Json => output.json().boxed(),
        LogFormat::Text => output.boxed(),
    };
    tracing_subscriber::registry().with(output.with_filter(filter.and(client_libraries_silenced())))
}

fn client_libraries_silenced() -> Targets {
    CLIENT_LIBRARIES
        .iter()
        .fold(Targets::new().with_default(LevelFilter::TRACE), |targets, library| {
            targets.with_target(*library, LevelFilter::OFF)
        })
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::sync::{Arc, Mutex, PoisonError};

    use super::*;

    const SECRET: &str = "ALTER ROLE app PASSWORD 'hunter2'";

    #[derive(Clone, Default)]
    struct Captured(Arc<Mutex<Vec<u8>>>);

    impl Captured {
        fn text(&self) -> String {
            String::from_utf8_lossy(&self.0.lock().unwrap_or_else(PoisonError::into_inner)).into_owned()
        }
    }

    impl Write for Captured {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl<'writer> MakeWriter<'writer> for Captured {
        type Writer = Self;

        fn make_writer(&'writer self) -> Self::Writer {
            self.clone()
        }
    }

    fn written(rust_log: &str, format: LogFormat, emit: impl FnOnce()) -> String {
        let captured = Captured::default();
        let subscriber = subscriber(EnvFilter::new(rust_log), format, captured.clone());
        tracing::subscriber::with_default(subscriber, emit);
        captured.text()
    }

    #[test]
    fn client_library_events_are_dropped_whatever_rust_log_asks() {
        for format in [LogFormat::Text, LogFormat::Json] {
            let text = written(
                "trace,tokio_postgres::simple_query=trace,sqlx::query=trace",
                format,
                || {
                    tracing::debug!(target: "tokio_postgres::simple_query", "executing simple query: {SECRET}");
                    tracing::warn!(target: "sqlx::query", "slow statement: {SECRET}");
                    tracing::trace!(target: "sqlx::explain", "{SECRET}");
                    tracing::error!(target: "tiberius::tds::stream::token", message = SECRET);
                    tracing::debug!(target: "clickhouse::error", "{SECRET}");
                    tracing::warn!(target: "deadpool.postgres", "Connection error: {SECRET}");
                    tracing::debug!(target: "tablepro::ui::editor", "the run ended");
                },
            );

            assert!(!text.contains("hunter2"), "{format:?}: {text}");
            assert!(text.contains("the run ended"), "{format:?}: {text}");
        }
    }

    #[test]
    fn statements_logged_through_log_are_dropped() {
        // Fails only when a logger other than the bridge is already set,
        // which nothing in this binary does.
        let _ = tracing_log::LogTracer::init();

        let text = written("debug", LogFormat::Text, || {
            log::debug!(target: "tokio_postgres::simple_query", "executing simple query: {SECRET}");
            log::debug!(target: "tokio_postgres::prepare", "preparing query s0: {SECRET}");
            log::info!(target: "tokio_postgres::connection", "NOTICE: {SECRET}");
            log::debug!(target: "drivers_postgres::pool", "a pooled connection ended");
        });

        assert!(!text.contains("hunter2"), "{text}");
        assert!(text.contains("a pooled connection ended"), "{text}");
    }

    #[test]
    fn the_filter_still_drops_what_rust_log_leaves_out() {
        let text = written("info", LogFormat::Text, || {
            tracing::debug!(target: "tablepro::ui", "noise");
            tracing::info!(target: "tablepro::ui", "kept");
        });

        assert!(!text.contains("noise"), "{text}");
        assert!(text.contains("kept"), "{text}");
    }

    #[test]
    fn default_level_per_profile() {
        assert_eq!(default_level(Profile::Development), "debug");
        assert_eq!(default_level(Profile::Default), "info");
    }

    #[test]
    fn a_format_is_named_in_any_case_with_any_spacing() {
        assert_eq!(parse_format("json"), Some(LogFormat::Json));
        assert_eq!(parse_format("  JSON "), Some(LogFormat::Json));
        assert_eq!(parse_format("text"), Some(LogFormat::Text));
        assert_eq!(parse_format("plain"), Some(LogFormat::Text));
    }

    #[test]
    fn an_unset_or_empty_value_is_the_text_default() {
        assert_eq!(parse_format(""), Some(LogFormat::Text));
        assert_eq!(parse_format("   "), Some(LogFormat::Text));
    }

    #[test]
    fn a_value_naming_no_format_is_refused_rather_than_guessed() {
        assert_eq!(parse_format("yaml"), None);
        assert_eq!(parse_format("jsonl"), None);
    }
}
