#![expect(
    clippy::disallowed_types,
    reason = "JSON in a test is written with json!; its key order means nothing to the store"
)]

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;

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

pub(super) fn plain(name: &str) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: name.to_owned(),
        driver_id: "postgres".to_owned(),
        host: "db.internal".to_owned(),
        port: 5432,
        database: "app".to_owned(),
        username: "app".to_owned(),
        tls: TlsConfig::verify_full(),
        safe_mode: SafeModeLevel::Silent,
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

// Every field the macOS app's `Connection` has a home for, set.
fn every_field() -> SavedConnection {
    let profile = Uuid::new_v4();
    SavedConnection {
        ssh: Some(every_ssh_field()),
        safe_mode: SafeModeLevel::SafeModeFull,
        ai_policy: AiPolicy::AppDefault,
        tls: TlsConfig {
            mode: tablepro_core::TlsMode::VerifyCa,
            ca_file: Some(PathBuf::from("ca.pem")),
            client_identity: Some(tablepro_core::ClientIdentity {
                certificate: PathBuf::from("client.pem"),
                key: PathBuf::new(),
            }),
            server_name: None,
            unknown: BTreeMap::from([("pinned".to_owned(), json!("sha256/abc"))]),
        },
        icon: Some(crate::LibraryIcon::Symbol(
            crate::SymbolName::new("cylinder.split.1x2").expect("a symbol"),
        )),
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
        device: every_device_field(),
        ..plain("everything")
    }
}

fn every_ssh_field() -> SavedSshConfig {
    SavedSshConfig {
        enabled: false,
        host: "bastion".to_owned(),
        port: Some(2222),
        username: Some("ops".to_owned()),
        jump_hosts: vec![
            SshJumpHost::new("edge", Some(22), Some("jump".to_owned())),
            SshJumpHost {
                id: Some(Uuid::new_v4()),
                auth: Some(SshJumpAuth::PrivateKey),
                key_path: Some(PathBuf::from("~/.ssh/hop")),
                ..SshJumpHost::new("inner", None, None)
            },
        ],
        auth: SavedSshAuth::Password,
        kept_key_path: Some(PathBuf::from("/home/ops/.ssh/id_ed25519")),
        agent_socket: Some(PathBuf::from("~/.1password/agent.sock")),
        totp: SshTotp {
            mode: SshTotpMode::AutoGenerate,
            algorithm: SshTotpAlgorithm::Sha256,
            digits: 8,
            period: 60,
        },
        remote_file: SshRemoteFile {
            path: Some("~/data/app.db".to_owned()),
            access: RemoteFileAccess::OnServer,
        },
        unknown: BTreeMap::from([("compression".to_owned(), json!(true))]),
    }
}

fn every_device_field() -> DeviceOnly {
    DeviceOnly {
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
        tls_mode_unsettled: true,
        ssh_profile_unlinked: true,
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
            enabled: true,
            kept_key_path: None,
            agent_socket: None,
            totp: Default::default(),
            remote_file: Default::default(),
            unknown: Default::default(),
        },
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
        ssh: SavedSshConfig::new("h", SavedSshAuth::Agent),
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
            color: Some(ConnectionColor::Blue),
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

    store.lay_out_blocking(&[held.id], ConnectionList::clone).expect("pull");

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

    // As the CloudKit layout does, which places only the connections this build reads.
    let readable_only = |list: &ConnectionList| ConnectionList {
        favorites: list
            .favorites
            .iter()
            .copied()
            .filter(|id| list.connections.iter().any(|saved| saved.id == *id))
            .collect(),
        ..list.clone()
    };
    store.lay_out_blocking(&[], readable_only).expect("pull");

    let list = store.list_blocking().expect("the list");
    assert_eq!(list.favorites.to_vec(), vec![held.id]);
    assert_eq!(list.unreadable.to_vec(), vec![held.id]);
}

#[test]
fn deleting_an_unreadable_connection_or_profile_removes_it_from_the_file() {
    let root = TempDir::new().expect("tempdir");
    let (store, held) = seeded_with_unreadable(&root, true);

    assert_eq!(store.remove_blocking(held.id).expect("remove"), RemoveOutcome::Removed);
    assert_eq!(
        store.remove_blocking(held.id).expect("again"),
        RemoveOutcome::NotPresent
    );

    let list = ConnectionStore::new(&paths(&root)).list_blocking().expect("the list");
    assert!(list.unreadable.is_empty());
    assert!(list.favorites.is_empty());
}

fn tag(name: &str, color: Option<ConnectionColor>) -> ConnectionTag {
    ConnectionTag {
        id: Uuid::new_v4(),
        name: ConnectionTagName::from_stored(name),
        color,
        is_preset: false,
    }
}

// What another app's store holds, values no edit would write included.
fn library_as_another_app_holds_it() -> LibraryWrite {
    let missing = Uuid::new_v4();
    let blank = ConnectionGroup {
        id: Uuid::new_v4(),
        name: ConnectionGroupName::from_stored(" "),
        parent_id: Some(missing),
        order: 9,
        color: None,
        icon: None,
    };
    let preset = ConnectionTag {
        is_preset: true,
        ..tag("production", Some(ConnectionColor::Red))
    };
    let long = tag(&"long tag name ".repeat(5), None);
    let mut first = SavedConnection {
        name: " Prod\t(EU) ".to_owned(),
        group_id: Some(blank.id),
        order: 7,
        tags: vec![preset.id, Uuid::new_v4()],
        last_opened_at: chrono::DateTime::from_timestamp_millis(1_700_000_000_123),
        ..every_field()
    };
    first.host = " db.internal ".to_owned();
    let second = SavedConnection {
        group_id: Some(missing),
        order: 3,
        tags: vec![long.id],
        ..plain("second")
    };
    LibraryWrite {
        favorites: vec![second.id, first.id],
        connections: vec![first, second],
        groups: vec![blank],
        tags: vec![preset, long],
        removing: Vec::new(),
    }
}

#[test]
fn a_library_write_keeps_every_id_and_value_as_given() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let library = library_as_another_app_holds_it();

    replace(&store, library.clone()).expect("write");
    let reread = |store: &ConnectionStore| {
        let list = store.list_blocking().expect("list");
        LibraryWrite {
            connections: list.connections.to_vec(),
            groups: list.groups.to_vec(),
            tags: list.tags.to_vec(),
            favorites: list.favorites.to_vec(),
            removing: Vec::new(),
        }
    };

    assert_eq!(reread(&store), library);
    assert_eq!(reread(&ConnectionStore::new(&paths(&root))), library);
    let touched = library.connections[1].id;
    store.touch_last_opened_blocking(touched).expect("another write");
    let after = reread(&store);
    assert_eq!(after.groups, library.groups);
    assert_eq!(after.tags, library.tags);
    assert_eq!(after.connections[0], library.connections[0]);
    assert_eq!(after.connections[1].order, 3);
}

#[test]
fn a_missing_group_or_parent_reads_as_the_top_level_and_stays_stored() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let library = library_as_another_app_holds_it();
    replace(&store, library.clone()).expect("write");

    let list = store.list_blocking().expect("list");

    let top: Vec<Uuid> = list.connections_in(None).iter().map(|saved| saved.id).collect();
    assert_eq!(top, [library.connections[1].id]);
    assert_eq!(list.group_of(&list.connections[1]), None);
    assert_eq!(list.connections[1].group_id, library.connections[1].group_id);
    let tree = list.group_tree();
    assert_eq!(tree.parent(library.groups[0].id), None);
    assert_eq!(tree.walk().len(), 1);
}

#[test]
fn a_library_write_is_one_journal_call_naming_each_record() {
    let root = TempDir::new().expect("tempdir");
    let (store, journal) = journaled(&root);
    let library = library_as_another_app_holds_it();
    let ids = |list: &[RecordRef]| list.to_vec();
    let refs = |ids: &[Uuid]| ids.iter().copied().map(RecordRef::Id).collect::<Vec<_>>();

    replace(&store, library.clone()).expect("write");
    let calls = journal.take_entries();

    assert_eq!(calls.len(), 1);
    let kinds: Vec<RecordKind> = calls[0].iter().map(|entry| entry.kind).collect();
    assert_eq!(kinds, [RecordKind::Connection, RecordKind::Group, RecordKind::Tag]);
    let connection_ids: Vec<Uuid> = library.connections.iter().map(|saved| saved.id).collect();
    assert_eq!(ids(&calls[0][0].written), refs(&connection_ids));
    assert!(calls[0].iter().all(|entry| entry.deleted.is_empty()));

    let kept = LibraryWrite {
        connections: vec![library.connections[0].clone()],
        favorites: vec![library.connections[0].id],
        ..library.clone()
    };
    replace(&store, kept).expect("drop one");
    let calls = journal.take_entries();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0][0].kind, RecordKind::Connection);
    assert_eq!(ids(&calls[0][0].deleted), refs(&[library.connections[1].id]));
    assert_eq!(
        ids(&calls[0][0].written),
        refs(&[library.connections[0].id]),
        "its favourite place moved"
    );
}

#[test]
fn a_library_write_refuses_an_id_named_twice_and_writes_nothing() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let library = library_as_another_app_holds_it();
    let twice = LibraryWrite {
        tags: vec![library.tags[0].clone(), library.tags[0].clone()],
        ..library
    };

    let repeated = twice.tags[0].id;

    let refused = replace(&store, twice);

    assert!(
        matches!(refused, Err(StorageError::RepeatedId { id }) if id == repeated),
        "{refused:?}"
    );
    assert!(store.list_blocking().expect("list").connections.is_empty());
}

#[test]
fn a_library_write_keeps_a_connection_this_build_cannot_read_unless_it_names_it() {
    let root = TempDir::new().expect("tempdir");
    let (store, held) = seeded_with_unreadable(&root, false);
    let library = library_as_another_app_holds_it();

    replace(&store, library.clone()).expect("write");
    let list = store.list_blocking().expect("list");
    assert_eq!(list.unreadable.to_vec(), [held.id]);
    assert_eq!(list.connections.len(), library.connections.len());

    let mut named = library.clone();
    named.connections.push(SavedConnection {
        id: held.id,
        ..plain("now readable")
    });
    replace(&store, named).expect("write");
    let list = store.list_blocking().expect("list");
    assert!(list.unreadable.is_empty());
    assert!(list.connections.iter().any(|saved| saved.id == held.id));
}

#[test]
fn each_write_names_the_records_it_wrote_and_deleted() {
    let root = TempDir::new().expect("tempdir");
    let (store, journal) = journaled(&root);
    let connection = plain("a");
    let entry = |kind, written: &[Uuid], deleted: &[Uuid]| {
        JournalEntry::new(kind)
            .wrote(written.iter().copied().map(RecordRef::Id))
            .deleted(deleted.iter().copied().map(RecordRef::Id))
    };

    store.upsert_blocking(connection.clone()).expect("upsert");
    store.add_favorites_blocking(&[connection.id], None).expect("favourite");
    let tag = store
        .create_tag_blocking(ConnectionTagName::new("prod").expect("a name"), ConnectionColor::Red)
        .expect("tag");
    store
        .update_blocking(connection.id, |saved| saved.tags = vec![tag.id])
        .expect("tagged");
    store.delete_tag_blocking(tag.id).expect("untag");
    store.remove_blocking(connection.id).expect("remove");

    assert_eq!(
        journal.take_entries(),
        vec![
            vec![entry(RecordKind::Connection, &[connection.id], &[])],
            vec![entry(RecordKind::Connection, &[connection.id], &[])],
            vec![entry(RecordKind::Tag, &[tag.id], &[])],
            vec![entry(RecordKind::Connection, &[connection.id], &[])],
            vec![
                entry(RecordKind::Connection, &[connection.id], &[]),
                entry(RecordKind::Tag, &[], &[tag.id]),
            ],
            vec![entry(RecordKind::Connection, &[], &[connection.id])],
        ]
    );
    assert!(store.list_blocking().expect("list").tags.is_empty());
}

#[test]
fn an_edit_keeps_a_group_that_has_not_arrived_and_an_orphan_group_reorders_at_the_top() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let mut library = library_as_another_app_holds_it();
    let orphan = ConnectionGroup {
        id: Uuid::new_v4(),
        name: ConnectionGroupName::from_stored("Orphan"),
        parent_id: Some(Uuid::new_v4()),
        order: 0,
        color: None,
        icon: None,
    };
    library.groups.push(orphan.clone());
    replace(&store, library.clone()).expect("write");
    let waiting = library.connections[1].clone();

    let edited = store
        .update_blocking(waiting.id, |saved| saved.color = Some(ConnectionColor::Teal))
        .expect("edit")
        .expect("the entry");
    store
        .move_groups_blocking(&[orphan.id], None, None)
        .expect("an orphan moves within the top");

    assert_eq!(
        edited.group_id, waiting.group_id,
        "a group that has not arrived was dropped"
    );
    let list = store.list_blocking().expect("list");
    let moved = list
        .groups
        .iter()
        .find(|group| group.id == orphan.id)
        .expect("the orphan");
    assert_eq!(moved.parent_id, None);
}

fn stored_group(name: &str, parent_id: Option<Uuid>) -> ConnectionGroup {
    ConnectionGroup {
        id: Uuid::new_v4(),
        name: ConnectionGroupName::from_stored(name),
        parent_id,
        order: 0,
        color: None,
        icon: None,
    }
}

#[test]
fn an_upsert_keeps_its_place_among_connections_of_one_order() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let connections = vec![plain("a"), plain("b"), plain("c")];
    replace(
        &store,
        LibraryWrite {
            connections: connections.clone(),
            ..LibraryWrite::default()
        },
    )
    .expect("write");

    store
        .upsert_blocking(SavedConnection {
            last_opened_at: Some(chrono::Utc::now()),
            ..connections[0].clone()
        })
        .expect("stamp");

    let list = store.list_blocking().expect("list");
    let shown: Vec<Uuid> = list.connections_in(None).iter().map(|saved| saved.id).collect();
    let ids: Vec<Uuid> = connections.iter().map(|saved| saved.id).collect();
    assert_eq!(shown, ids);
}

#[test]
fn a_move_at_the_top_lifts_a_cycle_partner_out_rather_than_nesting_it() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let mut first = stored_group("First", None);
    let second = stored_group("Second", Some(first.id));
    first.parent_id = Some(second.id);
    replace(
        &store,
        LibraryWrite {
            groups: vec![first.clone(), second.clone()],
            ..LibraryWrite::default()
        },
    )
    .expect("write");

    store
        .move_groups_blocking(&[first.id], None, None)
        .expect("a move within the top");

    let list = store.list_blocking().expect("list");
    let tree = list.group_tree();
    assert_eq!(tree.parent(first.id), None);
    assert_eq!(tree.parent(second.id), None, "the partner nested in the moved group");
}

#[test]
fn an_import_files_into_a_group_that_reads_at_the_top_by_its_name() {
    let other_root = TempDir::new().expect("tempdir");
    let other = store(&other_root);
    let work = other
        .create_group_blocking(ConnectionGroup::new(
            ConnectionGroupName::new("Work").expect("a name"),
            None,
        ))
        .expect("group");
    other
        .upsert_blocking(SavedConnection {
            group_id: Some(work.id),
            ..plain("api")
        })
        .expect("save");
    let bytes = other.export_blocking().expect("export");
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let waiting = stored_group("Work", Some(Uuid::new_v4()));
    replace(
        &store,
        LibraryWrite {
            groups: vec![waiting.clone()],
            ..LibraryWrite::default()
        },
    )
    .expect("write");

    store
        .import_blocking(std::path::Path::new("other.json"), &bytes)
        .expect("import");

    let list = store.list_blocking().expect("list");
    assert_eq!(list.groups.len(), 1, "{:?}", list.groups);
    let api = list
        .connections
        .iter()
        .find(|saved| saved.name == "api")
        .expect("the import");
    assert_eq!(api.group_id, Some(waiting.id));
}

// Over the file as the store holds it now, as a host that just checked it writes.
fn replace(store: &ConnectionStore, write: LibraryWrite) -> Result<Option<String>, StorageError> {
    let over = store.read_library_blocking()?.digest;
    store.replace_library_blocking(over.as_deref(), |_| Ok::<_, StorageError>(write))
}

fn sha256_of(path: &std::path::Path) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(std::fs::read(path).expect("the file")))
}

#[test]
fn a_library_read_and_write_give_the_digest_of_the_bytes_on_disk() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    assert_eq!(store.read_library_blocking().expect("read").digest, None, "no file yet");

    let written = replace(&store, library_as_another_app_holds_it()).expect("write");

    let path = paths(&root).connections_file();
    assert_eq!(written.as_deref(), Some(sha256_of(&path).as_str()));
    let edited = std::fs::read_to_string(&path)
        .expect("the file")
        .replace("Prod", "Staging");
    std::fs::write(&path, edited).expect("an edit outside the store");
    let read = store.read_library_blocking().expect("read");
    assert_eq!(read.digest.as_deref(), Some(sha256_of(&path).as_str()));
    assert_ne!(read.digest, written);
    assert_eq!(
        replace(
            &store,
            LibraryWrite {
                connections: read.list.connections.to_vec(),
                groups: read.list.groups.to_vec(),
                tags: read.list.tags.to_vec(),
                favorites: read.list.favorites.to_vec(),
                removing: Vec::new(),
            }
        )
        .expect("a write that changes nothing"),
        read.digest
    );
}

#[test]
fn a_rebuild_keeps_only_what_it_names_and_starts_a_new_generation() {
    let root = TempDir::new().expect("tempdir");
    let (store, held) = seeded_with_unreadable(&root, false);
    let journal = Arc::new(Recording::default());
    store.save_ssh_profile_blocking(ssh_profile()).expect("a profile");
    let mut kept = plain("kept");
    kept.unknown = BTreeMap::from([("from_a_newer_build".to_owned(), json!(true))]);
    store.upsert_blocking(kept.clone()).expect("save");
    let before = store.identity_blocking().expect("identity").expect("stamped");
    store.set_journal(Some(journal.clone()));

    let rebuilt = store
        .rebuild_library_blocking(
            LibraryWrite {
                connections: vec![SavedConnection {
                    unknown: BTreeMap::new(),
                    ..kept.clone()
                }],
                ..LibraryWrite::default()
            },
            SystemTime::now(),
        )
        .expect("rebuild");

    let list = store.list_blocking().expect("list");
    assert!(list.unreadable.is_empty(), "{:?}", list.unreadable);
    assert!(list.ssh_profiles.is_empty());
    assert!(list.connections[0].unknown.is_empty());
    let after = list.store.expect("stamped");
    assert_ne!(after.generation, before.generation);
    assert_eq!(
        rebuilt.digest.as_deref(),
        Some(sha256_of(&paths(&root).connections_file()).as_str())
    );
    assert_eq!(rebuilt.set_aside, None);
    let calls = journal.take_entries();
    assert_eq!(calls.len(), 1);
    assert!(
        calls[0].iter().all(|entry| entry.deleted.is_empty()),
        "an id from the file it replaced is a deletion to send: {calls:?} ({})",
        held.id
    );
}

#[test]
fn a_rebuild_sets_aside_a_file_this_build_cannot_read() {
    let root = TempDir::new().expect("tempdir");
    let path = paths(&root).connections_file();
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dir");
    std::fs::write(&path, b"{ half an edit").expect("a damaged file");
    let store = store(&root);
    let kept = plain("kept");

    let rebuilt = store
        .rebuild_library_blocking(
            LibraryWrite {
                connections: vec![kept.clone()],
                ..LibraryWrite::default()
            },
            SystemTime::now(),
        )
        .expect("rebuild");

    let aside = rebuilt.set_aside.expect("set aside");
    assert_eq!(std::fs::read(&aside).expect("the copy"), b"{ half an edit");
    assert_eq!(store.list_blocking().expect("list").connections.to_vec(), [kept]);
}

#[test]
fn a_library_write_over_a_file_that_changed_since_is_refused() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let vouched = replace(&store, library_as_another_app_holds_it()).expect("write");
    let path = paths(&root).connections_file();
    let swapped = std::fs::read_to_string(&path)
        .expect("the file")
        .replace("Prod", "Planted");
    std::fs::write(&path, &swapped).expect("a swap");

    let over_old = store.replace_library_blocking(vouched.as_deref(), |_| {
        Ok::<_, StorageError>(library_as_another_app_holds_it())
    });
    let over_none = store.replace_library_blocking(None, |_| Ok::<_, StorageError>(LibraryWrite::default()));

    assert!(matches!(over_old, Err(StorageError::LibraryChanged)), "{over_old:?}");
    assert!(matches!(over_none, Err(StorageError::LibraryChanged)), "{over_none:?}");
    assert_eq!(std::fs::read_to_string(&path).expect("the file"), swapped);
}

#[test]
fn a_library_write_over_a_file_swapped_for_one_that_does_not_read_is_refused_as_changed() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let vouched = replace(&store, library_as_another_app_holds_it()).expect("write");
    std::fs::write(paths(&root).connections_file(), b"{ half an edit").expect("a swap");

    let refused = store.replace_library_blocking(vouched.as_deref(), |_| {
        Ok::<_, StorageError>(library_as_another_app_holds_it())
    });

    assert!(matches!(refused, Err(StorageError::LibraryChanged)), "{refused:?}");
}

#[cfg(unix)]
#[test]
fn a_rebuild_sets_aside_a_file_the_system_will_not_let_it_read() {
    use std::os::unix::fs::PermissionsExt;
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    replace(&store, library_as_another_app_holds_it()).expect("write");
    let path = paths(&root).connections_file();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000)).expect("locked out");
    if std::fs::read(&path).is_ok() {
        // Root reads whatever the mode says, so there is nothing to test.
        return;
    }
    let kept = plain("kept");

    let rebuilt = store
        .rebuild_library_blocking(
            LibraryWrite {
                connections: vec![kept.clone()],
                ..LibraryWrite::default()
            },
            SystemTime::now(),
        )
        .expect("rebuild");

    assert!(rebuilt.set_aside.is_some());
    assert_eq!(store.list_blocking().expect("list").connections.to_vec(), [kept]);
}

#[test]
fn a_library_write_takes_out_an_entry_this_build_cannot_read_that_it_names() {
    let root = TempDir::new().expect("tempdir");
    let (store, held) = seeded_with_unreadable(&root, false);
    let kept = plain("kept");

    replace(
        &store,
        LibraryWrite {
            connections: vec![kept.clone()],
            removing: vec![held.id],
            ..LibraryWrite::default()
        },
    )
    .expect("write");

    let list = store.list_blocking().expect("list");
    assert!(list.unreadable.is_empty(), "{:?}", list.unreadable);
    assert_eq!(list.connections.to_vec(), [kept]);
}

#[test]
fn a_library_write_refuses_what_the_store_would_drop() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let connection = plain("a");
    let tag = Uuid::new_v4();
    let stray = Uuid::new_v4();

    let favourite_twice = replace(
        &store,
        LibraryWrite {
            connections: vec![connection.clone()],
            favorites: vec![connection.id, connection.id],
            ..LibraryWrite::default()
        },
    );
    let tag_twice = replace(
        &store,
        LibraryWrite {
            connections: vec![SavedConnection {
                tags: vec![tag, tag],
                ..connection.clone()
            }],
            ..LibraryWrite::default()
        },
    );
    let favourite_of_nothing = replace(
        &store,
        LibraryWrite {
            connections: vec![connection.clone()],
            favorites: vec![stray],
            ..LibraryWrite::default()
        },
    );

    let kept_and_removed = replace(
        &store,
        LibraryWrite {
            connections: vec![connection.clone()],
            removing: vec![connection.id],
            ..LibraryWrite::default()
        },
    );

    assert!(matches!(kept_and_removed, Err(StorageError::RepeatedId { id }) if id == connection.id));
    assert!(matches!(favourite_twice, Err(StorageError::RepeatedId { id }) if id == connection.id));
    assert!(matches!(tag_twice, Err(StorageError::RepeatedId { id }) if id == tag));
    assert!(matches!(favourite_of_nothing, Err(StorageError::ConnectionNotFound { id }) if id == stray));
    assert_eq!(
        store.read_library_blocking().expect("read").digest,
        None,
        "nothing was written"
    );
}

#[test]
fn a_rebuild_refuses_an_id_named_twice() {
    let root = TempDir::new().expect("tempdir");
    let store = store(&root);
    let connection = plain("a");

    let refused = store.rebuild_library_blocking(
        LibraryWrite {
            connections: vec![connection.clone(), connection],
            ..LibraryWrite::default()
        },
        SystemTime::now(),
    );

    assert!(matches!(refused, Err(StorageError::RepeatedId { .. })), "{refused:?}");
}
