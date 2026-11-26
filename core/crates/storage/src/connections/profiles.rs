use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use super::details::{CredentialReference, LocalPasswordSource};
use super::{ConnectionStore, RemoveOutcome, SavedSshConfig};
use crate::error::StorageError;
use crate::lenient::Identified;

/// SSH settings saved under a name, which connections follow by `ConnectionDetails::ssh_profile_id`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshProfile {
    pub id: Uuid,
    pub name: String,
    #[serde(flatten)]
    pub ssh: SavedSshConfig,
    #[serde(flatten)]
    pub unknown: BTreeMap<String, Value>,
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

impl ConnectionStore {
    /// Adds the profile, or replaces the one with its id.
    pub fn save_ssh_profile_blocking(&self, profile: SshProfile) -> Result<(), StorageError> {
        self.edit(|document| {
            document.ssh_profiles.release(profile.id);
            match document.ssh_profiles.iter_mut().find(|held| held.id == profile.id) {
                Some(held) => *held = profile,
                None => document.ssh_profiles.push(profile),
            }
            Ok(())
        })
    }

    /// Connections that follow it keep its id and the settings they last applied. A profile this
    /// build cannot read is deleted too.
    pub fn delete_ssh_profile_blocking(&self, id: Uuid) -> Result<RemoveOutcome, StorageError> {
        self.edit(|document| Ok(removed(document.ssh_profiles.remove_id(id))))
    }

    /// Adds the profile, or replaces the one with its id.
    pub fn save_credential_profile_blocking(&self, profile: CredentialProfile) -> Result<(), StorageError> {
        self.edit(|document| {
            document.credential_profiles.release(profile.id);
            match document
                .credential_profiles
                .iter_mut()
                .find(|held| held.id == profile.id)
            {
                Some(held) => *held = profile,
                None => document.credential_profiles.push(profile),
            }
            Ok(())
        })
    }

    /// A connection linked to it keeps the link, which reads as no profile until one with that id
    /// comes back, as a pull can bring a connection before its profile.
    pub fn delete_credential_profile_blocking(&self, id: Uuid) -> Result<RemoveOutcome, StorageError> {
        self.edit(|document| Ok(removed(document.credential_profiles.remove_id(id))))
    }
}

fn removed(found: bool) -> RemoveOutcome {
    if found {
        RemoveOutcome::Removed
    } else {
        RemoveOutcome::NotPresent
    }
}
