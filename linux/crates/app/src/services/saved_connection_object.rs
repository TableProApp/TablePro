use std::path::Path;

use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_core::AuthMode;
use tablepro_storage::SavedConnection;

use super::file_location;
use super::saved_connection_object_imp as imp;

glib::wrapper! {
    /// One saved connection as the pickers' shared model holds it. It
    /// never changes: a changed connection gets a new object.
    pub struct SavedConnectionObject(ObjectSubclass<imp::SavedConnectionObject>);
}

impl SavedConnectionObject {
    /// `file_based` says whether the connection's driver opens a file,
    /// which decides what the row names: the file, or the server.
    pub(crate) fn new(saved: SavedConnection, file_based: bool) -> Self {
        let object: Self = glib::Object::new();
        let _ = object.imp().saved.set(saved);
        object.imp().file_based.set(file_based);
        object
    }

    /// Always set: `new` is the only way to build one.
    pub(crate) fn saved(&self) -> Option<&SavedConnection> {
        self.imp().saved.get()
    }

    pub(crate) fn file_based(&self) -> bool {
        self.imp().file_based.get()
    }
}

/// The driver and where it connects: the file for a driver that opens
/// one, the server otherwise. `host_path` names the file a portal path
/// stands for, once it is read.
pub(crate) fn subtitle_for(saved: &SavedConnection, file_based: bool, host_path: Option<&Path>) -> String {
    if file_based {
        let shown = file_location::display_path(Path::new(&saved.database), host_path);
        return format!("{} · {shown}", saved.driver_id);
    }
    match (saved.auth_mode, saved.username.as_str()) {
        (AuthMode::Kerberos, _) | (AuthMode::Password, "") => {
            format!("{} · {}:{}", saved.driver_id, saved.host, saved.port)
        }
        (AuthMode::Password, username) => format!("{} · {username}@{}:{}", saved.driver_id, saved.host, saved.port),
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};
    use uuid::Uuid;

    use super::*;

    fn saved(username: &str, auth_mode: AuthMode) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Corp".into(),
            driver_id: "mssql".into(),
            host: "sql.corp.example".into(),
            port: 1433,
            database: "sales".into(),
            username: username.into(),
            tls: tablepro_core::TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    #[test]
    fn a_row_without_a_username_has_no_separator_to_dangle() {
        assert_eq!(
            subtitle_for(&saved("", AuthMode::Kerberos), false, None),
            "mssql · sql.corp.example:1433"
        );
        let mut redis = saved("", AuthMode::Password);
        redis.driver_id = "redis".into();
        redis.port = 6379;
        assert_eq!(subtitle_for(&redis, false, None), "redis · sql.corp.example:6379");
        assert_eq!(
            subtitle_for(&saved("sa", AuthMode::Password), false, None),
            "mssql · sa@sql.corp.example:1433"
        );
    }

    #[test]
    fn portal_path_shows_host_path() {
        let mut file = saved("", AuthMode::Password);
        file.driver_id = "sqlite".into();
        file.database = "/run/user/1000/doc/1a2b3c/app.db".into();

        assert_eq!(
            subtitle_for(&file, true, Some(Path::new("/srv/data/app.db"))),
            "sqlite · /srv/data/app.db"
        );
        assert_eq!(subtitle_for(&file, true, None), "sqlite · app.db");
        file.database = "/home/me/app.db".into();
        assert_eq!(subtitle_for(&file, true, None), "sqlite · /home/me/app.db");
    }

    /// Any engine that opens a file names the file, not a server it
    /// does not have.
    #[test]
    fn every_file_engine_names_its_file() {
        let mut file = saved("", AuthMode::Password);
        file.driver_id = "duckdb".into();
        file.host = String::new();
        file.port = 0;
        file.database = "/home/me/sales.duckdb".into();

        assert_eq!(subtitle_for(&file, true, None), "duckdb · /home/me/sales.duckdb");
    }

    #[gtk4::test]
    fn the_object_carries_the_connection_as_properties() {
        let mut connection = saved("sa", AuthMode::Password);
        connection.group = Some(tablepro_storage::ConnectionGroupName::new("Work").expect("a group name"));
        connection.last_opened_at = Utc.timestamp_opt(1_700_000_000, 0).single();

        let object = SavedConnectionObject::new(connection.clone(), false);

        assert_eq!(object.id(), connection.id.to_string());
        assert_eq!(object.name(), "Corp");
        assert_eq!(object.subtitle(), "mssql · sa@sql.corp.example:1433");
        assert_eq!(object.group().as_deref(), Some("Work"));
        assert_eq!(object.last_opened(), 1_700_000_000_000);
        assert_eq!(object.saved().map(|saved| saved.id), Some(connection.id));
    }
}
