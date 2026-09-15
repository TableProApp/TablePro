use std::error::Error;

use thiserror::Error as ThisError;
use tracing_subscriber::EnvFilter;

use crate::config::Profile;

#[derive(Debug, ThisError)]
pub enum LoggingError {
    #[error("could not install the tracing subscriber: {0}")]
    Install(Box<dyn Error + Send + Sync>),
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

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(false)
        .try_init()
        .map_err(LoggingError::Install)?;

    if unparsable {
        tracing::warn!(
            "RUST_LOG could not be parsed; falling back to {}",
            default_level(profile)
        );
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
}
