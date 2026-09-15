use std::path::PathBuf;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum SettingsError {
    #[error("GSettings schema {0} is not installed")]
    SchemaNotFound(String),
    #[error("could not read GSettings schemas from {}: {source}", .path.display())]
    SchemaDirectory {
        path: PathBuf,
        #[source]
        source: glib::Error,
    },
    #[error("could not write setting {key}: {source}")]
    Write {
        key: &'static str,
        #[source]
        source: glib::BoolError,
    },
}
