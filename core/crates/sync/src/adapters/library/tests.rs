use serde_json::json;
use tablepro_storage::{ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionTag, StoragePaths};

use super::*;

fn store(dir: &std::path::Path) -> ConnectionStore {
    ConnectionStore::new(&StoragePaths::under(dir, "tablepro", "app.tablepro.TablePro"))
}

fn adapter(store: &ConnectionStore, kind: Kind) -> Arc<dyn RecordAdapter> {
    LibraryAdapter::all(store)
        .into_iter()
        .find(|adapter| adapter.kind() == kind)
        .expect("an adapter for the kind")
}

const GROUP: &str = "E6C12C96-3CBD-4A0E-9F41-E36B47F35D84";
const PARENT: &str = "84BC7D00-A144-4C18-80C0-A11C6070D4F9";
const TAG: &str = "3FD0B191-5CF8-4760-84A9-92779983F3CF";

#[test]
fn a_group_goes_up_as_the_mac_writes_it() {
    let group = ConnectionGroup {
        color: Some(ConnectionColor::Slate),
        order: 3,
        parent_id: parse_uuid(PARENT),
        ..ConnectionGroup::new(ConnectionGroupName::new("Work").unwrap(), None)
    };
    let plain = ConnectionGroup::new(ConnectionGroupName::new("Home").unwrap(), None);

    assert_eq!(
        groups::group_to_wire(&group),
        json!({"name": "Work", "color": "Gray", "parent_id": PARENT, "sort_order": 3})
    );
    assert_eq!(
        groups::group_to_wire(&plain),
        json!({"name": "Home", "color": "None", "sort_order": 0})
    );
}

#[test]
fn a_tag_with_no_colour_reads_as_gray_as_the_mac_reads_it() {
    let id = parse_uuid(TAG).unwrap();

    let tag = groups::tag(id, &json!({"name": "prod", "is_preset": true}), None);

    assert_eq!(tag.color, Some(ConnectionColor::Slate));
    assert!(tag.is_preset);
    assert_eq!(
        groups::tag_to_wire(&ConnectionTag {
            color: None,
            ..tag
        }),
        json!({"name": "prod", "color": "None", "is_preset": true})
    );
}

#[test]
fn a_colour_a_newer_build_names_reads_as_the_base_s_until_the_person_changes_it() {
    let base = json!({"name": "Work", "color": "Magenta", "sort_order": 0});
    let id = parse_uuid(GROUP).unwrap();
    let stored = groups::group_to_wire(&groups::group(id, &base, None));
    let mut recoloured = stored.clone();
    recoloured["color"] = json!("Red");

    assert_eq!(stored["color"], json!("None"));
    assert_eq!(at_base(Kind::Group, &stored, Some(&base)), ["/color"]);
    assert!(at_base(Kind::Group, &recoloured, Some(&base)).is_empty());
}

#[tokio::test]
async fn groups_and_tags_round_trip_through_the_store_in_one_write_each() {
    let dir = tempfile::tempdir().unwrap();
    let store = store(dir.path());
    let groups = adapter(&store, Kind::Group);
    let tags = adapter(&store, Kind::Tag);
    let group = json!({"name": "Work", "color": "Blue", "icon_name": "server.rack", "sort_order": 2});
    let tag = json!({"name": "prod", "color": "Red", "is_preset": false});

    let before = groups.identity().await.unwrap();
    groups
        .apply(
            ScopeName::Personal,
            vec![LocalChange::Put {
                record_id: GROUP.to_owned(),
                fields: group.clone(),
            }],
        )
        .await
        .unwrap();
    let after = tags
        .apply(
            ScopeName::Personal,
            vec![LocalChange::Put {
                record_id: TAG.to_owned(),
                fields: tag.clone(),
            }],
        )
        .await
        .unwrap();
    let held = groups.records(ScopeName::Personal).await.unwrap().records;
    let elsewhere = groups.records(ScopeName::History).await.unwrap().records;

    assert!(!after.needs_refill(before));
    assert_eq!(held.len(), 1);
    assert_eq!(held[0].record_id, GROUP);
    assert_eq!(held[0].fields, group);
    assert_eq!(tags.records(ScopeName::Personal).await.unwrap().records[0].fields, tag);
    assert!(elsewhere.is_empty());

    groups
        .apply(
            ScopeName::Personal,
            vec![LocalChange::Delete {
                record_id: GROUP.to_owned(),
            }],
        )
        .await
        .unwrap();
    assert!(groups.records(ScopeName::Personal).await.unwrap().records.is_empty());
    assert_eq!(tags.records(ScopeName::Personal).await.unwrap().records.len(), 1);
}

#[tokio::test]
async fn a_new_store_starts_its_generation_and_every_kind_names_the_one_file() {
    let dir = tempfile::tempdir().unwrap();
    let store = store(dir.path());
    let adapters = LibraryAdapter::all(&store);

    let first = adapters[0].identity().await.unwrap();
    let again = adapters[1].identity().await.unwrap();

    assert_ne!(first.generation, Uuid::nil());
    assert_eq!(first, again);
    assert!(adapters.iter().all(|adapter| adapter.store() == STORE));
}

const CONNECTION: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";
const PROFILE: &str = "0F6C2A1E-6B3D-4D8E-9A51-3D7E2B1F0C44";

// `SSHConfiguration()`, as the Mac writes a connection with no tunnel.
fn no_tunnel() -> Value {
    json!({
        "agent_socket_path": "", "auth_method": "Password", "enabled": false, "host": "", "jump_hosts": [],
        "private_key_path": "", "remote_file_access": "readOnlyCopy", "remote_file_path": "", "totp_algorithm": "SHA1",
        "totp_digits": 6, "totp_mode": "none", "totp_period": 30, "username": "",
    })
}

// What a Mac writes for a connection, through the CloudKit projection.
fn mac_connection() -> Value {
    json!({
        "name": "Shop", "type": "PostgreSQL", "host": "db.internal", "port": 5432, "database": "shop", "username": "app",
        "color": "Blue", "safe_mode_level": "alertFull", "sort_order": 3, "is_favorite": true,
        "group_id": GROUP, "tag_ids": [TAG], "query_timeout_seconds": 60, "ai_policy": "askEachTime",
        "ai_always_allowed_tools": ["describe_table"],
        "ssh_config": {
            "agent_socket_path": "", "auth_method": "Private Key", "enabled": true, "host": "bastion",
            "jump_hosts": [{"auth_method": "SSH Agent", "host": "edge", "id": "9E5B6C0B-1C11-4C5B-9C8B-8E3C2C1A0B01",
                "private_key_path": "", "username": "a"}],
            "port": 22, "private_key_path": "~/.ssh/id_ed25519", "remote_file_access": "readOnlyCopy",
            "remote_file_path": "", "totp_algorithm": "SHA1", "totp_digits": 6, "totp_mode": "none",
            "totp_period": 30, "username": "ops",
        },
        "ssl_config": {"ca_certificate_path": "~/certs/ca.pem", "client_certificate_path": "", "client_key_path": "",
            "mode": "Verify Identity"},
        "additional_fields": [{"id": "connectTimeoutSeconds", "value": "30"}, {"id": "mongoAuthSource", "value": "admin"}],
        "external_access": "readOnly", "auth_mode": "password",
    })
}

fn id() -> Uuid {
    parse_uuid(CONNECTION).unwrap()
}

fn stored(fields: &Value) -> (tablepro_storage::SavedConnection, bool) {
    connection::model(id(), fields, None)
}

fn wire(saved: &tablepro_storage::SavedConnection, favorite: bool) -> Value {
    connection::to_wire(saved, favorite, None)
}

#[test]
fn a_mac_connection_reads_into_the_store_and_goes_up_as_the_mac_wrote_it() {
    let mac = mac_connection();

    let (saved, favorite) = stored(&mac);
    let mut service = mac.clone();
    service["ssh_config"]["passphrase_stored"] = json!(false);

    assert_eq!(wire(&saved, favorite), service);
    assert_eq!(
        at_base(Kind::Connection, &wire(&saved, favorite), Some(&mac)),
        ["/ssh_config/passphrase_stored"]
    );
    assert_eq!(saved.driver_id, "PostgreSQL");
    assert_eq!(saved.tls.mode, tablepro_core::TlsMode::VerifyFull);
    assert_eq!(saved.safe_mode, tablepro_core::SafeModeLevel::AlertFull);
    assert_eq!(saved.device.origin, tablepro_storage::ConnectionOrigin::Known(tablepro_storage::KnownOrigin::Synced));
    let home = std::env::home_dir().unwrap();
    assert_eq!(
        saved.ssh.as_ref().and_then(|ssh| match &ssh.auth {
            tablepro_storage::SavedSshAuth::PrivateKey { path, .. } => path.clone(),
            _ => None,
        }),
        Some(home.join(".ssh/id_ed25519"))
    );
}

#[test]
fn a_connection_with_no_tunnel_writes_the_mac_s_empty_one_and_reads_it_back_as_none() {
    let mut mac = mac_connection();
    mac["ssh_config"] = no_tunnel();

    let (saved, favorite) = stored(&mac);

    assert!(saved.ssh.is_none());
    assert_eq!(wire(&saved, favorite)["ssh_config"], no_tunnel());
}

#[test]
fn a_hop_no_build_named_takes_the_id_the_mac_derives_for_it() {
    let mut mac = mac_connection();
    mac["ssh_config"]["jump_hosts"] = json!([{"host": "one"}, {"host": "two"}]);
    let (mut saved, favorite) = stored(&mac);
    for hop in &mut saved.ssh.as_mut().unwrap().jump_hosts {
        hop.id = None;
    }

    let hops = &wire(&saved, favorite)["ssh_config"]["jump_hosts"];

    assert_eq!(hops[0]["id"], json!("5C65EB5D-E826-55C2-AAAD-83D63FD38948"));
    assert_eq!(hops[1]["id"], json!("A5C34367-6511-5075-AE51-D918B7E58610"));
}

#[test]
fn an_ios_copy_spelled_its_own_way_reads_as_the_base_and_sends_nothing() {
    let ios = json!({
        "name": "Orders", "type": "MySQL", "host": "db", "port": 3306, "database": "shop", "username": "app",
        "color": "Red", "safe_mode_level": "off", "sort_order": 0, "is_favorite": false,
        "ssl_config": {"ca_certificate_path": "", "client_certificate_path": "", "client_key_path": "", "mode": "Disabled"},
    });
    let (saved, favorite) = stored(&ios);
    let local = wire(&saved, favorite);

    let read = crate::adapters::unsettled::read(Kind::Connection, &local, Some(&ios));
    let pushed = crate::adapters::fields::with_members_of(
        Kind::Connection,
        ScopeName::Personal,
        &read,
        Some(&ios),
        &std::collections::BTreeSet::new(),
    );

    assert_eq!(pushed, ios);
}

#[test]
fn a_strict_tls_mode_and_a_teal_colour_survive_a_pull_that_leaves_them_alone() {
    let (mut saved, favorite) = stored(&mac_connection());
    saved.tls.mode = tablepro_core::TlsMode::Strict;
    saved.color = Some(ConnectionColor::Teal);
    let mut pulled = wire(&saved, favorite);
    pulled["name"] = json!("Shop 2");

    let held = connection::Held {
        saved: &saved,
        favorite,
        profile: None,
    };
    let (after, _) = connection::model(id(), &pulled, Some(held));
    let mut stricter = pulled.clone();
    stricter["ssl_config"]["mode"] = json!("Verify CA");
    let (changed, _) = connection::model(id(), &stricter, Some(held));

    assert_eq!(after.name, "Shop 2");
    assert_eq!(after.tls.mode, tablepro_core::TlsMode::Strict);
    assert_eq!(after.color, Some(ConnectionColor::Teal));
    assert_eq!(changed.tls.mode, tablepro_core::TlsMode::VerifyCa);
}

#[test]
fn values_a_newer_build_wrote_read_as_this_build_can_hold_them_and_the_base_s_value_stays() {
    let mut newer = mac_connection();
    newer["ssl_config"]["mode"] = json!("Post Quantum");
    newer["safe_mode_level"] = json!("approveEach");
    newer["ai_policy"] = json!("redacted");

    let (saved, favorite) = stored(&newer);
    let local = wire(&saved, favorite);
    let pointers = at_base(Kind::Connection, &local, Some(&newer));

    assert_eq!(saved.tls.mode, tablepro_core::TlsMode::VerifyFull);
    assert_eq!(saved.safe_mode, tablepro_core::SafeModeLevel::Alert);
    assert_eq!(saved.ai_policy, tablepro_core::AiPolicy::AppDefault);
    for pointer in ["/ssl_config/mode", "/safe_mode_level", "/ai_policy"] {
        assert!(pointers.iter().any(|held| held == pointer), "{pointer} in {pointers:?}");
    }
}

#[test]
fn the_driver_fields_go_up_as_the_mac_syncs_them() {
    let (mut saved, favorite) = stored(&mac_connection());
    let fields = &mut saved.details.additional_fields;
    fields.insert("connectTimeoutSeconds".to_owned(), "030".to_owned());
    fields.insert("queryTimeoutSeconds".to_owned(), "15".to_owned());
    fields.insert("mongoPassword".to_owned(), "hunter2".to_owned());

    let entries = &wire(&saved, favorite)["additional_fields"];

    assert_eq!(
        *entries,
        json!([{"id": "connectTimeoutSeconds", "value": "30"}, {"id": "mongoAuthSource", "value": "admin"}])
    );
}

#[test]
fn a_query_timeout_an_older_build_kept_with_the_driver_fields_moves_to_its_member() {
    let mut older = mac_connection();
    older.as_object_mut().unwrap().remove("query_timeout_seconds");
    older["additional_fields"] = json!([{"id": "queryTimeoutSeconds", "value": "45"}]);

    let (saved, _) = stored(&older);

    assert_eq!(saved.query_timeout_secs, Some(45));
    assert!(!saved.details.additional_fields.contains_key("queryTimeoutSeconds"));
}

#[test]
fn a_linked_tunnel_goes_up_with_the_profile_s_settings_and_the_link_only_while_it_is_on() {
    let (mut saved, favorite) = stored(&mac_connection());
    let profile_id = parse_uuid(PROFILE).unwrap();
    saved.details.ssh_profile_id = Some(profile_id);
    let profile = profiles::ssh(
        profile_id,
        &json!({"name": "edge", "host": "jump.example.com", "username": "deploy", "auth_method": "SSH Agent"}),
        None,
    );

    let linked = connection::to_wire(&saved, favorite, Some(&profile));
    saved.ssh.as_mut().unwrap().enabled = false;
    let off = connection::to_wire(&saved, favorite, Some(&profile));

    assert_eq!(linked["ssh_profile_id"], json!(PROFILE));
    assert_eq!(linked["ssh_config"]["host"], json!("jump.example.com"));
    assert_eq!(linked["ssh_config"]["auth_method"], json!("SSH Agent"));
    assert_eq!(linked["ssh_config"]["enabled"], json!(true));
    assert!(off.get("ssh_profile_id").is_none());
    assert_eq!(off["ssh_config"]["host"], json!("bastion"));
}

#[test]
fn a_route_another_device_published_is_neither_cleared_nor_replaced_by_one_to_the_same_hosts() {
    let route = json!({
        "basis": "b1", "hops": [], "publisher": PROFILE, "version": 1,
        "target": {"alias": "db", "host": "db.internal", "port": 5432, "username": "app"},
    });
    let mut base = mac_connection();
    base["ssh_route"] = route.clone();
    let (mut saved, favorite) = stored(&base);
    saved.details.ssh_route = None;
    let cleared = wire(&saved, favorite);
    let mut renamed = route.clone();
    renamed["target"]["alias"] = json!("primary");
    let mut same_hosts = base.clone();
    same_hosts["ssh_route"] = renamed;
    let mut elsewhere = base.clone();
    elsewhere["ssh_route"]["target"]["host"] = json!("db.other");

    assert_eq!(at_base(Kind::Connection, &cleared, Some(&base)), ["/ssh_route"]);
    assert_eq!(at_base(Kind::Connection, &same_hosts, Some(&base)), ["/ssh_route"]);
    assert!(at_base(Kind::Connection, &elsewhere, Some(&base)).is_empty());
}

#[test]
fn a_credential_profile_keeps_where_its_password_comes_from_over_a_pull_that_says_prompt() {
    let profile_id = parse_uuid(PROFILE).unwrap();
    let stored = tablepro_storage::CredentialProfile {
        id: profile_id,
        name: "ops".to_owned(),
        username: "ops".to_owned(),
        password: tablepro_storage::CredentialPassword::Reference {
            reference: tablepro_storage::CredentialReference::Env {
                variable: "OPS_PASSWORD".to_owned(),
            },
        },
        secure_field_ids: Vec::new(),
        order: 0,
        unknown: std::collections::BTreeMap::new(),
    };
    let pulled = profiles::credential_to_wire(&stored);

    let kept = profiles::credential(profile_id, &pulled, Some(&stored));
    let mut stored_mode = pulled.clone();
    stored_mode["password_mode"] = json!("stored");
    let changed = profiles::credential(profile_id, &stored_mode, Some(&stored));

    assert_eq!(pulled["password_mode"], json!("prompt"));
    assert_eq!(kept.password, stored.password);
    assert_eq!(changed.password, tablepro_storage::CredentialPassword::Stored);
}

#[test]
fn a_folder_with_no_schema_names_none_and_an_item_is_named_by_the_table_it_files() {
    let folder = folders::folder_from_wire(
        parse_uuid(GROUP).unwrap(),
        &json!({"connection_id": CONNECTION, "database": "shop", "name": "Billing", "created_at": 5}),
    )
    .unwrap();
    let item = folders::item_from_wire(&json!({
        "connection_id": CONNECTION, "database": "shop", "schema": "public", "name": "orders", "folder_id": GROUP,
    }))
    .unwrap();

    assert_eq!(
        folders::folder_to_wire(&folder),
        json!({"connection_id": CONNECTION, "database": "shop", "name": "Billing", "created_at": 5, "updated_at": 5})
    );
    assert_eq!(
        folders::item_id(&item.table),
        tablepro_records::record_id::table_folder_item(id(), "shop", Some("public"), "orders")
    );
}

#[tokio::test]
async fn a_pull_keeps_what_only_this_device_holds_and_a_local_only_connection_reads_as_one() {
    let dir = tempfile::tempdir().unwrap();
    let store = store(dir.path());
    let connections = adapter(&store, Kind::Connection);
    connections
        .apply(
            ScopeName::Personal,
            vec![LocalChange::Put {
                record_id: CONNECTION.to_owned(),
                fields: mac_connection(),
            }],
        )
        .await
        .unwrap();
    store
        .update_blocking(id(), |saved| {
            saved.device.local_only = true;
            saved.device.password_source = Some(tablepro_storage::LocalPasswordSource::File {
                path: "/keys/pw".into(),
            });
        })
        .unwrap();
    let mut renamed = mac_connection();
    renamed["name"] = json!("Shop 2");

    connections
        .apply(
            ScopeName::Personal,
            vec![LocalChange::Put {
                record_id: CONNECTION.to_owned(),
                fields: renamed,
            }],
        )
        .await
        .unwrap();
    let records = connections.records(ScopeName::Personal).await.unwrap().records;
    let saved = store.list_blocking().unwrap().connections[0].clone();

    assert_eq!(saved.name, "Shop 2");
    assert!(saved.device.local_only);
    assert!(saved.device.password_source.is_some());
    assert_eq!(records[0].standing, Standing::LocalOnly);
    assert_eq!(StoreStanding(store.clone()).standing(id()), Standing::LocalOnly);
    assert_eq!(StoreStanding(store).standing(Uuid::nil()), Standing::Unknown);
}
