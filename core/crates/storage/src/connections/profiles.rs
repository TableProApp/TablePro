use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use super::SavedSshConfig;
use super::details::{CredentialReference, LocalPasswordSource};
use crate::lenient::Identified;

/// SSH settings saved under a name, which connections follow by `ConnectionDetails::ssh_profile_id`.
// A key a newer build wrote lands in `ssh.unknown`: a second map beside a flattened one would read each key twice.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshProfile {
    pub id: Uuid,
    pub name: String,
    #[serde(flatten)]
    pub ssh: SavedSshConfig,
}

/// A user and a password kept once and shared by every connection that links to it. A linked
/// connection holds no secret of its own.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CredentialProfile {
    pub id: Uuid,
    pub name: String,
    #[serde(default)]
    pub username: String,
    pub password: CredentialPassword,
    /// The secure plugin fields the profile holds; a connection reads those its engine declares.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub secure_field_ids: Vec<String>,
    #[serde(default)]
    pub order: u32,
    #[serde(flatten)]
    pub unknown: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum CredentialPassword {
    /// In the secret store, under the profile's id.
    Stored,
    Prompt,
    /// Looked up in `~/.pgpass` for a PostgreSQL-family connection.
    Pgpass,
    Reference {
        reference: CredentialReference,
    },
    /// A file or command on this device, which never leaves it.
    Local {
        source: LocalPasswordSource,
    },
}

impl Identified for SshProfile {
    fn id(&self) -> Uuid {
        self.id
    }
}

impl Identified for CredentialProfile {
    fn id(&self) -> Uuid {
        self.id
    }
}
