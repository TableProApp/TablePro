// Bundles as the Mac's `ConnectionBundleExporter.teamShareableSettings` writes them, so a team copy a beta Mac published
// reads the same here and goes back out byte for byte.

use serde_json::{Value, json};
use uuid::Uuid;

use super::{DriverNames, team_bundle, team_connection};

const ID: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";
const PROFILE: &str = "0F6C2A1E-6B3D-4D8E-9A51-3D7E2B1F0C44";

fn id() -> Uuid {
    Uuid::parse_str(ID).unwrap()
}

fn read(bundle: &Value) -> tablepro_storage::SavedConnection {
    team_connection(id(), bundle, DriverNames::Mac, |_| false)
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
        "connectTimeoutSeconds": 30, "queryTimeoutSeconds": 120, "additionalFields": {"mysqlCharset": "utf8mb4"},
        "redisDatabase": 3,
    })
}

#[test]
fn a_bundle_the_mac_writes_reads_and_goes_back_out_unchanged() {
    for bundle in [plain(), full()] {
        assert_eq!(round_trip(&bundle), bundle);
    }
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
    assert!(saved.tls.ca_file.as_ref().is_some_and(|path| path.is_absolute()));
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

// A team copy drops what would run on the reader's machine, and a profile only a profile this device holds links.
#[test]
fn a_team_copy_drops_startup_and_tunnel_commands_and_links_only_a_held_profile() {
    let mut bundle = plain();
    bundle["startupCommands"] = json!("SET ROLE admin");
    bundle["tunnelCommand"] = json!({"method": "command", "command": "nc db 5432"});
    bundle["localOnly"] = json!(true);
    bundle["sshProfileId"] = json!(PROFILE);

    let unheld = read(&bundle);
    let held = team_connection(id(), &bundle, DriverNames::Mac, |profile| {
        profile == Uuid::parse_str(PROFILE).unwrap()
    });

    assert_eq!(unheld.details.startup_sql, None);
    assert!(!unheld.device.local_only);
    assert_eq!(unheld.details.ssh_profile_id, None);
    assert_eq!(held.details.ssh_profile_id, Uuid::parse_str(PROFILE).ok());
    assert_eq!(team_bundle(&unheld, None, DriverNames::Mac), plain());
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

// Linux and Windows name the engine by the core's driver id; the bundle always carries the Mac's name.
#[test]
fn the_core_s_driver_ids_read_and_write_the_mac_s_type_names() {
    let saved = team_connection(id(), &plain(), DriverNames::Core, |_| false);

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
