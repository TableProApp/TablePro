use super::*;
use tempfile::TempDir;

#[tokio::test]
async fn an_ssh_chain_at_the_hop_cap_is_accepted() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connections.json");
    let mut connection = super::tests::sample_connection();
    connection.ssh = Some(crate::connection_bundle::ssh_chain_for_test(MAX_SSH_HOPS));

    save_to(&path, std::slice::from_ref(&connection)).await.unwrap();
    assert_eq!(load_from(&path).await.unwrap(), vec![connection]);
}

#[tokio::test]
async fn an_ssh_chain_past_the_hop_cap_is_refused() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connections.json");
    let mut connection = super::tests::sample_connection();
    connection.ssh = Some(crate::connection_bundle::ssh_chain_for_test(MAX_SSH_HOPS + 1));

    let error = save_to(&path, std::slice::from_ref(&connection)).await.unwrap_err();
    assert!(matches!(error, StorageError::Schema(_)), "{error:?}");
    assert!(!path.exists());
}

#[tokio::test]
async fn a_file_holding_an_over_deep_ssh_chain_is_refused_on_load() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connections.json");
    let mut connection = super::tests::sample_connection();
    connection.ssh = Some(crate::connection_bundle::ssh_chain_for_test(MAX_SSH_HOPS + 1));
    let document = serde_json::json!({
        "version": CURRENT_VERSION,
        "connections": [serde_json::to_value(&connection).unwrap()],
    });
    std::fs::write(&path, serde_json::to_vec(&document).unwrap()).unwrap();

    assert!(load_from(&path).await.is_err());
}

#[tokio::test]
async fn unsupported_connections_file_versions_are_refused() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connections.json");

    for version in [0, CURRENT_VERSION + 1] {
        std::fs::write(&path, format!(r#"{{"version":{version},"connections":[]}}"#)).unwrap();

        let error = load_from(&path).await.unwrap_err();

        assert!(matches!(error, StorageError::Schema(message) if message.contains("not supported")));
    }
}

#[tokio::test]
async fn saving_a_legacy_ssh_chain_persists_distinct_stable_hop_ids() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connections.json");
    let id = Uuid::new_v4();
    let legacy = format!(
        r#"{{"version":1,"connections":[{{
            "id":"{id}","name":"Legacy","driver_id":"postgres",
            "host":"db.example","port":5432,"database":"postgres",
            "username":"app","use_tls":false,
            "ssh":{{
                "host":"edge.example","port":22,"username":"edge",
                "auth":{{"kind":"password"}},
                "jump":{{
                    "host":"bastion.example","port":2222,"username":"deploy",
                    "auth":{{"kind":"private_key","path":"/home/app/.ssh/id_ed25519"}}
                }}
            }}
        }}]}}"#
    );
    tokio::fs::write(&path, legacy).await.unwrap();

    let loaded = load_from(&path).await.unwrap();
    save_to(&path, &loaded).await.unwrap();
    let after_migration: serde_json::Value = serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    assert_eq!(after_migration["version"], 2);
    let root_id = after_migration["connections"][0]["ssh"]["hop_id"]
        .as_str()
        .expect("the root hop must have a persisted ID");
    let jump_id = after_migration["connections"][0]["ssh"]["jump"]["hop_id"]
        .as_str()
        .expect("the jump hop must have a persisted ID");
    assert_ne!(root_id, jump_id, "each hop needs its own credential identity");
    Uuid::parse_str(root_id).unwrap();
    Uuid::parse_str(jump_id).unwrap();

    let loaded_again = load_from(&path).await.unwrap();
    save_to(&path, &loaded_again).await.unwrap();
    let after_second_save: serde_json::Value = serde_json::from_slice(&tokio::fs::read(&path).await.unwrap()).unwrap();
    assert_eq!(after_second_save["connections"][0]["ssh"]["hop_id"], root_id);
    assert_eq!(after_second_save["connections"][0]["ssh"]["jump"]["hop_id"], jump_id);
}
