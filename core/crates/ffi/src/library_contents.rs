use std::collections::{HashMap, HashSet};
use std::time::SystemTime;

use chrono::DateTime;
use tablepro_core::{AuthMode, ExternalAccess, NetworkOptions};
use tablepro_records::cloudkit::library::{icon_for_symbol, symbol_for_icon};
use tablepro_storage::{
    ConnectionDetails, ConnectionGroup, ConnectionGroupName, ConnectionList, ConnectionTag, ConnectionTagName,
    CredentialPassword, CredentialProfile, DeviceOnly, LibraryWrite, SavedConnection, SshProfile,
};
use uuid::Uuid;

use crate::error::CoreError;
use crate::library::{
    ConnectionLibrary, ConnectionRecord, GroupRecord, LibraryIconRecord, TagRecord, library_icon, optional_id,
    parse_id, parse_ids, stored_ssh, stored_tls, tag_color,
};
use crate::library_details::{
    ConnectionDetailsRecord, CredentialProfileRecord, DeviceSettingsRecord, SshProfileRecord,
};

// A connection with everything the library keeps for it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryConnectionRecord {
    pub connection: ConnectionRecord,
    pub details: ConnectionDetailsRecord,
    pub device: DeviceSettingsRecord,
}

// As stored: a parent or group the list lacks is kept, where the snapshot reads it as the top.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryContents {
    pub connections: Vec<LibraryConnectionRecord>,
    pub groups: Vec<GroupRecord>,
    pub tags: Vec<TagRecord>,
    pub favorites: Vec<String>,
    pub ssh_profiles: Vec<SshProfileRecord>,
    pub credential_profiles: Vec<CredentialProfileRecord>,
    // Connections this build cannot read. The file keeps them, and a library write leaves them unless it names one.
    pub unreadable: Vec<String>,
    // SSH and credential profiles this build cannot read, kept the same way.
    pub unreadable_profiles: Vec<String>,
    // SHA-256 in hex of the exact bytes this came from, to check the host's tag against; a read vouches for nothing.
    pub digest: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryWriteRecord {
    pub connections: Vec<LibraryConnectionRecord>,
    pub groups: Vec<GroupRecord>,
    pub tags: Vec<TagRecord>,
    pub favorites: Vec<String>,
    // The whole set: a profile the file holds that the write leaves out goes, with its secrets.
    pub ssh_profiles: Vec<SshProfileRecord>,
    pub credential_profiles: Vec<CredentialProfileRecord>,
    // Ids of connections and profiles this build cannot read that the write takes out, with their secrets.
    pub removing: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryWritten {
    // SHA-256 in hex of the exact bytes the file holds after the write, the ones the host tags; None with no file.
    pub digest: Option<String>,
    // Where a rebuild put a file this build could not read.
    pub set_aside: Option<String>,
}

#[uniffi::export]
impl ConnectionLibrary {
    pub async fn library_contents(&self) -> Result<LibraryContents, CoreError> {
        self.blocking(|store| {
            let read = store.read_library_blocking()?;
            let list = read.list;
            Ok(LibraryContents {
                connections: list.connections.iter().map(LibraryConnectionRecord::from).collect(),
                groups: list.groups.iter().map(GroupRecord::from).collect(),
                tags: list.tags.iter().map(TagRecord::from).collect(),
                favorites: list.favorites.iter().map(Uuid::to_string).collect(),
                ssh_profiles: list.ssh_profiles.iter().map(SshProfileRecord::from).collect(),
                credential_profiles: list
                    .credential_profiles
                    .iter()
                    .map(CredentialProfileRecord::from)
                    .collect(),
                unreadable: list.unreadable.iter().map(Uuid::to_string).collect(),
                unreadable_profiles: list.unreadable_profiles.iter().map(Uuid::to_string).collect(),
                digest: read.digest,
            })
        })
        .await
    }

    // Values as given, unlike a save; `over` is the digest of the file the host vouched for, None for no file.
    pub async fn replace_library(
        &self,
        library: LibraryWriteRecord,
        over: Option<String>,
    ) -> Result<LibraryWritten, CoreError> {
        let _held = self.hold_writes().await;
        let removing = parse_ids(&library.removing)?;
        let (planned, checked) = (library.clone(), over.clone());
        // Refused here as the write would be, so no secret goes for a write that cannot land.
        let leaving = self
            .blocking(move |store| {
                store.profiles_leaving_blocking(checked.as_deref(), |list| library_write(planned, Some(list)))
            })
            .await?;
        let profiles: HashSet<Uuid> = leaving.ssh.iter().chain(&leaving.credential).copied().collect();
        let connections: Vec<Uuid> = removing.into_iter().filter(|id| !profiles.contains(id)).collect();
        // Their secrets go first, as a delete's do; a write refused after leaves entries already on their way out.
        if !connections.is_empty() {
            self.delete_secrets(connections).await?;
        }
        self.delete_profile_secrets(leaving).await?;
        self.blocking(move |store| {
            let digest = store.replace_library_blocking(over.as_deref(), |list| library_write(library, Some(list)))?;
            Ok(LibraryWritten {
                digest,
                set_aside: None,
            })
        })
        .await
    }

    // For a file its host cannot vouch for: the store holds only what this write names (rebuild_library_blocking).
    // Its ids came from that file, so no secret goes by them.
    pub async fn rebuild_library(&self, library: LibraryWriteRecord) -> Result<LibraryWritten, CoreError> {
        let _held = self.hold_writes().await;
        self.blocking(move |store| {
            let write = library_write(library, None)?;
            let rebuilt = store.rebuild_library_blocking(write, SystemTime::now())?;
            Ok(LibraryWritten {
                digest: rebuilt.digest,
                set_aside: rebuilt.set_aside.map(|path| path.display().to_string()),
            })
        })
        .await
    }
}

// What a write keeps from stored entries, such as keys a newer build wrote, comes from `stored`.
fn library_write(library: LibraryWriteRecord, stored: Option<&ConnectionList>) -> Result<LibraryWrite, CoreError> {
    let connections: HashMap<Uuid, &SavedConnection> = stored
        .map(|list| list.connections.iter().map(|saved| (saved.id, saved)).collect())
        .unwrap_or_default();
    let ssh_profiles: HashMap<Uuid, &SshProfile> = stored
        .map(|list| list.ssh_profiles.iter().map(|saved| (saved.id, saved)).collect())
        .unwrap_or_default();
    let credential_profiles: HashMap<Uuid, &CredentialProfile> = stored
        .map(|list| list.credential_profiles.iter().map(|saved| (saved.id, saved)).collect())
        .unwrap_or_default();
    Ok(LibraryWrite {
        connections: library
            .connections
            .into_iter()
            .map(|record| {
                let id = parse_id(&record.connection.id)?;
                stored_connection(id, record, connections.get(&id).copied())
            })
            .collect::<Result<_, CoreError>>()?,
        groups: library
            .groups
            .iter()
            .map(stored_group)
            .collect::<Result<_, CoreError>>()?,
        tags: library.tags.iter().map(stored_tag).collect::<Result<_, CoreError>>()?,
        favorites: parse_ids(&library.favorites)?,
        ssh_profiles: library
            .ssh_profiles
            .iter()
            .map(|record| {
                let id = parse_id(&record.id)?;
                stored_ssh_profile(id, record, ssh_profiles.get(&id).copied())
            })
            .collect::<Result<_, CoreError>>()?,
        credential_profiles: library
            .credential_profiles
            .into_iter()
            .map(|record| {
                let id = parse_id(&record.id)?;
                Ok(stored_credential_profile(
                    id,
                    record,
                    credential_profiles.get(&id).copied(),
                ))
            })
            .collect::<Result<_, CoreError>>()?,
        removing: parse_ids(&library.removing)?,
    })
}

// The icon a macOS SF Symbol name stands for, None for a name that is not one.
#[uniffi::export]
pub fn library_icon_for_symbol(symbol: String) -> Option<LibraryIconRecord> {
    icon_for_symbol(&symbol).as_ref().map(LibraryIconRecord::from)
}

// The SF Symbol a Mac draws for the icon.
#[uniffi::export]
pub fn library_icon_symbol(icon: LibraryIconRecord) -> Result<Option<String>, CoreError> {
    Ok(symbol_for_icon(&library_icon(&icon)?))
}

impl From<&SavedConnection> for LibraryConnectionRecord {
    fn from(saved: &SavedConnection) -> Self {
        Self {
            connection: ConnectionRecord::from(saved),
            details: ConnectionDetailsRecord::from(&saved.details),
            device: DeviceSettingsRecord::from(&saved.device),
        }
    }
}

fn stored_connection(
    id: Uuid,
    record: LibraryConnectionRecord,
    before: Option<&SavedConnection>,
) -> Result<SavedConnection, CoreError> {
    let LibraryConnectionRecord {
        connection,
        details,
        device,
    } = record;
    let mut details = ConnectionDetails::try_from(details)?;
    if let (Some(route), Some(held)) = (
        details.ssh_route.as_mut(),
        before.and_then(|before| before.details.ssh_route.as_ref()),
    ) {
        route.unknown.clone_from(&held.unknown);
    }
    let tls_unknown = before.map(|before| before.tls.unknown.clone()).unwrap_or_default();
    let ssh_unknown = before
        .and_then(|before| before.ssh.as_ref())
        .map(|ssh| ssh.unknown.clone())
        .unwrap_or_default();
    Ok(SavedConnection {
        id,
        name: connection.name,
        driver_id: connection.driver_id,
        host: connection.host,
        port: connection.port,
        database: connection.database,
        username: connection.username,
        tls: stored_tls(&connection.tls, tls_unknown),
        safe_mode: connection.safe_mode.into(),
        external_access: connection
            .external_access
            .map(ExternalAccess::from)
            .or(before.map(|before| before.external_access))
            .unwrap_or_default(),
        ai_policy: connection
            .ai_policy
            .map(Into::into)
            .or(before.map(|before| before.ai_policy))
            .unwrap_or_default(),
        query_timeout_secs: connection.query_timeout_secs,
        auth_mode: match connection.integrated_auth {
            true => AuthMode::Kerberos,
            false => AuthMode::Password,
        },
        ssh: connection
            .ssh
            .map(|settings| stored_ssh(&settings, ssh_unknown))
            .transpose()?,
        last_opened_at: connection
            .last_opened_ms
            .map(|ms| {
                DateTime::from_timestamp_millis(ms)
                    .ok_or_else(|| CoreError::failed("library.invalid_time", format!("{ms} is not a time")))
            })
            .transpose()?,
        color: connection.color.as_deref().map(tag_color).transpose()?,
        group_id: optional_id(connection.group_id.as_deref())?,
        order: connection.order,
        tags: parse_ids(&connection.tags)?,
        icon: connection.icon.as_ref().map(library_icon).transpose()?,
        options: before.map_or_else(NetworkOptions::default, |before| before.options.clone()),
        details,
        device: DeviceOnly::from(device),
        unknown: before.map(|before| before.unknown.clone()).unwrap_or_default(),
    })
}

fn stored_ssh_profile(
    id: Uuid,
    record: &SshProfileRecord,
    before: Option<&SshProfile>,
) -> Result<SshProfile, CoreError> {
    let unknown = before.map(|before| before.ssh.unknown.clone()).unwrap_or_default();
    Ok(SshProfile {
        id,
        name: record.name.clone(),
        ssh: stored_ssh(&record.ssh, unknown)?,
    })
}

fn stored_credential_profile(
    id: Uuid,
    record: CredentialProfileRecord,
    before: Option<&CredentialProfile>,
) -> CredentialProfile {
    CredentialProfile {
        id,
        name: record.name,
        username: record.username,
        password: CredentialPassword::from(record.password),
        secure_field_ids: record.secure_field_ids,
        order: record.order,
        unknown: before.map(|before| before.unknown.clone()).unwrap_or_default(),
    }
}

fn stored_group(record: &GroupRecord) -> Result<ConnectionGroup, CoreError> {
    Ok(ConnectionGroup {
        id: parse_id(&record.id)?,
        name: ConnectionGroupName::from_stored(&record.name),
        parent_id: optional_id(record.parent_id.as_deref())?,
        order: record.order,
        color: record.color.as_deref().map(tag_color).transpose()?,
        icon: record.icon.as_ref().map(library_icon).transpose()?,
    })
}

fn stored_tag(record: &TagRecord) -> Result<ConnectionTag, CoreError> {
    Ok(ConnectionTag {
        id: parse_id(&record.id)?,
        name: ConnectionTagName::from_stored(&record.name),
        color: record.color.as_deref().map(tag_color).transpose()?,
        is_preset: record.is_preset,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_named_icon_reads_back_as_the_symbol_a_mac_draws() {
        let server = library_icon_for_symbol("server.rack".to_owned());

        assert_eq!(
            server,
            Some(LibraryIconRecord::Named {
                id: "server".to_owned()
            })
        );
        assert_eq!(
            library_icon_symbol(server.expect("an icon"))
                .expect("a symbol")
                .as_deref(),
            Some("server.rack")
        );
        assert_eq!(
            library_icon_for_symbol("cylinder.split.1x2".to_owned()),
            Some(LibraryIconRecord::Symbol {
                name: "cylinder.split.1x2".to_owned()
            })
        );
        assert_eq!(library_icon_for_symbol("Not A Symbol".to_owned()), None);
    }

    #[test]
    fn a_colour_the_core_does_not_name_is_refused() {
        let tag = TagRecord {
            id: Uuid::new_v4().to_string(),
            name: "prod".to_owned(),
            color: Some("chartreuse".to_owned()),
            is_preset: false,
        };

        assert_eq!(
            stored_tag(&tag).expect_err("an unknown colour").code(),
            "library.unknown_color"
        );
    }
}
