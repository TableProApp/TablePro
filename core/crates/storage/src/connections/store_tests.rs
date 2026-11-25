#![expect(
    clippy::disallowed_types,
    reason = "JSON in a test is written with json!; its key order means nothing to the store"
)]

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::json;
use tablepro_core::{AiPolicy, AuthMode, ExternalAccess, SafeModeLevel, TlsConfig};
use tempfile::TempDir;
use uuid::Uuid;

use super::*;
use crate::journal::recording::Recording;
use crate::store_identity::StoreContinuity;
use crate::{ConnectionColor, ConnectionGroupName, StoragePaths};

fn paths(root: &TempDir) -> StoragePaths {
    StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro")
}

fn store(root: &TempDir) -> ConnectionStore {
    ConnectionStore::new(&paths(root))
}

fn plain(name: &str) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: name.to_owned(),
        driver_id: "postgres".to_owned(),
        host: "db.internal".to_owned(),
        port: 5432,
        database: "app".to_owned(),
        username: "app".to_owned(),
        tls: TlsConfig::verify_full(),
        safe_mode: SafeModeLevel::Off,
        external_access: ExternalAccess::ReadOnly,
        ai_policy: AiPolicy::Ask,
        query_timeout_secs: None,
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
        details: Default::default(),
        device: Default::default(),
        unknown: Default::default(),
    }
}

/// A connection with every field the macOS app's `Connection` has a home for set.
fn every_field() -> SavedConnection {
    let profile = Uuid::new_v4();
    SavedConnection {
        ssh: Some(SavedSshConfig {
            host: "bastion".to_owned(),
            port: Some(2222),
            username: Some("ops".to_owned()),
            jump_hosts: vec!["jump@edge:22".to_owned()],
            auth: SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/ops/.ssh/id_ed25519")),
                has_passphrase: true,
            },
        }),
        color: Some(ConnectionColor::Red),
        details: ConnectionDetails {
            startup_sql: Some("SET search_path TO app".to_owned()),
            ai_rules: Some("Never touch billing".to_owned()),
            ai_allowed_tools: BTreeSet::from(["list_tables".to_owned(), "describe_table".to_owned()]),
            ssh_profile_id: Some(profile),
            ssh_route: Some(SshRoute {
                version: 1,
                publisher: Uuid::new_v4(),
                basis: "4f1d".to_owned(),
                hops: vec![SshRouteHop {
                    id: Uuid::new_v4(),
                    alias: "edge".to_owned(),
                    host: "203.0.113.4".to_owned(),
                    port: 22,
                    username: "jump".to_owned(),
                }],
                target: SshRouteTarget {
                    alias: "bastion".to_owned(),
                    host: "10.0.0.5".to_owned(),
                    port: 2222,
                    username: "ops".to_owned(),
                },
                unknown: BTreeMap::new(),
            }),
            credential_profile_id: Some(Uuid::new_v4()),
            credential_reference: Some(CredentialReference::AwsSecretsManager {
                secret_id: "prod/db".to_owned(),
                json_key: Some("password".to_owned()),
            }),
            redis_database: Some(3),
            additional_fields: BTreeMap::from([
                ("mongoAuthSource".to_owned(), "admin".to_owned()),
                ("preConnectScript".to_owned(), "./vpn.sh".to_owned()),
            ]),
        },
        device: DeviceOnly {
            local_only: true,
            is_sample: true,
            origin: ConnectionOrigin::Known(KnownOrigin::Imported),
            password_source: Some(LocalPasswordSource::Command {
                shell: "pass show db".to_owned(),
                reuse_seconds: Some(300),
            }),
            cloudflare_tunnel: Some(CloudflareTunnel {
                access_hostname: "db.example.com".to_owned(),
                local_port: Some(15432),
                auth_method: CloudflareAuth::ServiceToken,
                expose_to_lan: false,
                binary_path: String::new(),
            }),
            cloud_sql_proxy: Some(CloudSqlProxy {
                instance_connection_name: "p:r:i".to_owned(),
                auth_mode: CloudSqlAuth::ApplicationDefault,
                use_iam_auth: true,
                use_private_ip: false,
                local_port: None,
                binary_path: String::new(),
            }),
            socks_proxy: Some(SocksProxy {
                host: "proxy".to_owned(),
                port: 1080,
                username: "u".to_owned(),
            }),
            tunnel_command: Some(TunnelCommand {
                method: TunnelCommandMethod::Kubectl,
                command: String::new(),
                executable_path: String::new(),
                kubernetes_namespace: "db".to_owned(),
                kubernetes_resource: "svc/postgres".to_owned(),
                kubernetes_context: "prod".to_owned(),
                aws_target: String::new(),
                aws_profile: String::new(),
                aws_region: String::new(),
            }),
        },
        ..plain("everything")
    }
}

#[test]
fn every_field_round_trips_through_the_file() {
    let root = TempDir::new().expect("tempdir");
    let saved = every_field();

    store(&root).upsert_blocking(saved.clone()).expect("save");
    let reread = store(&root).load_blocking().expect("load");

    assert_eq!(reread.to_vec(), vec![saved]);
}

#[test]
fn unknown_keys_survive_a_rewrite_at_every_level() {
    let root = TempDir::new().expect("tempdir");
    let id = "550e8400-e29b-41d4-a716-446655440000";
    let path = paths(&root).connections_file();
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dir");
    let file = json!({
        "version": 1,
        "connections": [{
            "id": id, "name": "n", "driver_id": "postgres", "host": "h", "port": 5432, "database": "d",
            "username": "u", "tls": {"mode": "disable"}, "safe_mode": "off", "external_access": "read_only",
            "ai_policy": "ask", "project_id": "CBCAF15E-97D4-4B75-8D5D-01D586CADC97",
            "ssh_route": {"version": 1, "publisher": id, "basis": "b", "hops": [],
                "target": {"alias": "a", "host": "h", "port": 22, "username": "u"}, "signed_by": "newer"},
            "origin": "shared_vault"
        }],
        "ssh_profiles": [{"id": id, "name": "p", "host": "h", "auth": {"kind": "agent"}, "totp_mode": "prompt_at_connect"}]
    });
    std::fs::write(&path, serde_json::to_vec(&file).expect("json")).expect("seed");
    let store = store(&root);

    let mut connection = store.load_blocking().expect("load")[0].clone();
    connection.name = "renamed".to_owned();
    store.upsert_blocking(connection).expect("rewrite");
    let raw: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).expect("read")).expect("json");

    let entry = &raw["connections"][0];
    assert_eq!(entry["name"], "renamed");
    assert_eq!(entry["project_id"], "CBCAF15E-97D4-4B75-8D5D-01D586CADC97");
    assert_eq!(entry["ssh_route"]["signed_by"], "newer");
    assert_eq!(entry["origin"], "shared_vault");
    assert_eq!(raw["ssh_profiles"][0]["totp_mode"], "prompt_at_connect");
}

#[test]
fn a_newer_enum_value_holds_one_entry_and_leaves_the_list_writable() {
    let root = TempDir::new().expect("tempdir");
    let path = paths(&root).connections_file();
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dir");
    let mut newer = serde_json::to_value(plain("newer")).expect("json");
    newer["safe_mode"] = json!("paranoid");
    let file =
        json!({"version": 1, "connections": [newer.clone(), serde_json::to_value(plain("kept")).expect("json")]});
    std::fs::write(&path, serde_json::to_vec(&file).expect("json")).expect("seed");
    let store = store(&root);

    let list = store.list_blocking().expect("the list");
    store.upsert_blocking(plain("added")).expect("a write");
    let raw: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).expect("read")).expect("json");

    assert_eq!(list.connections.len(), 1);
    assert_eq!(
        list.unreadable.to_vec(),
        vec![Uuid::parse_str(newer["id"].as_str().expect("id")).expect("uuid")]
    );
    let entries = raw["connections"].as_array().expect("entries");
    assert_eq!(entries.len(), 3);
    assert!(entries.contains(&newer));
}

#[test]
fn a_readable_copy_takes_the_place_of_a_held_one() {
    let root = TempDir::new().expect("tempdir");
    let path = paths(&root).connections_file();
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dir");
    let readable = plain("pulled");
    let mut newer = serde_json::to_value(&readable).expect("json");
    newer["auth_mode"] = json!("from_the_future");
    std::fs::write(
        &path,
        serde_json::to_vec(&json!({"version": 1, "connections": [newer]})).expect("json"),
    )
    .expect("seed");
    let store = store(&root);

    store.upsert_blocking(readable.clone()).expect("save");

    let list = store.list_blocking().expect("the list");
    assert_eq!(list.connections.to_vec(), vec![readable]);
    assert!(list.unreadable.is_empty());
}

#[test]
fn a_favourite_held_connection_stays_a_favourite() {
    let root = TempDir::new().expect("tempdir");
    let path = paths(&root).connections_file();
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dir");
    let held = plain("held");
    let mut newer = serde_json::to_value(&held).expect("json");
    newer["tls"] = json!({"mode": "quantum"});
    let file = json!({"version": 1, "connections": [newer], "favorites": [held.id]});
    std::fs::write(&path, serde_json::to_vec(&file).expect("json")).expect("seed");
    let store = store(&root);

    store.upsert_blocking(plain("beside")).expect("a write");

    assert_eq!(
        store.list_blocking().expect("the list").favorites.to_vec(),
        vec![held.id]
    );
}

#[test]
fn an_export_carries_nothing_this_device_alone_holds() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let mut saved = every_field();
    saved.unknown.insert("from_a_newer_build".to_owned(), json!("x"));
    store.upsert_blocking(saved.clone()).expect("save");

    let exported: serde_json::Value = serde_json::from_slice(&store.export_blocking().expect("export")).expect("json");

    let entry = &exported["connections"][0];
    for key in [
        "local_only",
        "is_sample",
        "origin",
        "password_source",
        "cloudflare_tunnel",
        "cloud_sql_proxy",
        "socks_proxy",
        "tunnel_command",
        "startup_sql",
        "ai_rules",
        "ai_allowed_tools",
        "ssh_profile_id",
        "ssh_route",
        "credential_profile_id",
        "credential_reference",
        "from_a_newer_build",
    ] {
        assert!(entry.get(key).is_none(), "{key} left the device: {entry}");
    }
    assert_eq!(entry["redis_database"], 3);
    assert_eq!(entry["additional_fields"], json!({"mongoAuthSource": "admin"}));
    assert!(exported.get("store").is_none());
}

#[test]
fn an_import_takes_no_command_or_source_a_crafted_file_brings() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let mut crafted = serde_json::to_value(every_field()).expect("json");
    crafted["additional_fields"]["awsProfileName"] = json!("prod");
    let file = serde_json::to_vec(&json!({"version": 1, "connections": [crafted]})).expect("json");

    store
        .import_blocking(std::path::Path::new("crafted.json"), &file)
        .expect("import");

    let imported = store.load_blocking().expect("load")[0].clone();
    assert_eq!(imported.device, DeviceOnly::default());
    assert_eq!(
        imported.details,
        ConnectionDetails {
            redis_database: Some(3),
            additional_fields: BTreeMap::from([("mongoAuthSource".to_owned(), "admin".to_owned())]),
            ..ConnectionDetails::default()
        }
    );
}

#[test]
fn importing_its_own_export_updates_rather_than_doubles() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    store.upsert_blocking(every_field()).expect("save");
    let exported = store.export_blocking().expect("export");

    let report = store
        .import_blocking(std::path::Path::new("mine.json"), &exported)
        .expect("import");

    assert_eq!((report.added, report.updated), (0, 1));
    assert_eq!(store.load_blocking().expect("load")[0].device, every_field().device);
}

#[test]
fn profiles_are_saved_replaced_and_deleted_by_id() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let mut ssh = SshProfile {
        id: Uuid::new_v4(),
        name: "Bastion".to_owned(),
        ssh: SavedSshConfig {
            host: "bastion".to_owned(),
            port: None,
            username: None,
            jump_hosts: Vec::new(),
            auth: SavedSshAuth::Agent,
        },
        unknown: BTreeMap::new(),
    };
    let credential = CredentialProfile {
        id: Uuid::new_v4(),
        name: "Readonly".to_owned(),
        username: "reader".to_owned(),
        password: CredentialPassword::Local {
            source: LocalPasswordSource::File {
                path: PathBuf::from("/run/secrets/db"),
            },
        },
        secure_field_ids: Vec::new(),
        order: 0,
        unknown: BTreeMap::new(),
    };

    store.save_ssh_profile_blocking(ssh.clone()).expect("save");
    ssh.name = "Edge".to_owned();
    store.save_ssh_profile_blocking(ssh.clone()).expect("replace");
    store
        .save_credential_profile_blocking(credential.clone())
        .expect("save");
    let list = store.list_blocking().expect("the list");

    assert_eq!(list.ssh_profiles.to_vec(), vec![ssh.clone()]);
    assert_eq!(list.credential_profiles.to_vec(), vec![credential.clone()]);
    assert_eq!(
        store.delete_ssh_profile_blocking(ssh.id).expect("delete"),
        RemoveOutcome::Removed
    );
    assert_eq!(
        store.delete_credential_profile_blocking(ssh.id).expect("delete"),
        RemoveOutcome::NotPresent
    );
}

#[test]
fn each_write_raises_the_sequence_and_keeps_the_generation() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    assert_eq!(store.identity_blocking().expect("identity"), None);

    store.upsert_blocking(plain("a")).expect("save");
    let first = store.identity_blocking().expect("identity").expect("stamped");
    store.upsert_blocking(plain("b")).expect("save");
    let second = store.identity_blocking().expect("identity").expect("stamped");

    assert_eq!(first.sequence, 1);
    assert_eq!(second.generation, first.generation);
    assert_eq!(second.sequence, 2);
}

#[test]
fn another_process_writing_keeps_the_generation() {
    let root = TempDir::new().expect("tempdir");
    let ours = store(&root);
    let theirs = store(&root);
    ours.upsert_blocking(plain("a")).expect("save");
    let seen = ours.identity_blocking().expect("identity").expect("stamped");

    theirs.upsert_blocking(plain("b")).expect("their save");
    let now = ours.identity_blocking().expect("identity").expect("stamped");

    assert_eq!(now.compared_with(seen), StoreContinuity::Continues);
    assert!(now.sequence > seen.sequence);
}

#[test]
fn the_sequence_goes_backward_on_an_older_file() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    store.upsert_blocking(plain("a")).expect("save");
    let backup = std::fs::read(store.path()).expect("a backup");
    store.upsert_blocking(plain("b")).expect("save");
    store.upsert_blocking(plain("c")).expect("save");
    let seen = store.identity_blocking().expect("identity").expect("stamped");

    std::fs::write(store.path(), backup).expect("a Time Machine restore");
    let restored = store.identity_blocking().expect("identity").expect("stamped");

    assert_eq!(restored.compared_with(seen), StoreContinuity::WentBack);
}

#[test]
fn the_generation_changes_on_a_backup_restore() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    store.upsert_blocking(plain("a")).expect("save");
    let seen = store.identity_blocking().expect("identity").expect("stamped");

    let restored = store.start_new_generation_blocking().expect("restored");

    assert_eq!(restored.compared_with(seen), StoreContinuity::NewGeneration);
    assert_eq!(store.load_blocking().expect("load").len(), 1);
}

#[test]
fn a_file_copied_in_from_another_machine_is_another_generation() {
    let here = TempDir::new().expect("tempdir");
    let there = TempDir::new().expect("tempdir");
    let ours = store(&here);
    let theirs = store(&there);
    ours.upsert_blocking(plain("a")).expect("save");
    theirs.upsert_blocking(plain("b")).expect("save");
    let seen = ours.identity_blocking().expect("identity").expect("stamped");

    std::fs::copy(theirs.path(), ours.path()).expect("copied in");
    let copied = ours.identity_blocking().expect("identity").expect("stamped");

    assert_eq!(copied.compared_with(seen), StoreContinuity::NewGeneration);
}

#[test]
fn a_reset_list_starts_a_new_generation() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    store.upsert_blocking(plain("a")).expect("save");
    let seen = store.identity_blocking().expect("identity").expect("stamped");
    std::fs::write(store.path(), b"{ broken").expect("damage");
    let _ = store.load_blocking();

    store
        .reset_unreadable_blocking(std::time::SystemTime::now())
        .expect("reset");
    store.upsert_blocking(plain("b")).expect("save");
    let fresh = store.identity_blocking().expect("identity").expect("stamped");

    assert_eq!(fresh.compared_with(seen), StoreContinuity::NewGeneration);
}

fn journaled(root: &TempDir) -> (ConnectionStore, Arc<Recording>) {
    let store = store(root);
    let journal = Arc::new(Recording::default());
    store.set_journal(Some(journal.clone()));
    (store, journal)
}

fn ssh_profile() -> SshProfile {
    SshProfile {
        id: Uuid::new_v4(),
        name: "p".to_owned(),
        ssh: SavedSshConfig {
            host: "h".to_owned(),
            port: None,
            username: None,
            jump_hosts: Vec::new(),
            auth: SavedSshAuth::Agent,
        },
        unknown: BTreeMap::new(),
    }
}

#[test]
fn every_connection_and_tag_write_tells_the_journal() {
    let root = TempDir::new().expect("tempdir");
    let (store, journal) = journaled(&root);
    let connection = plain("a");
    let connections = || vec![RecordKind::Connection];
    let tag_name = |text: &str| ConnectionTagName::new(text).expect("a tag name");

    store.upsert_blocking(connection.clone()).expect("upsert");
    store
        .insert_after_blocking(plain("b"), connection.id)
        .expect("insert after");
    store
        .update_blocking(connection.id, |saved| saved.host = "elsewhere".to_owned())
        .expect("update");
    store.touch_last_opened_blocking(connection.id).expect("touch");
    store.add_favorites_blocking(&[connection.id], None).expect("favourite");
    store.remove_favorites_blocking(&[connection.id]).expect("unfavourite");
    assert_eq!(journal.take(), vec![connections(); 6]);

    let tag = store
        .create_tag_blocking(tag_name("prod"), ConnectionColor::Red)
        .expect("tag");
    store
        .update_tag_blocking(ConnectionTag {
            color: ConnectionColor::Blue,
            ..tag.clone()
        })
        .expect("retag");
    store.delete_tag_blocking(tag.id).expect("untag");
    assert_eq!(journal.take(), vec![vec![RecordKind::Tag]; 3]);

    store.remove_blocking(connection.id).expect("remove");
    assert_eq!(journal.take(), vec![connections()]);
}

#[test]
fn every_group_write_tells_the_journal() {
    let root = TempDir::new().expect("tempdir");
    let (store, journal) = journaled(&root);
    let connection = plain("a");
    let other = plain("b");
    store.upsert_blocking(connection.clone()).expect("upsert");
    store.upsert_blocking(other.clone()).expect("upsert");
    journal.take();
    let name = |text: &str| ConnectionGroupName::new(text).expect("a group name");
    let both = || vec![RecordKind::Connection, RecordKind::Group];

    let group = store
        .create_group_blocking(ConnectionGroup::new(name("Work"), None))
        .expect("group");
    store.rename_group_blocking(group.id, name("Office")).expect("rename");
    store
        .set_group_color_blocking(group.id, Some(ConnectionColor::Green))
        .expect("color");
    store.set_group_icon_blocking(group.id, None).expect("same icon");
    assert_eq!(journal.take(), vec![vec![RecordKind::Group]; 3]);
    store
        .move_connections_blocking(&[connection.id], Some(group.id), None)
        .expect("move");
    assert_eq!(journal.take(), vec![vec![RecordKind::Connection]]);
    store
        .move_connections_to_group_named_blocking(&[other.id], None, name("Lab"))
        .expect("file");
    store.move_groups_blocking(&[group.id], None, None).expect("reorder");
    store.delete_group_blocking(group.id).expect("ungroup");
    assert_eq!(journal.take(), vec![both(), vec![RecordKind::Group], both()]);
}

#[test]
fn every_profile_import_and_restore_write_tells_the_journal() {
    let root = TempDir::new().expect("tempdir");
    let (store, journal) = journaled(&root);
    let profile = ssh_profile();
    let credential = CredentialProfile {
        id: Uuid::new_v4(),
        name: "c".to_owned(),
        username: String::new(),
        password: CredentialPassword::Prompt,
        secure_field_ids: Vec::new(),
        order: 0,
        unknown: BTreeMap::new(),
    };

    store.save_ssh_profile_blocking(profile.clone()).expect("ssh profile");
    store.delete_ssh_profile_blocking(profile.id).expect("ssh profile gone");
    assert_eq!(journal.take(), vec![vec![RecordKind::SshProfile]; 2]);
    store
        .save_credential_profile_blocking(credential.clone())
        .expect("credential profile");
    store
        .delete_credential_profile_blocking(credential.id)
        .expect("credential profile gone");
    assert_eq!(journal.take(), vec![vec![RecordKind::CredentialProfile]; 2]);

    let list = store.list_blocking().expect("the list");
    let imported = ImportedConnection {
        connection: plain("c"),
        group_path: Vec::new(),
        replaces: None,
    };
    store.add_imported_blocking(&list, vec![imported]).expect("imported");
    let mut file: serde_json::Value = serde_json::from_slice(&store.export_blocking().expect("export")).expect("json");
    file["connections"][0]["id"] = json!(Uuid::new_v4());
    let bytes = serde_json::to_vec(&file).expect("json");
    store
        .import_blocking(std::path::Path::new("other.json"), &bytes)
        .expect("import");
    assert_eq!(journal.take(), vec![vec![RecordKind::Connection]; 2]);

    store.start_new_generation_blocking().expect("restored");
    assert_eq!(journal.take(), Vec::<Vec<RecordKind>>::new());
}

#[test]
fn a_write_that_changes_nothing_tells_nothing() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let connection = plain("a");
    store.upsert_blocking(connection.clone()).expect("save");
    let journal = Arc::new(Recording::default());
    store.set_journal(Some(journal.clone()));

    store.update_blocking(connection.id, |_| {}).expect("no change");
    store
        .remove_favorites_blocking(&[connection.id])
        .expect("not a favourite");

    assert!(journal.calls().is_empty());
}

#[test]
fn an_import_never_takes_the_id_of_a_connection_this_build_cannot_read() {
    let root = TempDir::new().expect("tempdir");
    let path = paths(&root).connections_file();
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dir");
    let original = plain("prod");
    let mut unreadable = serde_json::to_value(&original).expect("json");
    unreadable["safe_mode"] = json!("paranoid");
    std::fs::write(
        &path,
        serde_json::to_vec(&json!({"version": 1, "connections": [unreadable.clone()]})).expect("json"),
    )
    .expect("seed");
    let store = store(&root);
    let crafted = SavedConnection {
        host: "attacker.example".to_owned(),
        ..original.clone()
    };
    let file = serde_json::to_vec(&json!({"version": 1, "connections": [crafted]})).expect("json");

    let report = store
        .import_blocking(std::path::Path::new("crafted.json"), &file)
        .expect("import");

    let reread = ConnectionStore::new(&paths(&root)).list_blocking().expect("the list");
    assert_eq!(report.added, 1);
    assert_eq!(reread.connections.len(), 1);
    assert_ne!(reread.connections[0].id, original.id);
    assert_eq!(reread.unreadable.to_vec(), vec![original.id]);
    let raw: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).expect("read")).expect("json");
    assert!(raw["connections"].as_array().expect("entries").contains(&unreadable));
}

fn seeded_with_unreadable(root: &TempDir, favourite: bool) -> (ConnectionStore, SavedConnection) {
    let path = paths(root).connections_file();
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dir");
    let held = plain("held");
    let mut unreadable = serde_json::to_value(&held).expect("json");
    unreadable["auth_mode"] = json!("from_the_future");
    let favorites = if favourite { vec![held.id] } else { Vec::new() };
    let file = json!({"version": 1, "connections": [unreadable], "favorites": favorites});
    std::fs::write(&path, serde_json::to_vec(&file).expect("json")).expect("seed");
    (store(root), held)
}

#[test]
fn a_pulled_deletion_removes_a_connection_this_build_cannot_read() {
    let root = TempDir::new().expect("tempdir");
    let (store, held) = seeded_with_unreadable(&root, true);
    let mut pull = crate::cloudkit::CloudPull::default();
    pull.deleted.connections.push(held.id);

    store.apply_cloud_pull_blocking(&pull).expect("pull");

    let list = ConnectionStore::new(&paths(&root)).list_blocking().expect("the list");
    assert!(list.unreadable.is_empty());
    assert!(list.favorites.is_empty());
}

#[test]
fn a_pull_keeps_the_favourite_of_a_connection_this_build_cannot_read() {
    let root = TempDir::new().expect("tempdir");
    let (store, held) = seeded_with_unreadable(&root, true);
    let readable = plain("readable");
    store.upsert_blocking(readable.clone()).expect("save");

    store
        .apply_cloud_pull_blocking(&crate::cloudkit::CloudPull::default())
        .expect("pull");

    let list = store.list_blocking().expect("the list");
    assert_eq!(list.favorites.to_vec(), vec![held.id]);
    assert_eq!(list.unreadable.to_vec(), vec![held.id]);
}
