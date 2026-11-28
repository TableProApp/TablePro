// Bundles as the Mac's `ConnectionBundleExporter.teamShareableSettings` writes them, so a team copy a beta Mac published
// reads the same here and goes back out byte for byte, less the paths on the device that wrote it.

use serde_json::{Value, json};
use uuid::Uuid;

use super::{DriverNames, team_bundle, team_connection};

const ID: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";
const PROFILE: &str = "0F6C2A1E-6B3D-4D8E-9A51-3D7E2B1F0C44";

fn id() -> Uuid {
    Uuid::parse_str(ID).unwrap()
}

fn read(bundle: &Value) -> tablepro_storage::SavedConnection {
    team_connection(id(), bundle, DriverNames::Mac)
}

fn round_trip(bundle: &Value) -> Value {
    team_bundle(&read(bundle), None, DriverNames::Mac)
}

// A plain connection: no tunnel, no TLS, the defaults left out.
fn plain() -> Value {
    json!({
        "name": "Shop", "host": "db.internal", "port": 5432, "database": "shop", "username": "app",
        "type": "PostgreSQL",
    })
}

// Every member the builder writes, each away from its default.
fn full() -> Value {
    json!({
        "name": "Orders", "host": "db.team", "port": 3306, "database": "orders", "username": "ro", "type": "MySQL",
        "sshConfig": {
            "enabled": true, "host": "bastion", "port": 2222, "username": "ops", "authMethod": "Private Key",
            "privateKeyPath": "~/.ssh/id_ed25519", "agentSocketPath": "",
            "jumpHosts": [{"host": "edge", "port": 22, "username": "a", "authMethod": "SSH Agent", "privateKeyPath": ""}],
            "totpMode": "auto_generate", "totpAlgorithm": "SHA256", "totpDigits": 8, "totpPeriod": 60,
            "remoteFilePath": "/srv/app.db", "remoteFileAccess": "onServer",
        },
        "sslConfig": {
            "mode": "Verify CA", "caCertificatePath": "~/certs/ca.pem", "clientCertificatePath": "",
            "clientKeyPath": "",
        },
        "color": "Blue", "iconName": "server.rack", "safeModeLevel": "alertFull", "aiPolicy": "askEachTime",
        "connectTimeoutSeconds": 30, "queryTimeoutSeconds": 120, "additionalFields": {"bqLocation": "EU"},
        "redisDatabase": 3,
    })
}

// `full()` with no path on the device that wrote it: the key, agent socket and TLS members empty, as the Mac's decoder
// needs them, and no SSH profile.
fn full_without_device_paths() -> Value {
    let mut bundle = full();
    bundle["sshConfig"]["privateKeyPath"] = json!("");
    bundle["sshConfig"]["agentSocketPath"] = json!("");
    bundle["sshConfig"]["jumpHosts"][0]["privateKeyPath"] = json!("");
    bundle["sslConfig"]["caCertificatePath"] = json!("");
    bundle
}

#[test]
fn a_bundle_the_mac_writes_reads_and_goes_back_out_unchanged() {
    assert_eq!(round_trip(&plain()), plain());
    assert_eq!(round_trip(&full()), full_without_device_paths());
    assert_eq!(round_trip(&full_without_device_paths()), full_without_device_paths());
}

#[test]
fn a_full_bundle_reads_into_the_saved_connection_s_members() {
    let saved = read(&full());

    assert_eq!(saved.id, id());
    assert_eq!(
        (
            saved.name.as_str(),
            saved.host.as_str(),
            saved.port,
            saved.driver_id.as_str()
        ),
        ("Orders", "db.team", 3306, "MySQL")
    );
    let ssh = saved.ssh.as_ref().expect("a tunnel");
    assert!(ssh.enabled);
    assert_eq!(ssh.host, "bastion");
    assert_eq!(ssh.jump_hosts.len(), 1);
    assert_eq!(saved.tls.mode, tablepro_core::TlsMode::VerifyCa);
    assert_eq!(saved.safe_mode, tablepro_core::SafeModeLevel::AlertFull);
    assert_eq!(saved.query_timeout_secs, Some(120));
    assert_eq!(
        saved
            .details
            .additional_fields
            .get("connectTimeoutSeconds")
            .map(String::as_str),
        Some("30")
    );
    assert_eq!(saved.details.redis_database, Some(3));
    assert!(saved.tags.is_empty() && saved.group_id.is_none() && saved.project_id.is_none());
}

// A team copy drops what would run on the reader's machine.
#[test]
fn a_team_copy_drops_startup_and_tunnel_commands() {
    let mut bundle = plain();
    bundle["startupCommands"] = json!("SET ROLE admin");
    bundle["tunnelCommand"] = json!({"method": "command", "command": "nc db 5432"});
    bundle["localOnly"] = json!(true);

    let saved = read(&bundle);

    assert_eq!(saved.details.startup_sql, None);
    assert!(!saved.device.local_only);
    assert_eq!(team_bundle(&saved, None, DriverNames::Mac), plain());
}

// A path on the device that wrote the copy names nothing on the reader's, and another account's path must never pick
// this device's key, so none comes in. The sign-in method stays, so a key copy asks for a key of the reader's own.
#[test]
fn a_team_copy_reads_no_key_agent_tls_file_driver_file_or_profile() {
    let mut bundle = full();
    bundle["sshConfig"]["agentSocketPath"] = json!("~/.1password/agent.sock");
    bundle["sslConfig"]["clientCertificatePath"] = json!("~/certs/me.pem");
    bundle["sslConfig"]["clientKeyPath"] = json!("~/certs/me.key");
    bundle["sshProfileId"] = json!(PROFILE);
    bundle["additionalFields"] =
        json!({"bqLocation": "EU", "sslCaCertPath": "~/ca.pem", "sqliteExtensions": "~/x.dylib"});

    let saved = read(&bundle);

    let ssh = saved.ssh.as_ref().expect("a tunnel");
    assert_eq!(
        ssh.auth,
        tablepro_storage::SavedSshAuth::PrivateKey {
            path: None,
            has_passphrase: false
        }
    );
    assert_eq!((&ssh.kept_key_path, &ssh.agent_socket), (&None, &None));
    assert_eq!(ssh.jump_hosts[0].key_path, None);
    assert_eq!((&saved.tls.ca_file, &saved.tls.client_identity), (&None, &None));
    assert_eq!(saved.details.ssh_profile_id, None);
    assert_eq!(
        saved.details.additional_fields.keys().collect::<Vec<_>>(),
        ["bqLocation", "connectTimeoutSeconds"]
    );
}

// The same paths on this device stay here when it publishes.
#[test]
fn a_published_copy_carries_no_key_agent_tls_file_driver_file_or_profile() {
    let mut saved = read(&full_without_device_paths());
    let ssh = saved.ssh.as_mut().expect("a tunnel");
    ssh.auth = tablepro_storage::SavedSshAuth::PrivateKey {
        path: Some("/Users/ada/.ssh/id_ed25519".into()),
        has_passphrase: true,
    };
    ssh.kept_key_path = Some("/Users/ada/.ssh/old".into());
    ssh.agent_socket = Some("/Users/ada/.1password/agent.sock".into());
    ssh.jump_hosts[0].key_path = Some("/Users/ada/.ssh/edge".into());
    saved.tls.ca_file = Some("/Users/ada/ca.pem".into());
    saved.details.ssh_profile_id = Uuid::parse_str(PROFILE).ok();
    for (key, value) in [
        ("sslCaCertPath", "/Users/ada/ca.pem"),
        ("sqliteExtensions", "/Users/ada/x.dylib"),
    ] {
        saved.details.additional_fields.insert(key.to_owned(), value.to_owned());
    }

    assert_eq!(team_bundle(&saved, None, DriverNames::Mac), full_without_device_paths());
}

// `DatabaseConnection(importing:)`: a blank host is localhost, a mode no build names checks as Required, a legacy
// timeout in the fields moves to its member, and one out of range is dropped.
#[test]
fn a_bundle_reads_as_the_mac_imports_one() {
    let mut bundle = plain();
    bundle["host"] = json!("  ");
    bundle["sslConfig"] =
        json!({"mode": "verify-full", "caCertificatePath": "", "clientCertificatePath": "", "clientKeyPath": ""});
    bundle["additionalFields"] = json!({"queryTimeoutSeconds": "45", "connectTimeoutSeconds": "9000"});
    let mut unknown_mode = plain();
    unknown_mode["sslConfig"] = json!({"mode": "Paranoid"});

    let saved = read(&bundle);

    assert_eq!(saved.host, "localhost");
    assert_eq!(saved.tls.mode, tablepro_core::TlsMode::VerifyFull);
    assert_eq!(saved.query_timeout_secs, Some(45));
    assert!(saved.details.additional_fields.is_empty());
    assert_eq!(read(&unknown_mode).tls.mode, tablepro_core::TlsMode::Require);
}

// A driver field this build does not know as one a file may carry neither goes out nor comes in: it may be a secret
// or a command a newer build added.
#[test]
fn a_driver_field_no_file_may_carry_stays_out_both_ways() {
    let mut bundle = plain();
    bundle["additionalFields"] = json!({"bqLocation": "EU", "someNewToken": "abc"});

    let saved = read(&bundle);
    let mut held = saved.clone();
    held.details
        .additional_fields
        .insert("someNewToken".to_owned(), "abc".to_owned());

    assert!(!saved.details.additional_fields.contains_key("someNewToken"));
    assert_eq!(
        team_bundle(&held, None, DriverNames::Mac)["additionalFields"],
        json!({"bqLocation": "EU"})
    );
}

// A database file is where the connection goes, not a credential, so it travels both ways: a MotherDuck `md:` copy, a
// DuckDB file and a libSQL file alike.
#[test]
fn a_team_copy_keeps_its_database_file() {
    let file = |kind: &str, field: &str, path: &str| {
        json!({"name": "Local", "host": "localhost", "port": 0, "database": "", "username": "", "type": kind,
            "additionalFields": {field: path}})
    };
    for bundle in [
        file("DuckDB", "duckdbFilePath", "md:analytics"),
        file("DuckDB", "duckdbFilePath", "~/data/sales.duckdb"),
        file("libSQL", "libsqlFilePath", "~/data/app.db"),
    ] {
        let saved = read(&bundle);
        let (field, path) = bundle["additionalFields"].as_object().unwrap().iter().next().unwrap();

        assert!(saved.details.additional_fields.contains_key(field), "{bundle}");
        assert_eq!(
            team_bundle(&saved, None, DriverNames::Mac)["additionalFields"][field],
            *path,
            "{bundle}"
        );
    }
}

// Linux and Windows name the engine by the core's driver id; the bundle always carries the Mac's name.
#[test]
fn the_core_s_driver_ids_read_and_write_the_mac_s_type_names() {
    let saved = team_connection(id(), &plain(), DriverNames::Core);

    assert_ne!(saved.driver_id, "PostgreSQL");
    assert_eq!(team_bundle(&saved, None, DriverNames::Core), plain());
}

// A tunnel switched off and TLS disabled are left out, as `ExportableSSHConfig(portable:)` and
// `ExportableSSLConfig(portable:)` leave them.
#[test]
fn a_switched_off_tunnel_and_disabled_tls_are_left_out() {
    let mut saved = read(&full());
    if let Some(ssh) = saved.ssh.as_mut() {
        ssh.enabled = false;
    }
    saved.tls.mode = tablepro_core::TlsMode::Disable;

    let bundle = team_bundle(&saved, None, DriverNames::Mac);

    assert!(bundle.get("sshConfig").is_none());
    assert!(bundle.get("sslConfig").is_none());
}
