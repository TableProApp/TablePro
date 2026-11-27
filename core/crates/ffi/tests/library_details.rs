#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    AiPolicyTag, CloudflareAuthTag, CloudflareTunnelRecord, ConnectionDetailsRecord, ConnectionRecord,
    ConnectionSecrets, Core, CredentialPasswordRecord, CredentialProfileRecord, CredentialReferenceRecord,
    DeviceSettingsRecord, ExternalAccessTag, GroupRecord, HostConfig, HostSecretError, HostSecrets,
    LibraryConnectionRecord, LibraryWriteRecord, LocalPasswordSourceRecord, RemoteFileAccessTag, SafeModeTag,
    SecretItemTag, SecretKindTag, SshAuthTag, SshJumpAuthTag, SshJumpHostRecord, SshOptionsRecord, SshProfileRecord,
    SshSettings, SshTotpAlgorithmTag, SshTotpModeTag, SshTotpRecord, TableFolderItemRecord, TableRefRecord, TagRecord,
    TlsModeTag, TlsSettings, VaultAuthRecord, library_icon_for_symbol, library_icon_symbol, parse_jump_hosts,
};

struct NoSecrets;

impl HostSecrets for NoSecrets {
    fn load(&self, _: String, _: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store(&self, _: String, _: SecretKindTag, _: SecretString, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn relabel(&self, _: String, _: SecretKindTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete(&self, _: String, _: SecretKindTag) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_connection(&self, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn load_item(&self, _: SecretItemTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store_item(&self, _: SecretItemTag, _: SecretString) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_item(&self, _: SecretItemTag) -> Result<(), HostSecretError> {
        Ok(())
    }
}

fn started(dir: &Path) -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: Some(dir.display().to_string()),
        },
        Box::new(NoSecrets),
    )
    .unwrap()
}

fn record(name: &str) -> ConnectionRecord {
    ConnectionRecord {
        id: String::new(),
        name: name.to_owned(),
        driver_id: "postgres".to_owned(),
        host: "db.internal".to_owned(),
        port: 5432,
        database: "app".to_owned(),
        username: "app".to_owned(),
        integrated_auth: false,
        tls: TlsSettings {
            mode: TlsModeTag::VerifyFull,
            ca_file: None,
            client_certificate: None,
            client_key: None,
            server_name: None,
        },
        ssh: None,
        safe_mode: SafeModeTag::Silent,
        query_timeout_secs: None,
        color: None,
        group_id: None,
        last_opened_ms: None,
        tags: Vec::new(),
        ai_policy: None,
        external_access: None,
        icon: None,
        order: 0,
    }
}

fn details() -> ConnectionDetailsRecord {
    ConnectionDetailsRecord {
        startup_sql: Some("SET search_path TO app".to_owned()),
        ai_rules: Some("Never touch billing".to_owned()),
        ai_allowed_tools: vec!["describe_table".to_owned(), "list_tables".to_owned()],
        ssh_profile_id: None,
        ssh_route: None,
        credential_profile_id: Some("C00996E7-3992-4501-99A1-03CF155AB59A".to_lowercase()),
        credential_reference: Some(CredentialReferenceRecord::VaultDatabaseRole {
            address: Some("https://vault.internal".to_owned()),
            mount: "database".to_owned(),
            role: "readonly".to_owned(),
            auth: VaultAuthRecord::AppRole {
                mount: "approle".to_owned(),
                role_id: "role".to_owned(),
                secret_id_path: "/run/secrets/vault".to_owned(),
            },
        }),
        redis_database: Some(2),
        additional_fields: HashMap::from([("mongoAuthSource".to_owned(), "admin".to_owned())]),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn details_and_device_settings_round_trip_and_a_form_save_keeps_them() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let saved = library
        .save(record("prod"), ConnectionSecrets::default())
        .await
        .unwrap();
    let device = DeviceSettingsRecord {
        local_only: true,
        is_sample: false,
        origin: "imported".to_owned(),
        password_source: Some(LocalPasswordSourceRecord::Command {
            shell: "pass show db".to_owned(),
            reuse_seconds: Some(60),
        }),
        cloudflare_tunnel: Some(CloudflareTunnelRecord {
            access_hostname: "db.example.com".to_owned(),
            local_port: None,
            auth_method: CloudflareAuthTag::BrowserSso,
            expose_to_lan: false,
            binary_path: String::new(),
        }),
        cloud_sql_proxy: None,
        socks_proxy: None,
        tunnel_command: None,
        tls_mode_unsettled: true,
        ssh_profile_unlinked: true,
    };

    library
        .set_connection_details(saved.id.clone(), details())
        .await
        .unwrap();
    library
        .set_device_settings(saved.id.clone(), device.clone())
        .await
        .unwrap();
    library
        .save(
            ConnectionRecord {
                host: "elsewhere".to_owned(),
                ..saved.clone()
            },
            ConnectionSecrets::default(),
        )
        .await
        .unwrap();

    assert_eq!(library.connection_details(saved.id.clone()).await.unwrap(), details());
    assert_eq!(library.device_settings(saved.id.clone()).await.unwrap(), device);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_origin_a_newer_build_wrote_comes_back_as_written() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let saved = library
        .save(record("prod"), ConnectionSecrets::default())
        .await
        .unwrap();

    library
        .set_device_settings(
            saved.id.clone(),
            DeviceSettingsRecord {
                origin: "shared_vault".to_owned(),
                ..DeviceSettingsRecord::default()
            },
        )
        .await
        .unwrap();

    assert_eq!(
        library.device_settings(saved.id.clone()).await.unwrap().origin,
        "shared_vault"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn details_of_a_missing_connection_are_refused_by_code() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();

    let refused = library
        .set_connection_details("6f0b6a4e-3a52-4c2f-9d1e-0c6a2b7f9e11".to_owned(), details())
        .await
        .unwrap_err();

    assert_eq!(refused.code(), "storage.connection_not_found");
}

#[tokio::test(flavor = "multi_thread")]
async fn profiles_are_created_replaced_and_deleted() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let ssh = library
        .save_ssh_profile(SshProfileRecord {
            id: String::new(),
            name: " Bastion ".to_owned(),
            ssh: SshSettings {
                host: "bastion".to_owned(),
                port: Some(22),
                username: Some("ops".to_owned()),
                jump_hosts: Vec::new(),
                auth: SshAuthTag::Agent,
                enabled: None,
                options: None,
            },
        })
        .await
        .unwrap();
    let credential = library
        .save_credential_profile(CredentialProfileRecord {
            id: String::new(),
            name: "Readonly".to_owned(),
            username: "reader".to_owned(),
            password: CredentialPasswordRecord::Reference {
                reference: CredentialReferenceRecord::Env {
                    variable: "DB_PASSWORD".to_owned(),
                },
            },
            secure_field_ids: Vec::new(),
            order: 0,
        })
        .await
        .unwrap();

    let renamed = library
        .save_ssh_profile(SshProfileRecord {
            name: "Edge".to_owned(),
            ..ssh.clone()
        })
        .await
        .unwrap();

    assert_eq!(ssh.name, "Bastion");
    assert_eq!(library.ssh_profiles().await.unwrap(), vec![renamed.clone()]);
    assert_eq!(library.credential_profiles().await.unwrap(), vec![credential.clone()]);
    assert!(library.delete_ssh_profile(renamed.id.clone()).await.unwrap());
    assert!(!library.delete_ssh_profile(renamed.id).await.unwrap());
    assert!(library.delete_credential_profile(credential.id).await.unwrap());
    assert!(library.credential_profiles().await.unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn table_folders_file_tables_and_keep_a_folder_brought_in() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let folders = core.saved_query_database().await.unwrap().table_folders();
    let connection = "6f0b6a4e-3a52-4c2f-9d1e-0c6a2b7f9e11".to_owned();
    let orders = TableRefRecord {
        database: "shop".to_owned(),
        schema: "public".to_owned(),
        name: "orders".to_owned(),
    };

    let sales = folders
        .create(
            connection.clone(),
            "shop".to_owned(),
            "public".to_owned(),
            "Sales".to_owned(),
        )
        .await
        .unwrap();
    folders
        .file(connection.clone(), vec![orders.clone()], sales.id.clone())
        .await
        .unwrap();
    let mut pulled = sales.clone();
    pulled.id = "3d7f338f-27b8-4e35-9cfa-c88ce07131ef".to_owned();
    pulled.created_at_ms = 1_700_000_000_000;
    folders.put(pulled.clone()).await.unwrap();

    assert_eq!(
        folders.items(connection.clone()).await.unwrap(),
        vec![TableFolderItemRecord {
            table: orders.clone(),
            folder_id: sales.id.clone(),
        }]
    );
    assert!(folders.folders(connection.clone()).await.unwrap().contains(&pulled));
    assert!(folders.delete(sales.id).await.unwrap());
    assert!(folders.items(connection).await.unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_save_never_takes_the_id_of_a_connection_this_build_cannot_read() {
    let dir = tempfile::tempdir().unwrap();
    let held = "6f0b6a4e-3a52-4c2f-9d1e-0c6a2b7f9e11";
    let entry = format!(
        r#"{{"id":"{held}","name":"prod","driver_id":"postgres","host":"db","port":5432,"database":"d","username":"u","tls":{{"mode":"disable"}},"safe_mode":"paranoid","external_access":"read_only","ai_policy":"ask"}}"#
    );
    std::fs::write(
        dir.path().join("connections.json"),
        format!(r#"{{"version": 1, "connections": [{entry}]}}"#),
    )
    .unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();

    let saved = library
        .save(
            ConnectionRecord {
                id: held.to_owned(),
                host: "attacker.example".to_owned(),
                ..record("prod")
            },
            ConnectionSecrets::default(),
        )
        .await
        .unwrap();

    assert_ne!(saved.id, held);
    let file = std::fs::read_to_string(dir.path().join("connections.json")).unwrap();
    assert!(file.contains("paranoid"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_profile_save_never_takes_the_id_of_a_profile_this_build_cannot_read() {
    let dir = tempfile::tempdir().unwrap();
    let ssh = "3fd0b191-5cf8-4760-84a9-92779983f3cf";
    let credential = "c00996e7-3992-4501-99a1-03cf155ab59a";
    std::fs::write(
        dir.path().join("connections.json"),
        format!(
            r#"{{"version": 1, "connections": [],
                "ssh_profiles": [{{"id":"{ssh}","name":"p","host":"h","auth":{{"kind":"quantum"}}}}],
                "credential_profiles": [{{"id":"{credential}","name":"c","password":{{"mode":"hardware_key"}}}}]}}"#
        ),
    )
    .unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();

    let saved_ssh = library
        .save_ssh_profile(SshProfileRecord {
            id: ssh.to_owned(),
            name: "stale".to_owned(),
            ssh: SshSettings {
                host: "attacker.example".to_owned(),
                port: None,
                username: None,
                jump_hosts: Vec::new(),
                auth: SshAuthTag::Agent,
                enabled: None,
                options: None,
            },
        })
        .await
        .unwrap();
    let saved_credential = library
        .save_credential_profile(CredentialProfileRecord {
            id: credential.to_owned(),
            name: "stale".to_owned(),
            username: "u".to_owned(),
            password: CredentialPasswordRecord::Stored,
            secure_field_ids: Vec::new(),
            order: 0,
        })
        .await
        .unwrap();

    assert_ne!(saved_ssh.id, ssh);
    assert_ne!(saved_credential.id, credential);
    let file = std::fs::read_to_string(dir.path().join("connections.json")).unwrap();
    assert!(file.contains("quantum"));
    assert!(file.contains("hardware_key"));
}

fn mac_library() -> LibraryWriteRecord {
    let group = "E6C12C96-3CBD-4A0E-9F41-E36B47F35D84".to_lowercase();
    let tag = "00000000-0000-0000-0000-000000000003".to_owned();
    let mut connection = record(" Prod\t(EU) ");
    connection.id = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44".to_lowercase();
    connection.host = " db.internal ".to_owned();
    connection.tls = TlsSettings {
        mode: TlsModeTag::VerifyCa,
        ca_file: Some("ca.pem".to_owned()),
        client_certificate: Some("client.pem".to_owned()),
        client_key: None,
        server_name: None,
    };
    connection.safe_mode = SafeModeTag::SafeModeFull;
    connection.ai_policy = Some(AiPolicyTag::AppDefault);
    connection.external_access = Some(ExternalAccessTag::ReadWrite);
    connection.group_id = Some(group.clone());
    connection.order = 7;
    connection.tags = vec![tag.clone(), "84bc7d00-a144-4c18-80c0-a11c6070d4f9".to_owned()];
    connection.last_opened_ms = Some(1_700_000_000_123);
    connection.icon = library_icon_for_symbol("cylinder.split.1x2".to_owned());
    connection.ssh = Some(SshSettings {
        host: "bastion".to_owned(),
        port: Some(2222),
        username: None,
        jump_hosts: vec![SshJumpHostRecord {
            id: Some("3FD0B191-5CF8-4760-84A9-92779983F3CF".to_lowercase()),
            host: "jump".to_owned(),
            port: None,
            username: Some("ops".to_owned()),
            auth: Some(SshJumpAuthTag::PrivateKey),
            key_path: Some("~/.ssh/hop".to_owned()),
        }],
        auth: SshAuthTag::None,
        enabled: Some(false),
        options: Some(SshOptionsRecord {
            kept_key_path: Some("~/.ssh/id_ed25519".to_owned()),
            agent_socket: Some("~/.1password/agent.sock".to_owned()),
            totp: SshTotpRecord {
                mode: SshTotpModeTag::AutoGenerate,
                algorithm: SshTotpAlgorithmTag::Sha256,
                digits: 8,
                period: 60,
            },
            remote_file_path: Some("~/app.db".to_owned()),
            remote_file_access: RemoteFileAccessTag::OnServer,
        }),
    });
    LibraryWriteRecord {
        connections: vec![LibraryConnectionRecord {
            connection,
            details: details(),
            device: DeviceSettingsRecord {
                local_only: true,
                origin: "synced".to_owned(),
                ..DeviceSettingsRecord::default()
            },
        }],
        groups: vec![GroupRecord {
            id: group,
            name: " ".to_owned(),
            parent_id: Some("380cb783-4b26-48f3-8f84-1468967a9fa3".to_owned()),
            order: 4,
            color: None,
            icon: library_icon_for_symbol("server.rack".to_owned()),
        }],
        tags: vec![TagRecord {
            id: tag,
            name: "production with a name longer than thirty-two".to_owned(),
            color: None,
            is_preset: true,
        }],
        favorites: vec!["6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44".to_owned()],
        removing: Vec::new(),
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    use std::fmt::Write;
    Sha256::digest(bytes).iter().fold(String::new(), |mut text, byte| {
        let _ = write!(text, "{byte:02x}");
        text
    })
}

#[tokio::test(flavor = "multi_thread")]
async fn a_library_read_and_write_give_the_digest_of_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let file = dir.path().join("connections.json");
    assert_eq!(library.library_contents().await.unwrap().digest, None);

    let written = library.replace_library(mac_library(), None).await.unwrap();

    let on_disk = sha256_hex(&std::fs::read(&file).unwrap());
    assert_eq!(written.digest.as_deref(), Some(on_disk.as_str()));
    assert_eq!(library.library_contents().await.unwrap().digest, written.digest);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_library_write_keeps_every_path_and_host_as_given() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let mut written = mac_library();
    let connection = &mut written.connections[0].connection;
    connection.tls.ca_file = Some(" ca.pem ".to_owned());
    connection.tls.client_certificate = Some(" client.pem ".to_owned());
    connection.tls.client_key = Some(" client.key ".to_owned());
    if let Some(ssh) = connection.ssh.as_mut() {
        ssh.host = " bastion ".to_owned();
        ssh.auth = SshAuthTag::PrivateKey {
            path: Some(" ~/.ssh/id_rsa ".to_owned()),
            has_passphrase: true,
        };
        ssh.jump_hosts[0].key_path = Some(" ~/.ssh/hop ".to_owned());
        ssh.jump_hosts.push(SshJumpHostRecord {
            id: None,
            host: "edge,inner".to_owned(),
            port: None,
            username: Some(" ops".to_owned()),
            auth: None,
            key_path: None,
        });
        if let Some(options) = ssh.options.as_mut() {
            options.kept_key_path = Some(" ~/.ssh/kept ".to_owned());
            options.agent_socket = Some(" agent.sock ".to_owned());
            options.remote_file_path = Some(" ~/app.db ".to_owned());
        }
    }

    library.replace_library(written.clone(), None).await.unwrap();

    assert_eq!(
        library.library_contents().await.unwrap().connections,
        written.connections
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_library_write_over_a_file_changed_since_it_was_read_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let vouched = library.replace_library(mac_library(), None).await.unwrap();
    let file = dir.path().join("connections.json");
    let swapped = std::fs::read_to_string(&file)
        .unwrap()
        .replace("db.internal", "attacker.example");
    std::fs::write(&file, &swapped).unwrap();

    let refused = library.replace_library(mac_library(), vouched.digest).await;

    assert_eq!(
        refused.err().map(|error| error.code().to_owned()),
        Some("storage.library_changed".to_owned())
    );
    assert_eq!(std::fs::read_to_string(&file).unwrap(), swapped);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_library_write_refuses_a_blank_hop_id_and_a_time_out_of_range() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let mut blank_hop = mac_library();
    if let Some(ssh) = blank_hop.connections[0].connection.ssh.as_mut() {
        ssh.jump_hosts[0].id = Some("  ".to_owned());
    }
    let mut far_time = mac_library();
    far_time.connections[0].connection.last_opened_ms = Some(i64::MAX);

    assert!(library.replace_library(blank_hop, None).await.is_err());
    assert!(library.replace_library(far_time, None).await.is_err());
    assert_eq!(library.library_contents().await.unwrap().digest, None);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rebuild_sets_aside_a_file_this_build_cannot_read() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("connections.json");
    std::fs::write(&file, b"{ half an edit").unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();

    let rebuilt = library.rebuild_library(mac_library()).await.unwrap();

    let aside = rebuilt.set_aside.expect("set aside");
    assert_eq!(std::fs::read(&aside).unwrap(), b"{ half an edit");
    assert_eq!(
        library.library_contents().await.unwrap().connections,
        mac_library().connections
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_library_write_refuses_a_hop_id_that_does_not_read() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let mut written = mac_library();
    if let Some(ssh) = written.connections[0].connection.ssh.as_mut() {
        ssh.jump_hosts[0].id = Some("not an id".to_owned());
    }

    let refused = library.replace_library(written, None).await;

    assert!(refused.is_err(), "{refused:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rebuild_keeps_only_what_the_write_names() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let written = mac_library();
    library.replace_library(written.clone(), None).await.unwrap();
    library
        .save_ssh_profile(SshProfileRecord {
            id: String::new(),
            name: "jump".to_owned(),
            ssh: SshSettings {
                host: "jump.example".to_owned(),
                port: None,
                username: None,
                jump_hosts: Vec::new(),
                auth: SshAuthTag::Agent,
                enabled: None,
                options: None,
            },
        })
        .await
        .unwrap();
    let file = dir.path().join("connections.json");
    let mut stored: serde_json::Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    stored["connections"][0]["from_a_newer_build"] = serde_json::json!(true);
    stored["connections"][0]["tls"]["pinned"] = serde_json::json!("sha256/abc");
    std::fs::write(&file, serde_json::to_vec(&stored).unwrap()).unwrap();

    let rebuilt = library.rebuild_library(written.clone()).await.unwrap();

    let text = std::fs::read_to_string(&file).unwrap();
    assert!(!text.contains("from_a_newer_build"), "{text}");
    assert!(!text.contains("pinned"), "{text}");
    assert!(!text.contains("jump.example"), "{text}");
    assert_eq!(rebuilt.digest.as_deref(), Some(sha256_hex(text.as_bytes()).as_str()));
    assert_eq!(
        library.library_contents().await.unwrap().connections,
        written.connections
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_library_written_whole_reads_back_as_it_was_written() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let written = mac_library();

    library.replace_library(written.clone(), None).await.unwrap();
    let read = library.library_contents().await.unwrap();

    assert_eq!(read.connections, written.connections);
    assert_eq!(read.groups, written.groups);
    assert_eq!(read.tags, written.tags);
    assert_eq!(read.favorites, written.favorites);
    assert!(read.unreadable.is_empty());
    assert_eq!(
        library_icon_symbol(read.groups[0].icon.clone().unwrap())
            .unwrap()
            .as_deref(),
        Some("server.rack")
    );
    let snapshot = library.snapshot().await.unwrap();
    assert_eq!(
        snapshot.groups[0].parent_id, None,
        "a parent the library lacks reads as the top"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_form_save_keeps_what_the_form_does_not_show() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let written = mac_library();
    library.replace_library(written.clone(), None).await.unwrap();
    let mut form = library.snapshot().await.unwrap().connections.remove(0);
    form.safe_mode = SafeModeTag::ReadOnly;
    form.ai_policy = Some(AiPolicyTag::Ask);
    form.icon = None;
    if let Some(ssh) = form.ssh.as_mut() {
        ssh.options = None;
        ssh.enabled = Some(true);
        ssh.auth = SshAuthTag::Agent;
        ssh.jump_hosts = parse_jump_hosts("ops@jump".to_owned()).unwrap();
    }
    form.tls.client_certificate = None;
    form.tls.mode = TlsModeTag::VerifyFull;

    library.save(form, ConnectionSecrets::default()).await.unwrap();
    let saved = library
        .library_contents()
        .await
        .unwrap()
        .connections
        .remove(0)
        .connection;

    let before = &written.connections[0].connection;
    assert_eq!(saved.safe_mode, SafeModeTag::SafeModeFull);
    assert_eq!(saved.tls.mode, TlsModeTag::VerifyCa, "Verify CA shows as Verify full");
    assert_eq!(saved.ai_policy, Some(AiPolicyTag::AppDefault));
    assert_eq!(saved.icon, before.icon);
    let (ssh, held) = (saved.ssh.unwrap(), before.ssh.clone().unwrap());
    assert_eq!(ssh.auth, SshAuthTag::None);
    assert_eq!(ssh.options, held.options);
    assert_eq!(ssh.jump_hosts, held.jump_hosts);
    assert_eq!(ssh.enabled, Some(true));
    assert_eq!(saved.name, "Prod (EU)");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_form_that_sends_a_tunnel_turns_one_switched_off_back_on() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let library = core.library().unwrap();
    let mut written = mac_library();
    if let Some(ssh) = written.connections[0].connection.ssh.as_mut() {
        ssh.options = None;
    }
    library.replace_library(written.clone(), None).await.unwrap();
    let mut form = library.snapshot().await.unwrap().connections.remove(0);
    let mut ssh = form.ssh.take().unwrap();
    ssh.enabled = None;
    ssh.options = None;
    form.ssh = Some(ssh);
    // A form save refuses half a client identity, which the library write kept.
    form.tls.client_certificate = None;

    library.save(form.clone(), ConnectionSecrets::default()).await.unwrap();
    let saved = library
        .library_contents()
        .await
        .unwrap()
        .connections
        .remove(0)
        .connection;
    assert_eq!(saved.ssh.and_then(|ssh| ssh.enabled), Some(true));

    form.ssh = None;
    library.save(form, ConnectionSecrets::default()).await.unwrap();
    let off = library
        .library_contents()
        .await
        .unwrap()
        .connections
        .remove(0)
        .connection;
    assert_eq!(
        off.ssh.map(|ssh| (ssh.enabled, ssh.host)),
        Some((Some(false), "bastion".to_owned()))
    );
}
