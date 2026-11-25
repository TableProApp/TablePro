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
    CloudflareAuthTag, CloudflareTunnelRecord, ConnectionDetailsRecord, ConnectionRecord, ConnectionSecrets, Core,
    CredentialPasswordRecord, CredentialProfileRecord, CredentialReferenceRecord, DeviceSettingsRecord, HostConfig,
    HostSecretError, HostSecrets, LocalPasswordSourceRecord, SafeModeTag, SecretItemTag, SecretKindTag, SshAuthTag,
    SshProfileRecord, SshSettings, TableFolderItemRecord, TableRefRecord, TlsModeTag, TlsSettings, VaultAuthRecord,
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
        safe_mode: SafeModeTag::Off,
        query_timeout_secs: None,
        color: None,
        group_id: None,
        last_opened_ms: None,
        tags: Vec::new(),
        ai_policy: None,
        external_access: None,
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
    let folders = core.history().await.unwrap().table_folders();
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
