use serde_json::json;
use tablepro_storage::{SavedConnection, SavedSshAuth, SshJumpHost};
use uuid::Uuid;

use super::super::{DriverNames, team_connection};
use super::{LocalUse, shared_row_local_uses};

fn row(bundle: serde_json::Value) -> SavedConnection {
    team_connection(Uuid::from_u128(1), &bundle, DriverNames::Mac)
}

fn tunneled(auth: &str) -> SavedConnection {
    row(
        json!({"name": "Orders", "host": "db.team", "port": 5432, "database": "orders", "username": "ro",
        "type": "PostgreSQL", "sshConfig": {"enabled": true, "host": "bastion", "port": 2222, "username": "ops",
        "authMethod": auth, "privateKeyPath": "", "agentSocketPath": ""}}),
    )
}

fn agent(host: &str, port: u16) -> LocalUse {
    LocalUse::SshAgent {
        host: host.to_owned(),
        port,
    }
}

fn default_keys(host: &str, port: u16) -> LocalUse {
    LocalUse::SshDefaultKeys {
        host: host.to_owned(),
        port,
    }
}

fn key(host: &str, port: u16, path: &str) -> LocalUse {
    LocalUse::SshKeyFile {
        host: host.to_owned(),
        port,
        path: path.into(),
    }
}

fn file(path: &str) -> LocalUse {
    LocalUse::File { path: path.to_owned() }
}

// Every method but a named key may try the agent and the default keys, a password tunnel too, as the core's transports
// do after the password.
#[test]
fn a_tunnel_names_the_agent_and_default_keys_unless_it_names_a_key() {
    for auth in ["SSH Agent", "Private Key", "Password", "Keyboard Interactive", "None"] {
        assert_eq!(
            shared_row_local_uses(&tunneled(auth), false),
            [agent("bastion", 2222), default_keys("bastion", 2222)],
            "{auth}"
        );
    }
    let mut named = tunneled("Private Key");
    named.ssh.as_mut().unwrap().auth = SavedSshAuth::PrivateKey {
        path: Some("/Users/ada/.ssh/id_ed25519".into()),
        has_passphrase: false,
    };

    assert_eq!(
        shared_row_local_uses(&named, false),
        [key("bastion", 2222, "/Users/ada/.ssh/id_ed25519")]
    );
}

// A hop signs in first, so each names its own host: the agent, its key or the connection's, and the default keys.
#[test]
fn each_hop_names_the_host_it_signs_in_to() {
    let mut saved = tunneled("Private Key");
    let ssh = saved.ssh.as_mut().unwrap();
    ssh.auth = SavedSshAuth::PrivateKey {
        path: Some("/k/main".into()),
        has_passphrase: false,
    };
    let mut keyed = SshJumpHost::new("edge", Some(22), Some("a".to_owned()));
    keyed.key_path = Some("/k/edge".into());
    ssh.jump_hosts = vec![SshJumpHost::new("gate", None, None), keyed];
    saved.details.ssh_profile_id = Some(Uuid::from_u128(9));

    assert_eq!(
        shared_row_local_uses(&saved, false),
        [
            key("bastion", 2222, "/k/main"),
            agent("gate", 22),
            key("gate", 22, "/k/main"),
            default_keys("gate", 22),
            agent("edge", 22),
            key("edge", 22, "/k/edge"),
            default_keys("edge", 22),
            LocalUse::SshProfile { id: Uuid::from_u128(9) },
        ]
    );
}

// A database file or a socket here is opened here; MotherDuck, a URL, memory and a file on the SSH host are not.
#[test]
fn a_file_or_socket_on_this_device_is_named_and_a_remote_one_is_not() {
    let sqlite = row(
        json!({"name": "Local", "host": "", "port": 0, "database": "~/data/app.sqlite", "username": "",
        "type": "SQLite", "additionalFields": {"attachedDatabases":
            "[{\"name\":\"auth\",\"path\":\"/data/auth.db\"},{\"name\":\"cloud\",\"path\":\"md:shared\"}]"}}),
    );
    let duckdb = |path: &str, mode: &str| {
        row(
            json!({"name": "Duck", "host": "", "port": 0, "database": "", "username": "", "type": "DuckDB",
            "additionalFields": {"duckdbFilePath": path, "duckdbMode": mode}}),
        )
    };
    let libsql = row(
        json!({"name": "Turso", "host": "", "port": 0, "database": "", "username": "", "type": "libSQL",
        "additionalFields": {"libsqlFilePath": "/data/app.db"}}),
    );
    let socket = row(
        json!({"name": "MySQL", "host": "localhost", "port": 3306, "database": "", "username": "root",
        "type": "MySQL", "additionalFields": {"localSocketPath": "/tmp/mysql.sock"}}),
    );
    let mut over_ssh = sqlite.clone();
    over_ssh.details.additional_fields.clear();
    over_ssh.ssh = tunneled("SSH Agent").ssh;
    over_ssh.ssh.as_mut().unwrap().remote_file.path = Some("/srv/app.sqlite".to_owned());

    let opened = shared_row_local_uses(&sqlite, true);
    assert_eq!(opened.len(), 2, "{opened:?}");
    assert!(
        matches!(&opened[0], LocalUse::File { path } if path.ends_with("data/app.sqlite")),
        "{opened:?}"
    );
    assert_eq!(opened[1], file("/data/auth.db"));
    assert_eq!(
        shared_row_local_uses(&duckdb("/data/sales.duckdb", "local"), true),
        [file("/data/sales.duckdb")]
    );
    assert!(shared_row_local_uses(&duckdb("md:analytics", "motherduck"), true).is_empty());
    assert!(shared_row_local_uses(&duckdb("/data/sales.duckdb", "remote"), false).is_empty());
    assert_eq!(shared_row_local_uses(&libsql, false), [file("/data/app.db")]);
    assert_eq!(shared_row_local_uses(&socket, false), [file("/tmp/mysql.sock")]);
    assert!(
        !shared_row_local_uses(&over_ssh, true)
            .iter()
            .any(|used| matches!(used, LocalUse::File { .. }))
    );
}

// A row of plain network settings uses nothing of this device.
#[test]
fn a_plain_network_row_uses_nothing_here() {
    let plain = row(
        json!({"name": "Shop", "host": "db.internal", "port": 5432, "database": "shop",
        "username": "app", "type": "PostgreSQL"}),
    );

    assert!(shared_row_local_uses(&plain, false).is_empty());
}
