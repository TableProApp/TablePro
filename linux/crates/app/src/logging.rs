use std::error::Error;

use thiserror::Error as ThisError;
use tracing_subscriber::EnvFilter;

use crate::config::Profile;

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

    let builder = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(false);
    match format.unwrap_or(LogFormat::Text) {
        // One object per line, so a shipper reads a field rather than a
        // position in a sentence.
        LogFormat::Json => builder.json().try_init().map_err(LoggingError::Install)?,
        LogFormat::Text => builder.try_init().map_err(LoggingError::Install)?,
    }

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

#[cfg(test)]
mod tests {
    use super::*;

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
