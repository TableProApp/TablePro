use std::collections::HashMap;

use chrono::DateTime;
use tablepro_core::{AuthMode, ExternalAccess, NetworkOptions};
use tablepro_records::cloudkit::library::{icon_for_symbol, symbol_for_icon};
use tablepro_storage::{
    ConnectionDetails, ConnectionGroup, ConnectionGroupName, ConnectionTag, ConnectionTagName, DeviceOnly,
    LibraryWrite, SavedConnection,
};
use uuid::Uuid;

use crate::error::CoreError;
use crate::library::{
    ConnectionLibrary, ConnectionRecord, GroupRecord, LibraryIconRecord, TagRecord, library_icon, optional_id,
    parse_id, parse_ids, stored_ssh, stored_tls, tag_color,
};
use crate::library_details::{ConnectionDetailsRecord, DeviceSettingsRecord};

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
    // Connections this build cannot read. The file keeps them, and a library write leaves them unless it names one.
    pub unreadable: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryWriteRecord {
    pub connections: Vec<LibraryConnectionRecord>,
    pub groups: Vec<GroupRecord>,
    pub tags: Vec<TagRecord>,
    pub favorites: Vec<String>,
}

#[uniffi::export]
impl ConnectionLibrary {
    pub async fn library_contents(&self) -> Result<LibraryContents, CoreError> {
        self.blocking(|store| {
            let list = store.list_blocking()?;
            Ok(LibraryContents {
                connections: list.connections.iter().map(LibraryConnectionRecord::from).collect(),
                groups: list.groups.iter().map(GroupRecord::from).collect(),
                tags: list.tags.iter().map(TagRecord::from).collect(),
                favorites: list.favorites.iter().map(Uuid::to_string).collect(),
                unreadable: list.unreadable.iter().map(Uuid::to_string).collect(),
            })
        })
        .await
    }

    // Values as given, unlike a save; a newer build's keys stay; secrets are the app's to keep or delete.
    pub async fn replace_library(&self, library: LibraryWriteRecord) -> Result<(), CoreError> {
        let _held = self.hold_writes().await;
        self.blocking(move |store| {
            let list = store.list_blocking()?;
            let stored: HashMap<Uuid, &SavedConnection> =
                list.connections.iter().map(|saved| (saved.id, saved)).collect();
            let write = LibraryWrite {
                connections: library
                    .connections
                    .into_iter()
                    .map(|record| {
                        let id = parse_id(&record.connection.id)?;
                        stored_connection(id, record, stored.get(&id).copied())
                    })
                    .collect::<Result<_, CoreError>>()?,
                groups: library
                    .groups
                    .iter()
                    .map(stored_group)
                    .collect::<Result<_, CoreError>>()?,
                tags: library.tags.iter().map(stored_tag).collect::<Result<_, CoreError>>()?,
                favorites: parse_ids(&library.favorites)?,
            };
            Ok(store.replace_library_blocking(write)?)
        })
        .await
    }
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
        ssh: connection.ssh.map(|settings| stored_ssh(&settings, ssh_unknown)),
        last_opened_at: connection.last_opened_ms.and_then(DateTime::from_timestamp_millis),
        color: connection.color.as_deref().map(tag_color).transpose()?,
        group_id: optional_id(connection.group_id.as_deref())?,
        project_id: optional_id(connection.project_id.as_deref())?,
        order: connection.order,
        tags: parse_ids(&connection.tags)?,
        icon: connection.icon.as_ref().map(library_icon).transpose()?,
        options: before.map_or_else(NetworkOptions::default, |before| before.options.clone()),
        details,
        device: DeviceOnly::from(device),
        unknown: before.map(|before| before.unknown.clone()).unwrap_or_default(),
    })
}

fn stored_group(record: &GroupRecord) -> Result<ConnectionGroup, CoreError> {
    Ok(ConnectionGroup {
        id: parse_id(&record.id)?,
        name: ConnectionGroupName::from_stored(&record.name),
        parent_id: optional_id(record.parent_id.as_deref())?,
        order: record.order,
        color: record.color.as_deref().map(tag_color).transpose()?,
        icon: record.icon.as_ref().map(library_icon).transpose()?,
        project_id: optional_id(record.project_id.as_deref())?,
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
