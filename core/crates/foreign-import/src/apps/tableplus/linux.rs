use std::collections::HashMap;

use serde::Deserialize;
use serde_json::Value;

use super::connection::{Entry, Group};

// The Linux app saves each list as `{"objects": [...]}`, one serialized object per item with
// kebab-case property names.
#[derive(Deserialize)]
pub(super) struct ObjectList {
    #[serde(default)]
    pub objects: Vec<Value>,
}

impl ObjectList {
    pub(super) fn parse(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }

    // All or nothing, as the macOS list of dictionaries.
    pub(super) fn all_objects(&self) -> bool {
        self.objects.iter().all(Value::is_object)
    }
}

fn text(object: &Value, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn integer(object: &Value, key: &str) -> Option<i64> {
    let value = object.get(key)?;
    value
        .as_i64()
        .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
}

fn flag(object: &Value, key: &str) -> bool {
    object
        .get(key)
        .is_some_and(|value| value.as_bool().unwrap_or(false) || value.as_i64() == Some(1))
}

// The Linux file has no TLS mode, environment or password mode that maps onto the macOS ones: its
// `ssl-mode` numbers and `tag` values are not known, so they stay out.
pub(super) fn entry(object: &Value) -> Entry {
    let key_path = text(object, "ssh-key-path").filter(|path| !path.trim().is_empty());
    Entry {
        id: text(object, "id"),
        name: text(object, "name"),
        driver: text(object, "db-driver"),
        host: text(object, "db-host"),
        port: integer(object, "db-port"),
        user: text(object, "db-user"),
        database_name: text(object, "db-name"),
        database_path: text(object, "db-path"),
        group_id: text(object, "group-id"),
        over_ssh: flag(object, "use-ssh-tunnel"),
        ssh_host: text(object, "ssh-host"),
        ssh_port: integer(object, "ssh-port").map(|port| port.to_string()),
        ssh_user: text(object, "ssh-user"),
        // The app has no key toggle; a saved key path is what picks key sign-in.
        use_private_key: key_path.is_some(),
        private_key_name: key_path,
        tls_mode: None,
        tls_key_paths: Vec::new(),
        // `-1` is the file's own "no TLS"; any other mode, or a certificate, is TLS not read.
        tls_unread: integer(object, "ssl-mode").is_some_and(|mode| mode != -1)
            || ["ssl-key-path-1", "ssl-key-path-2", "ssl-key-path-3"]
                .iter()
                .any(|key| text(object, key).is_some_and(|path| !path.trim().is_empty())),
        environment: None,
        // Command Line is the one password mode the file records.
        database_password_mode: flag(object, "db-use-command-line-password").then_some(3),
        server_password_mode: None,
    }
}

pub(super) fn groups(list: &ObjectList) -> HashMap<String, Group> {
    if !list.all_objects() {
        return HashMap::new();
    }
    let mut groups = HashMap::with_capacity(list.objects.len());
    for object in &list.objects {
        if let (Some(id), Some(name)) = (text(object, "id"), text(object, "name")) {
            groups.insert(
                id,
                Group {
                    name,
                    parent: text(object, "group-id"),
                },
            );
        }
    }
    groups
}

#[derive(Deserialize, Default)]
pub(super) struct Settings {
    #[serde(rename = "shared-folder-paths", default)]
    shared_folder_paths: Vec<Value>,
}

impl Settings {
    pub(super) fn parse(data: &[u8]) -> Self {
        serde_json::from_slice(data).unwrap_or_default()
    }

    pub(super) fn shared_folder_paths(&self) -> Vec<String> {
        self.shared_folder_paths
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_linux_connection_maps_onto_the_macos_keys() {
        let list = ObjectList::parse(
            br#"{"objects":[{"id":"l1","name":"Shop","db-driver":"PostgreSQL","db-host":"db","db-port":"5433",
            "use-ssh-tunnel":1,"ssh-host":"bastion","ssh-port":"2222","ssh-user":"deploy","ssh-key-path":"/k/id",
            "ssl-mode":2,"tag":1,"db-use-command-line-password":true,"group-id":"g1"}],"updated_at":1}"#,
        )
        .expect("a list");
        let entry = entry(&list.objects[0]);
        assert_eq!(entry.name.as_deref(), Some("Shop"));
        assert_eq!(entry.port, Some(5433));
        assert!(entry.over_ssh);
        assert!(entry.use_private_key);
        assert_eq!(entry.ssh_port.as_deref(), Some("2222"));
        assert_eq!(entry.tls_mode, None);
        assert_eq!(entry.environment, None);
        assert_eq!(entry.database_password_mode, Some(3));
        assert_eq!(entry.group_id.as_deref(), Some("g1"));
    }

    #[test]
    fn an_empty_key_path_means_password_sign_in() {
        let list =
            ObjectList::parse(br#"{"objects":[{"name":"A","use-ssh-tunnel":0,"ssh-key-path":" "}]}"#).expect("a list");
        let entry = entry(&list.objects[0]);
        assert!(!entry.over_ssh);
        assert!(!entry.use_private_key);
        assert_eq!(entry.private_key_name, None);
    }

    #[test]
    fn settings_list_only_text_shared_folders() {
        let settings = Settings::parse(br#"{"theme":2,"shared-folder-paths":["/q/team",3,null]}"#);
        assert_eq!(settings.shared_folder_paths(), ["/q/team"]);
        assert!(Settings::parse(b"not json").shared_folder_paths().is_empty());
    }
}
