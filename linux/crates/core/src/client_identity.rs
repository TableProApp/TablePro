use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ClientIdentity {
    pub certificate: PathBuf,
    pub key: PathBuf,
}
