// 0056, Envelopes and history: which secrets a record's envelopes hold, and the destination each is sealed for.

use std::fmt;

use serde_json::Value;

use crate::kind::Kind;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SecretKind {
    Password,
    SslKeyPassphrase,
    SshPassword,
    SshKeyPassphrase,
    SshTotpSecret,
    // One per secure field a driver plugin declares. A field id holding `/` does not sync.
    Plugin(String),
    // One per AI provider, on a settings kind's `ai` record.
    AiKey(String),
}

pub const AI_RECORD: &str = "ai";

impl SecretKind {
    // A new secret kind needs a row in 0056's envelope table first.
    pub fn parse(parent: Kind, text: &str) -> Option<Self> {
        let suffix = |prefix: &str| {
            text.strip_prefix(prefix)
                .filter(|rest| !rest.is_empty() && !rest.contains('/'))
                .map(str::to_owned)
        };
        let secret = match text {
            "password" => Self::Password,
            "ssl_key_passphrase" => Self::SslKeyPassphrase,
            "ssh_password" => Self::SshPassword,
            "ssh_key_passphrase" => Self::SshKeyPassphrase,
            "ssh_totp_secret" => Self::SshTotpSecret,
            _ => suffix("plugin.")
                .map(Self::Plugin)
                .or_else(|| suffix("ai_key.").map(Self::AiKey))?,
        };
        secret.belongs_to(parent).then_some(secret)
    }

    pub fn belongs_to(&self, parent: Kind) -> bool {
        match parent {
            Kind::Connection | Kind::LibraryConnection => !matches!(self, Self::AiKey(_)),
            Kind::SshProfile => matches!(self, Self::SshPassword | Self::SshKeyPassphrase | Self::SshTotpSecret),
            Kind::CredentialProfile => matches!(self, Self::Password),
            Kind::MacosSettings | Kind::IosSettings | Kind::LinuxSettings | Kind::WindowsSettings => {
                matches!(self, Self::AiKey(_))
            }
            _ => false,
        }
    }

    const fn is_ssh(&self) -> bool {
        matches!(self, Self::SshPassword | Self::SshKeyPassphrase | Self::SshTotpSecret)
    }
}

impl fmt::Display for SecretKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Password => f.write_str("password"),
            Self::SslKeyPassphrase => f.write_str("ssl_key_passphrase"),
            Self::SshPassword => f.write_str("ssh_password"),
            Self::SshKeyPassphrase => f.write_str("ssh_key_passphrase"),
            Self::SshTotpSecret => f.write_str("ssh_totp_secret"),
            Self::Plugin(id) => write!(f, "plugin.{id}"),
            Self::AiKey(provider) => write!(f, "ai_key.{provider}"),
        }
    }
}

// The members of the record a secret is sealed for, as paths into its wire schema. A hop of the SSH route keeps the
// same SSH fields as the host it leads to. A driver's own fields go in whole: some of them name the hosts it dials,
// such as Elasticsearch's node list, or switch its TLS checks, and only the driver knows which.
pub fn destination_paths(parent: Kind, secret: &SecretKind) -> &'static [&'static str] {
    const CONNECTION: &[&str] = &[
        "type",
        "host",
        "port",
        "database",
        "username",
        "ssl_config.mode",
        "ssl_config.ca_certificate_path",
        "ssl_config.client_certificate_path",
        "ssh_config.enabled",
        "ssh_config.host",
        "ssh_config.port",
        "ssh_config.username",
        "ssh_config.private_key_path",
        "ssh_config.jump_hosts[].host",
        "ssh_config.jump_hosts[].port",
        "ssh_config.jump_hosts[].username",
        "ssh_config.jump_hosts[].private_key_path",
        "ssh_profile_id",
        "ssh_route",
        "network_options",
        "additional_fields",
    ];
    // The published route's target is the SSH server a Mac dials when it resolved one.
    const CONNECTION_SSH: &[&str] = &[
        "ssh_config.host",
        "ssh_config.port",
        "ssh_config.username",
        "ssh_config.private_key_path",
        "ssh_route",
    ];
    const LIBRARY_CONNECTION: &[&str] = &[
        "type",
        "host",
        "port",
        "database",
        "username",
        "sslConfig.mode",
        "sslConfig.caCertificatePath",
        "sslConfig.clientCertificatePath",
        "sshConfig.enabled",
        "sshConfig.host",
        "sshConfig.port",
        "sshConfig.username",
        "sshConfig.privateKeyPath",
        "sshConfig.jumpHosts[].host",
        "sshConfig.jumpHosts[].port",
        "sshConfig.jumpHosts[].username",
        "sshConfig.jumpHosts[].privateKeyPath",
        "sshProfileId",
        "additionalFields",
    ];
    const LIBRARY_CONNECTION_SSH: &[&str] = &[
        "sshConfig.host",
        "sshConfig.port",
        "sshConfig.username",
        "sshConfig.privateKeyPath",
    ];
    const SSH_PROFILE: &[&str] = &["host", "port", "username", "private_key_path"];
    const CREDENTIAL_PROFILE: &[&str] = &["username"];
    // Within the provider entry whose `id` the secret kind names.
    const AI_PROVIDER: &[&str] = &["type", "endpoint"];

    if !secret.belongs_to(parent) {
        return &[];
    }
    match parent {
        Kind::Connection if secret.is_ssh() => CONNECTION_SSH,
        Kind::Connection => CONNECTION,
        Kind::LibraryConnection if secret.is_ssh() => LIBRARY_CONNECTION_SSH,
        Kind::LibraryConnection => LIBRARY_CONNECTION,
        Kind::SshProfile => SSH_PROFILE,
        Kind::CredentialProfile => CREDENTIAL_PROFILE,
        _ => AI_PROVIDER,
    }
}

// `dest`: the record's values at those paths, nested as the record nests them and left out where the record has none.
// At use the client builds it again from the record's current fields and compares the two as JSON values.
pub fn destination(parent: Kind, secret: &SecretKind, fields: &Value) -> Value {
    let source = match secret {
        SecretKind::AiKey(provider) => ai_provider(fields, provider).unwrap_or(&Value::Null),
        _ => fields,
    };
    let mut dest = Value::Object(Default::default());
    for path in destination_paths(parent, secret) {
        let steps: Vec<&str> = path.split('.').collect();
        copy(source, &mut dest, &steps);
    }
    dest
}

fn ai_provider<'a>(fields: &'a Value, provider: &str) -> Option<&'a Value> {
    fields
        .get("options")?
        .get("providers")?
        .as_array()?
        .iter()
        .find(|entry| entry.get("id").and_then(Value::as_str) == Some(provider))
}

fn copy(source: &Value, dest: &mut Value, steps: &[&str]) {
    let Some((step, rest)) = steps.split_first() else {
        return;
    };
    let (key, each) = match step.strip_suffix("[]") {
        Some(key) => (key, true),
        None => (*step, false),
    };
    let Some(found) = source.get(key) else {
        return;
    };
    let Value::Object(target) = dest else {
        return;
    };
    match (each, found) {
        (false, _) if rest.is_empty() => {
            target.insert(key.to_owned(), found.clone());
        }
        (false, Value::Object(_)) => {
            let slot = target
                .entry(key.to_owned())
                .or_insert_with(|| Value::Object(Default::default()));
            copy(found, slot, rest);
        }
        (true, Value::Array(items)) => {
            let slot = target
                .entry(key.to_owned())
                .or_insert_with(|| Value::Array(vec![Value::Object(Default::default()); items.len()]));
            if let Value::Array(hops) = slot {
                for (item, hop) in items.iter().zip(hops.iter_mut()) {
                    copy(item, hop, rest);
                }
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::schema::{nested, schema};

    #[test]
    fn each_parent_takes_only_the_secrets_0056_lists_for_it() {
        assert_eq!(
            SecretKind::parse(Kind::Connection, "password"),
            Some(SecretKind::Password)
        );
        assert_eq!(
            SecretKind::parse(Kind::LibraryConnection, "plugin.serviceAccountKey"),
            Some(SecretKind::Plugin("serviceAccountKey".to_owned()))
        );
        assert_eq!(SecretKind::parse(Kind::Connection, "plugin."), None);
        assert_eq!(SecretKind::parse(Kind::Connection, "ai_key.A"), None);
        assert_eq!(SecretKind::parse(Kind::SshProfile, "password"), None);
        assert_eq!(
            SecretKind::parse(Kind::SshProfile, "ssh_totp_secret"),
            Some(SecretKind::SshTotpSecret)
        );
        assert_eq!(SecretKind::parse(Kind::CredentialProfile, "ssh_password"), None);
        assert_eq!(
            SecretKind::parse(Kind::MacosSettings, "ai_key.7C1A"),
            Some(SecretKind::AiKey("7C1A".to_owned()))
        );
        assert_eq!(SecretKind::parse(Kind::Group, "password"), None);
        assert_eq!(SecretKind::parse(Kind::Connection, "token"), None);
    }

    #[test]
    fn every_destination_path_is_a_member_of_the_parent_schema() {
        let secrets = [
            SecretKind::Password,
            SecretKind::SslKeyPassphrase,
            SecretKind::SshPassword,
            SecretKind::SshKeyPassphrase,
            SecretKind::SshTotpSecret,
            SecretKind::Plugin("f".to_owned()),
        ];
        for parent in [
            Kind::Connection,
            Kind::LibraryConnection,
            Kind::SshProfile,
            Kind::CredentialProfile,
        ] {
            for secret in secrets.iter().filter(|secret| secret.belongs_to(parent)) {
                for path in destination_paths(parent, secret) {
                    let mut fields = schema(parent).fields;
                    for step in path.split('.') {
                        let key = step.trim_end_matches("[]");
                        let field = fields
                            .iter()
                            .find(|field| field.key == key)
                            .unwrap_or_else(|| panic!("{parent} {secret}: {path}"));
                        fields = nested(&field.ty).unwrap_or(&[]);
                    }
                }
            }
        }
    }

    #[test]
    fn a_connection_password_is_sealed_for_its_engine_host_tls_and_ssh_route() {
        let fields = json!({
            "name": "prod",
            "type": "PostgreSQL",
            "host": "db.internal",
            "port": 5432,
            "database": "shop",
            "username": "app",
            "sort_order": 3,
            "ssl_config": {"mode": "Verify Identity", "ca_certificate_path": "~/ca.pem", "client_key_path": "~/k.pem"},
            "ssh_config": {
                "enabled": true,
                "host": "bastion",
                "port": 22,
                "username": "ops",
                "auth_method": "Private Key",
                "private_key_path": "~/.ssh/id",
                "totp_mode": "none",
                "jump_hosts": [
                    {"id": "J1", "host": "edge", "port": 2222, "username": "a", "auth_method": "SSH Agent"},
                    {"id": "J2", "host": "inner", "username": "b", "private_key_path": "~/.ssh/b"}
                ]
            }
        });

        assert_eq!(
            destination(Kind::Connection, &SecretKind::Password, &fields),
            json!({
                "type": "PostgreSQL",
                "host": "db.internal",
                "port": 5432,
                "database": "shop",
                "username": "app",
                "ssl_config": {"mode": "Verify Identity", "ca_certificate_path": "~/ca.pem"},
                "ssh_config": {
                    "enabled": true,
                    "host": "bastion",
                    "port": 22,
                    "username": "ops",
                    "private_key_path": "~/.ssh/id",
                    "jump_hosts": [
                        {"host": "edge", "port": 2222, "username": "a"},
                        {"host": "inner", "username": "b", "private_key_path": "~/.ssh/b"}
                    ]
                }
            })
        );
        assert_eq!(
            destination(Kind::Connection, &SecretKind::SshKeyPassphrase, &fields),
            json!({"ssh_config": {"host": "bastion", "port": 22, "username": "ops", "private_key_path": "~/.ssh/id"}})
        );
    }

    // `fixtures/dest.json`: the destination each secret is sealed for, for the sealing and opening code to share.
    #[test]
    fn the_destination_fixtures_build_as_written() {
        let cases: Vec<Value> = serde_json::from_str(include_str!("../fixtures/dest.json")).expect("the fixtures");
        assert!(cases.len() >= 7);
        for case in cases {
            let parent = Kind::parse(case["parent"].as_str().expect("a kind"))
                .expect("well formed")
                .expect("known");
            let secret = SecretKind::parse(parent, case["secret"].as_str().expect("a secret")).expect("listed");
            assert_eq!(
                destination(parent, &secret, &case["fields"]),
                case["dest"],
                "{}",
                case["name"]
            );
        }
    }

    // Each member that decides where the secret goes, or how it is protected on the way, changes `dest`.
    #[test]
    fn every_endpoint_member_changes_the_destination() {
        let held = json!({
            "type": "Elasticsearch",
            "host": "es",
            "port": 9200,
            "ssl_config": {"mode": "Required"},
            "ssh_config": {"enabled": true, "host": "b", "jump_hosts": [{"host": "j"}]},
            "ssh_route": {"hops": [{"host": "h1"}], "target": {"host": "es"}},
            "network_options": {"more_hosts": ["es2:9200"]},
            "additional_fields": [{"id": "esHosts", "value": "es:9200"}, {"id": "esSkipTLSVerify", "value": "false"}]
        });
        let changes = [
            ("/type", json!("OpenSearch")),
            ("/host", json!("evil")),
            ("/port", json!(1)),
            ("/ssl_config/mode", json!("Disabled")),
            ("/ssh_config/enabled", json!(false)),
            ("/ssh_config/jump_hosts/0/host", json!("evil")),
            ("/ssh_route/hops/0/host", json!("evil")),
            ("/network_options/more_hosts/0", json!("evil:9200")),
            ("/additional_fields/0/value", json!("evil:9200")),
            ("/additional_fields/1/value", json!("true")),
        ];
        for secret in [SecretKind::Password, SecretKind::Plugin("esApiKey".to_owned())] {
            let sealed = destination(Kind::Connection, &secret, &held);
            for (pointer, value) in &changes {
                let mut moved = held.clone();
                *moved.pointer_mut(pointer).expect("a member") = value.clone();
                assert_ne!(
                    destination(Kind::Connection, &secret, &moved),
                    sealed,
                    "{secret} {pointer}"
                );
            }
        }
    }

    #[test]
    fn an_ssh_secret_follows_the_route_target_a_mac_dials() {
        let held = json!({
            "ssh_config": {"enabled": true, "host": "bastion", "port": 22, "username": "ops"},
            "ssh_route": {"basis": "b", "hops": [], "target": {"alias": "bastion", "host": "10.0.0.5", "port": 22, "username": "ops"}}
        });
        for secret in [
            SecretKind::SshPassword,
            SecretKind::SshKeyPassphrase,
            SecretKind::SshTotpSecret,
        ] {
            let sealed = destination(Kind::Connection, &secret, &held);
            for (pointer, value) in [
                ("/ssh_route/target/host", json!("evil")),
                ("/ssh_route/target/port", json!(2222)),
                ("/ssh_route/target/username", json!("root")),
            ] {
                let mut moved = held.clone();
                *moved.pointer_mut(pointer).expect("a member") = value;
                assert_ne!(
                    destination(Kind::Connection, &secret, &moved),
                    sealed,
                    "{secret} {pointer}"
                );
            }
        }
    }

    #[test]
    fn a_rewritten_host_changes_the_destination_and_a_new_name_does_not() {
        let held = json!({"type": "MySQL", "host": "a", "port": 3306, "name": "x"});
        let renamed = json!({"type": "MySQL", "host": "a", "port": 3306, "name": "y"});
        let moved = json!({"type": "MySQL", "host": "evil", "port": 3306, "name": "x"});
        let sealed = destination(Kind::Connection, &SecretKind::Password, &held);

        assert_eq!(destination(Kind::Connection, &SecretKind::Password, &renamed), sealed);
        assert_ne!(destination(Kind::Connection, &SecretKind::Password, &moved), sealed);
    }

    #[test]
    fn an_ai_key_is_sealed_for_its_provider_type_and_endpoint() {
        let fields = json!({
            "category": "ai",
            "options": {"providers": [
                {"id": "A", "type": "openAI", "endpoint": "https://api.openai.com/v1", "name": "Work", "model": "x"},
                {"id": "B", "type": "ollama", "endpoint": "http://localhost:11434"}
            ]}
        });
        let secret = SecretKind::AiKey("A".to_owned());

        assert_eq!(
            destination(Kind::MacosSettings, &secret, &fields),
            json!({"type": "openAI", "endpoint": "https://api.openai.com/v1"})
        );
        assert_eq!(
            destination(Kind::MacosSettings, &SecretKind::AiKey("C".to_owned()), &fields),
            json!({})
        );
    }

    #[test]
    fn profiles_are_sealed_for_their_own_destination() {
        let ssh = json!({"name": "n", "host": "h", "port": 22, "username": "u", "private_key_path": "~/k", "totp_mode": "none"});
        let credentials = json!({"name": "n", "username": "dba", "password_mode": "stored"});

        assert_eq!(
            destination(Kind::SshProfile, &SecretKind::SshPassword, &ssh),
            json!({"host": "h", "port": 22, "username": "u", "private_key_path": "~/k"})
        );
        assert_eq!(
            destination(Kind::CredentialProfile, &SecretKind::Password, &credentials),
            json!({"username": "dba"})
        );
    }
}
