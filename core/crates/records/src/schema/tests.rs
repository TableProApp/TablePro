use serde_json::json;
use tablepro_core::{ClientIdentity, NetworkOptions, TlsConfig};
use tablepro_storage::query_history::Entry;
use tablepro_storage::saved_queries::SavedQuery;
use tablepro_storage::{
    ConnectionGroup, ConnectionTag, FavouriteDatabase, FavouriteTable, SavedConnection, SavedQueryFolder, SavedSshAuth,
    SavedSshConfig,
};

use super::model::{MODELS, Target, model};
use super::*;
use crate::secret_key::is_secret_key;
use crate::settings;

fn pushed_paths(fields: &'static [Field], prefix: &str, found: &mut Vec<String>) {
    for field in fields.iter().filter(|field| field.class.is_pushed()) {
        let path = if prefix.is_empty() {
            field.key.to_owned()
        } else {
            format!("{prefix}.{}", field.key)
        };
        found.push(path.clone());
        if let Some(inner) = nested(&field.ty) {
            pushed_paths(inner, &path, found);
        }
    }
}

// 0051, What syncs: every key a wire schema names passes the server's secret rule, so no field is refused by name.
#[test]
fn every_pushed_key_of_every_kind_passes_the_servers_secret_rule() {
    let mut checked = 0;
    for kind in Kind::ALL {
        let mut paths = Vec::new();
        pushed_paths(schema(kind).fields, "", &mut paths);
        for path in paths {
            let key = path.rsplit('.').next().unwrap_or(&path);
            assert!(!is_secret_key(key), "{kind}: {path}");
            checked += 1;
        }
    }
    let mut entry = Vec::new();
    pushed_paths(HISTORY_ENTRY, "", &mut entry);
    for path in entry {
        assert!(!is_secret_key(&path), "history entry: {path}");
    }
    assert!(checked > 150, "{checked}");
}

#[test]
fn every_option_of_every_settings_registry_passes_the_secret_rule() {
    for kind in [
        Kind::MacosSettings,
        Kind::IosSettings,
        Kind::LinuxSettings,
        Kind::WindowsSettings,
    ] {
        let registry = settings::registry(kind).expect("a registry");
        for category in registry.categories {
            let mut paths = Vec::new();
            pushed_paths(category.document.options(), "", &mut paths);
            for path in paths {
                let key = path.rsplit('.').next().unwrap_or(&path);
                assert!(!is_secret_key(key), "{kind} {:?}: {path}", category.id);
            }
        }
    }
}

// The core's own `has_passphrase` would be refused; it goes as `passphrase_stored`.
#[test]
fn the_cores_passphrase_flag_is_renamed_on_the_wire() {
    assert!(is_secret_key("has_passphrase"));
    let target = model("SavedConnection")
        .and_then(|model| {
            model
                .members
                .iter()
                .find(|(member, _)| *member == "ssh.auth.has_passphrase")
        })
        .map(|(_, target)| *target);

    assert_eq!(target, Some(Target::Wire("ssh_config.passphrase_stored")));
}

fn resolve(kind: Kind, path: &str) -> Option<&'static Field> {
    let mut fields = if kind == Kind::HistoryEntry {
        HISTORY_ENTRY
    } else {
        schema(kind).fields
    };
    let mut found = None;
    for step in path.split('.') {
        let field = fields.iter().find(|field| field.key == step)?;
        fields = nested(&field.ty).unwrap_or(&[]);
        found = Some(field);
    }
    found
}

// Each core model member lands on a wire member with a class, or is marked as staying on the device.
#[test]
fn every_member_of_every_core_model_has_a_place_on_the_wire() {
    for model in MODELS {
        for (member, target) in model.members {
            if let Target::Wire(path) = target {
                let field = resolve(model.kind, path).unwrap_or_else(|| panic!("{}: {member} -> {path}", model.name));
                assert!(field.class.is_pushed(), "{}: {member}", model.name);
            }
        }
    }
}

fn members(name: &str) -> Vec<&'static str> {
    let mut members: Vec<&str> = model(name)
        .expect("a model")
        .members
        .iter()
        .map(|(member, _)| *member)
        .collect();
    members.sort_unstable();
    members
}

fn sorted(mut names: Vec<&'static str>) -> Vec<&'static str> {
    names.sort_unstable();
    names
}

// Each destructuring below lists every member, so a store that gains one stops this compiling until the member is
// classed.
// Never called: it compiles only while it names every member.
fn exhaustive_connection(connection: SavedConnection) {
    let SavedConnection {
        id: _,
        name: _,
        driver_id: _,
        host: _,
        port: _,
        database: _,
        username: _,
        tls,
        safe_mode: _,
        external_access: _,
        ai_policy: _,
        query_timeout_secs: _,
        auth_mode: _,
        ssh,
        last_opened_at: _,
        color: _,
        group_id: _,
        order: _,
        tags: _,
        icon: _,
        options,
    } = connection;
    let TlsConfig {
        mode: _,
        ca_file: _,
        client_identity,
        server_name: _,
    } = tls;
    if let Some(ClientIdentity { certificate: _, key: _ }) = client_identity {}
    let NetworkOptions {
        dns_seed_list: _,
        auth_database: _,
        replica_set: _,
        more_hosts: _,
        channel_binding: _,
    } = options;
    if let Some(SavedSshConfig {
        host: _,
        port: _,
        username: _,
        jump_hosts: _,
        auth,
    }) = ssh
    {
        match auth {
            SavedSshAuth::PrivateKey {
                path: _,
                has_passphrase: _,
            }
            | SavedSshAuth::Agent
            | SavedSshAuth::Password
            | SavedSshAuth::KeyboardInteractive => {}
        }
    }
}

#[test]
fn the_connection_table_names_every_member_the_store_holds() {
    let _ = exhaustive_connection;
    assert_eq!(
        members("SavedConnection"),
        sorted(vec![
            "id",
            "name",
            "driver_id",
            "host",
            "port",
            "database",
            "username",
            "tls.mode",
            "tls.ca_file",
            "tls.client_identity.certificate",
            "tls.client_identity.key",
            "tls.server_name",
            "safe_mode",
            "external_access",
            "ai_policy",
            "query_timeout_secs",
            "auth_mode",
            "ssh",
            "ssh.host",
            "ssh.port",
            "ssh.username",
            "ssh.jump_hosts",
            "ssh.auth.kind",
            "ssh.auth.path",
            "ssh.auth.has_passphrase",
            "last_opened_at",
            "color",
            "group_id",
            "order",
            "tags",
            "icon",
            "options.dns_seed_list",
            "options.auth_database",
            "options.replica_set",
            "options.more_hosts",
            "options.channel_binding",
        ])
    );
}

#[test]
fn the_group_and_tag_tables_name_every_member_the_store_holds() {
    let exhaustive_group = |group: ConnectionGroup| {
        let ConnectionGroup {
            id: _,
            name: _,
            parent_id: _,
            order: _,
            color: _,
            icon: _,
        } = group;
    };
    let _ = exhaustive_group;
    assert_eq!(
        members("ConnectionGroup"),
        sorted(vec!["id", "name", "parent_id", "order", "color", "icon"])
    );

    let exhaustive_tag = |tag: ConnectionTag| {
        let ConnectionTag {
            id: _,
            name: _,
            color: _,
        } = tag;
    };
    let _ = exhaustive_tag;
    assert_eq!(members("ConnectionTag"), sorted(vec!["id", "name", "color"]));
}

#[test]
fn the_favourite_tables_name_every_member_the_store_holds() {
    let exhaustive_favourites = |table: FavouriteTable, database: FavouriteDatabase| {
        let FavouriteTable {
            connection_id: _,
            database: _,
            schema: _,
            name: _,
        } = table;
        let FavouriteDatabase {
            connection_id: _,
            database: _,
            environment: _,
        } = database;
    };
    let _ = exhaustive_favourites;
    assert_eq!(
        members("FavouriteTable"),
        sorted(vec!["connection_id", "database", "schema", "name"])
    );
    assert_eq!(
        members("FavouriteDatabase"),
        sorted(vec!["connection_id", "database", "environment"])
    );
}

#[test]
fn the_saved_query_tables_name_every_member_the_store_holds() {
    let exhaustive_queries = |query: SavedQuery, folder: SavedQueryFolder| {
        let SavedQuery {
            id: _,
            name: _,
            query: _,
            connection_id: _,
            connection_name: _,
            keyword: _,
            folder_id: _,
            order: _,
            created_at: _,
            updated_at: _,
        } = query;
        let SavedQueryFolder {
            id: _,
            connection_id: _,
            name: _,
            parent_id: _,
            order: _,
            created_at: _,
            updated_at: _,
        } = folder;
    };
    let _ = exhaustive_queries;
    assert_eq!(
        members("SavedQuery"),
        sorted(vec![
            "id",
            "name",
            "query",
            "connection_id",
            "connection_name",
            "keyword",
            "folder_id",
            "order",
            "created_at",
            "updated_at",
        ])
    );
    assert_eq!(
        members("SavedQueryFolder"),
        sorted(vec![
            "id",
            "connection_id",
            "name",
            "parent_id",
            "order",
            "created_at",
            "updated_at"
        ])
    );
}

#[test]
fn the_history_table_names_every_member_the_store_holds() {
    let exhaustive_entry = |entry: Entry| {
        let Entry {
            id: _,
            query: _,
            driver_id: _,
            connection_id: _,
            connection_name: _,
            executed_at: _,
            duration_ms: _,
            rows_affected: _,
            success: _,
            cancelled: _,
            pinned: _,
            error: _,
        } = entry;
    };
    let _ = exhaustive_entry;
    assert_eq!(
        members("query_history::Entry"),
        sorted(vec![
            "id",
            "query",
            "driver_id",
            "connection_id",
            "connection_name",
            "executed_at",
            "duration_ms",
            "rows_affected",
            "success",
            "cancelled",
            "pinned",
            "error",
        ])
    );
}

#[test]
fn a_member_no_schema_names_is_content_and_waits_for_approval() {
    let connection = schema(Kind::Connection);

    assert_eq!(connection.role("from_a_newer_build"), Role::Content);
    assert_eq!(
        connection.class("from_a_newer_build"),
        Class::Approval(Approval::Always)
    );
    assert_eq!(connection.role("sort_order"), Role::Placement);
    assert_eq!(connection.role("group_id"), Role::Placement);
    assert_eq!(connection.role("is_favorite"), Role::Placement);
    assert_eq!(connection.role("name"), Role::Content);
    assert_eq!(schema(Kind::TableFolderItem).role("folder_id"), Role::Placement);
    assert_eq!(schema(Kind::SavedQuery).role("folder_id"), Role::Placement);
    assert_eq!(schema(Kind::Group).role("parent_id"), Role::Placement);
    assert_eq!(schema(Kind::LibraryFolder).role("parent_client_id"), Role::Placement);
}

// 0044: a lower safe mode level and a looser AI policy wait; the other way is applied.
#[test]
fn a_looser_value_waits_and_a_stricter_one_applies() {
    let safe_mode = schema(Kind::Connection).class("safe_mode_level");
    let Class::Approval(rule) = safe_mode else {
        panic!("safe mode is approval-required");
    };

    assert!(rule.waits(Some(&json!("readOnly")), Some(&json!("silent"))));
    assert!(!rule.waits(Some(&json!("silent")), Some(&json!("alertFull"))));
    assert!(rule.waits(Some(&json!("silent")), Some(&json!("fromTheFuture"))));
    assert!(rule.waits(Some(&json!("alert")), None));
    assert!(!rule.waits(Some(&json!("alert")), Some(&json!("alert"))));
    let Class::Approval(access) = schema(Kind::Connection).class("external_access") else {
        panic!("external access is approval-required");
    };
    assert!(access.waits(Some(&json!("readOnly")), Some(&json!("readWrite"))));
    assert!(!access.waits(Some(&json!("readWrite")), Some(&json!("blocked"))));
    assert!(Approval::WhenOn.waits(Some(&json!(false)), Some(&json!(true))));
    assert!(!Approval::WhenOn.waits(Some(&json!(true)), Some(&json!(false))));
    assert!(Approval::WhenHigher.waits(Some(&json!(10)), Some(&json!(50))));
    assert!(!Approval::WhenHigher.waits(Some(&json!(50)), Some(&json!(10))));
}

#[test]
fn destinations_scripts_and_allowlists_wait_and_names_apply() {
    let connection = schema(Kind::Connection);
    for key in [
        "type",
        "host",
        "port",
        "database",
        "username",
        "ssh_config",
        "ssl_config",
        "ssh_route",
        "startup_commands",
        "ai_rules",
        "ai_always_allowed_tools",
        "credential_reference",
    ] {
        assert!(matches!(connection.class(key), Class::Approval(_)), "{key}");
    }
    for key in ["name", "color", "sort_order", "tag_ids", "query_timeout_seconds"] {
        assert_eq!(connection.class(key), Class::Inert, "{key}");
    }
    assert_eq!(connection.class("password_source"), Class::DeviceOnly);
    assert_eq!(schema(Kind::LibraryConnection).class("startupCommands"), Class::Dropped);
    assert_eq!(schema(Kind::LibraryConnection).class("tunnelCommand"), Class::Dropped);
}

// A driver's field takes the class its driver declares; a team drops scripts on pull (0051, What syncs).
#[test]
fn a_driver_field_is_classed_by_the_trust_its_driver_declares() {
    assert_eq!(entry_class(Scope::Personal, Some("setting")), Class::Inert);
    assert_eq!(
        entry_class(Scope::Personal, Some("destination")),
        Class::Approval(Approval::Always)
    );
    assert_eq!(
        entry_class(Scope::Personal, Some("ownDevices")),
        Class::Approval(Approval::Always)
    );
    assert_eq!(entry_class(Scope::Team, Some("ownDevices")), Class::Dropped);
    assert_eq!(entry_class(Scope::Personal, Some("secret")), Class::DeviceOnly);
    assert_eq!(entry_class(Scope::Personal, None), Class::Approval(Approval::Always));
}

// 0051, Key object bodies.
#[test]
fn key_object_bodies_name_exactly_the_members_0051_lists() {
    let keys = |kind: Kind| -> Vec<&str> { schema(kind).fields.iter().map(|field| field.key).collect() };

    assert_eq!(
        keys(Kind::KeyAccount),
        ["suite", "kind", "ik", "ask", "aek", "sig", "replace_sig"]
    );
    assert_eq!(keys(Kind::KeyMember), keys(Kind::KeyAccount));
    assert_eq!(keys(Kind::KeyDevice), ["suite", "dek", "dsk", "sig"]);
    assert_eq!(keys(Kind::KeyRecovery), ["suite", "nonce", "ct"]);
    assert_eq!(
        keys(Kind::KeyReset),
        ["suite", "av", "key_device", "account", "device", "recovery"]
    );
    assert_eq!(keys(Kind::KeyCancel), ["suite", "sig"]);
    assert_eq!(keys(Kind::KeyRequest), ["suite", "key_device", "dek", "dsk", "commit"]);
    assert_eq!(keys(Kind::KeySas), ["suite", "key_device", "dek", "dsk", "r", "reason"]);
    assert_eq!(
        keys(Kind::KeyVersion),
        ["suite", "start", "kid", "signer", "signer_av", "sig"]
    );
    assert_eq!(
        keys(Kind::KeyWrap),
        ["suite", "enc", "ct", "wrapper", "wrapper_av", "wrapper_device", "sig"]
    );
    assert_eq!(keys(Kind::KeyRing), ["suite", "nonce", "ct"]);
    assert_eq!(keys(Kind::SecretEnvelope), ["suite", "kv", "nonce", "ct"]);
    assert_eq!(keys(Kind::HistoryEntry), ["suite", "kv", "nonce", "ct"]);
}

#[test]
fn the_team_librarys_folder_and_query_keep_the_keys_the_facade_reads() {
    let keys = |kind: Kind| -> Vec<&str> { schema(kind).fields.iter().map(|field| field.key).collect() };

    assert_eq!(keys(Kind::LibraryFolder), ["name", "parent_client_id", "sort_order"]);
    assert_eq!(
        keys(Kind::LibraryQuery),
        [
            "name",
            "query",
            "keyword",
            "folder_client_id",
            "connection_client_id",
            "sort_order"
        ]
    );
}

#[test]
fn a_value_of_the_wrong_shape_does_not_conform() {
    let connection = schema(Kind::Connection);
    let ty = |key: &str| connection.field(key).map(|field| field.ty).expect("a field");

    assert!(conforms(&ty("port"), &json!(5432)));
    assert!(!conforms(&ty("port"), &json!("5432")));
    assert!(conforms(&ty("tag_ids"), &json!(["A", "B"])));
    assert!(!conforms(&ty("tag_ids"), &json!([1])));
    assert!(conforms(
        &ty("ssh_config"),
        &json!({"host": "h", "port": 22, "unknown": [1]})
    ));
    assert!(!conforms(&ty("ssh_config"), &json!({"port": "22"})));
    assert!(conforms(
        &ty("additional_fields"),
        &json!([{"id": "mongoAuthSource", "value": "admin"}])
    ));
    assert!(!conforms(
        &ty("additional_fields"),
        &json!({"mongoAuthSource": "admin"})
    ));
}

#[test]
fn every_schema_path_is_unique() {
    for kind in Kind::ALL {
        let all = paths(schema(kind).fields);
        let mut unique = all.clone();
        unique.sort();
        unique.dedup();
        assert_eq!(unique.len(), all.len(), "{kind}");
    }
}
