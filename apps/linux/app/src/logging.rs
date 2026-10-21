use std::error::Error;

use thiserror::Error as ThisError;
use tracing::Subscriber;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::util::SubscriberInitExt;

use crate::config::Profile;

pub const LOG_FORMAT_ENV: &str = "TABLEPRO_LOG_FORMAT";

#[derive(Debug, ThisError)]
pub enum LoggingError {
    #[error("could not install the tracing subscriber: {0}")]
    Install(Box<dyn Error + Send + Sync>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogFormat {
    Human,
    Json,
}

pub fn default_level(profile: Profile) -> &'static str {
    match profile {
        Profile::Development => "debug",
        Profile::Default => "info",
    }
}

pub const STATEMENT_LOG_TARGET: &str = "sqlx::query";

pub fn without_statement_text(filter: EnvFilter, requested: Option<&str>) -> EnvFilter {
    if requested.is_some_and(|requested| requested.contains(STATEMENT_LOG_TARGET)) {
        return filter;
    }
    match format!("{STATEMENT_LOG_TARGET}=off").parse() {
        Ok(directive) => filter.add_directive(directive),
        Err(_) => filter,
    }
}

pub fn log_format(requested: Option<&str>) -> Option<LogFormat> {
    let Some(raw) = requested else {
        return Some(LogFormat::Human);
    };
    match raw.trim().to_ascii_lowercase().as_str() {
        "" | "human" | "text" | "pretty" | "compact" => Some(LogFormat::Human),
        "json" => Some(LogFormat::Json),
        _ => None,
    }
}

pub fn build_subscriber<W>(format: LogFormat, filter: EnvFilter, writer: W) -> Box<dyn Subscriber + Send + Sync>
where
    W: for<'a> MakeWriter<'a> + Send + Sync + 'static,
{
    let builder = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(writer)
        .with_target(false);
    match format {
        LogFormat::Human => Box::new(builder.finish()),
        LogFormat::Json => Box::new(builder.json().finish()),
    }
}

/// Logs go to stderr, which the GNOME session journals for both Flatpak
/// and system installs. Panics land there too, so the two interleave in
/// order without a journald writer or a panic hook.
pub fn init(profile: Profile) -> Result<(), LoggingError> {
    let requested = std::env::var_os("RUST_LOG");
    let parsed = EnvFilter::try_from_default_env();
    let unparsable = requested.is_some() && parsed.is_err();
    let filter = without_statement_text(
        parsed.unwrap_or_else(|_| EnvFilter::new(default_level(profile))),
        requested.as_deref().and_then(|requested| requested.to_str()),
    );

    let requested_format = std::env::var(LOG_FORMAT_ENV).ok();
    let selected = log_format(requested_format.as_deref());
    let format = selected.unwrap_or(LogFormat::Human);

    build_subscriber(format, filter, std::io::stderr)
        .try_init()
        .map_err(|e| LoggingError::Install(Box::new(e)))?;

    if unparsable {
        tracing::warn!(
            "RUST_LOG could not be parsed; falling back to {}",
            default_level(profile)
        );
    }
    if selected.is_none() {
        tracing::warn!("{LOG_FORMAT_ENV} is not a known log format; using the human format");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Default)]
    struct Captured(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);

    impl std::io::Write for Captured {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn logged(filter: &str, requested: Option<&str>) -> String {
        let captured = Captured::default();
        let writer = captured.clone();
        let filter = without_statement_text(EnvFilter::new(filter), requested);
        let subscriber = build_subscriber(LogFormat::Human, filter, move || writer.clone());
        tracing::subscriber::with_default(subscriber, || {
            tracing::warn!(target: "sqlx::query", statement = "CREATE USER u PASSWORD 'secret-marker'", "slow statement");
            tracing::debug!(target: "sqlx::query", statement = "SELECT 'debug-marker'", "statement");
            tracing::warn!("ordinary warning");
        });
        String::from_utf8(captured.0.lock().unwrap().clone()).unwrap()
    }

    #[test]
    fn sql_statement_text_never_reaches_the_log_unless_asked_for_by_name() {
        for (filter, requested) in [
            ("info", None),
            ("debug", None),
            ("debug", Some("debug")),
            ("trace", Some("trace")),
        ] {
            let output = logged(filter, requested);
            assert!(output.contains("ordinary warning"), "{filter}: {output}");
            assert!(!output.contains("secret-marker"), "{filter}: {output}");
            assert!(!output.contains("debug-marker"), "{filter}: {output}");
        }
        let output = logged("info,sqlx::query=warn", Some("info,sqlx::query=warn"));
        assert!(output.contains("secret-marker"), "{output}");
    }

    #[test]
    fn default_level_per_profile() {
        assert_eq!(default_level(Profile::Development), "debug");
        assert_eq!(default_level(Profile::Default), "info");
    }

    #[test]
    fn an_unset_log_format_stays_human() {
        assert_eq!(log_format(None), Some(LogFormat::Human));
    }

    #[test]
    fn json_is_selected_case_insensitively() {
        assert_eq!(log_format(Some("json")), Some(LogFormat::Json));
        assert_eq!(log_format(Some(" JSON ")), Some(LogFormat::Json));
    }

    #[test]
    fn a_human_format_name_stays_human() {
        assert_eq!(log_format(Some("human")), Some(LogFormat::Human));
        assert_eq!(log_format(Some("text")), Some(LogFormat::Human));
        assert_eq!(log_format(Some("")), Some(LogFormat::Human));
    }

    #[test]
    fn an_unknown_log_format_is_rejected_rather_than_guessed() {
        assert_eq!(log_format(Some("logfmt")), None);
        assert_eq!(log_format(Some("jsonl")), None);
    }
}
