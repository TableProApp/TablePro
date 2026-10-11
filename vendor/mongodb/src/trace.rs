use crate::{
    bson_util::{rawdoc_to_json_str, truncate_on_char_boundary},
    client::options::{ServerAddress, DEFAULT_PORT},
};

pub(crate) mod command;
pub(crate) mod connection;
pub(crate) mod server_selection;
pub(crate) mod topology;

pub(crate) const COMMAND_TRACING_EVENT_TARGET: &str = "mongodb::command";
pub(crate) const CONNECTION_TRACING_EVENT_TARGET: &str = "mongodb::connection";
pub(crate) const SERVER_SELECTION_TRACING_EVENT_TARGET: &str = "mongodb::server_selection";
pub(crate) const TOPOLOGY_TRACING_EVENT_TARGET: &str = "mongodb::topology";

pub(crate) const DEFAULT_MAX_DOCUMENT_LENGTH_BYTES: usize = 1000;

pub(crate) trait TracingRepresentation {
    type Representation;

    fn tracing_representation(&self) -> Self::Representation;
}

impl TracingRepresentation for crate::bson::oid::ObjectId {
    type Representation = String;

    fn tracing_representation(&self) -> String {
        self.to_hex()
    }
}

impl crate::error::Error {
    fn tracing_representation(&self, max_document_length: usize) -> String {
        let mut error_string = format!(
            "Kind: {}, labels: {:?}, source: {:?}",
            self.kind,
            self.labels(),
            self.source
        );
        if let Some(server_response) = self.server_response() {
            let server_response_string =
                match rawdoc_to_json_str(server_response, max_document_length) {
                    Ok(s) => s,
                    Err(_) => {
                        let mut hex_string = hex::encode(server_response.as_bytes());
                        if truncate_on_char_boundary(&mut hex_string, max_document_length) {
                            hex_string.push_str("...");
                        }
                        hex_string
                    }
                };
            error_string.push_str(", server response: ");
            error_string.push_str(&server_response_string);
        }
        error_string
    }
}

impl ServerAddress {
    /// Per spec should populate the port field with 27017 if we are defaulting to that.
    pub(crate) fn port_tracing_representation(&self) -> Option<u16> {
        match self {
            Self::Tcp { port, .. } => Some(port.unwrap_or(DEFAULT_PORT)),
            // For Unix domain sockets we should return None here, as ports
            // are not meaningful for those.
            #[cfg(unix)]
            Self::Unix { .. } => None,
        }
    }
}

/// We don't currently use all of these levels but they are included for completeness.
#[allow(dead_code)]
pub(crate) enum TracingOrLogLevel {
    Error,
    Warn,
    Info,
    Debug,
    Trace,
}

impl TracingOrLogLevel {
    pub(crate) const fn as_log_level(&self) -> log::Level {
        match self {
            TracingOrLogLevel::Error => log::Level::Error,
            TracingOrLogLevel::Warn => log::Level::Warn,
            TracingOrLogLevel::Info => log::Level::Info,
            TracingOrLogLevel::Debug => log::Level::Debug,
            TracingOrLogLevel::Trace => log::Level::Trace,
        }
    }

    pub(crate) const fn as_tracing_level(&self) -> tracing::Level {
        match self {
            TracingOrLogLevel::Error => tracing::Level::ERROR,
            TracingOrLogLevel::Warn => tracing::Level::WARN,
            TracingOrLogLevel::Info => tracing::Level::INFO,
            TracingOrLogLevel::Debug => tracing::Level::DEBUG,
            TracingOrLogLevel::Trace => tracing::Level::TRACE,
        }
    }
}

/// Pending https://github.com/tokio-rs/tracing/issues/2036 we can remove this and just use tracing::enabled.
macro_rules! trace_or_log_enabled {
    (target: $target:expr, $lvl:expr) => {
        tracing::enabled!(target: $target, $lvl.as_tracing_level())
            || log::log_enabled!(target: $target, $lvl.as_log_level())
    };
}
pub(crate) use trace_or_log_enabled;
