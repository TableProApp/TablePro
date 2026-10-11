use super::*;

#[tokio::test]
#[ignore = "requires a running Secret Service; scripts/test-secret-service.sh provides one"]
async fn private_key_passphrases_use_the_secret_bound_to_each_hop() {
    let connection_id = Uuid::new_v4();
    let root_passphrase = Uuid::new_v4().to_string();
    let jump_passphrase = Uuid::new_v4().to_string();
    let root = encrypted_key_chain();
    let hops = root.flatten_hops();
    for (hop, passphrase) in hops.iter().zip([&root_passphrase, &jump_passphrase]) {
        tablepro_storage::store_ssh_hop_passphrase(
            connection_id,
            hop.hop_id,
            hop.credential_revision,
            passphrase,
            "BookiE test SSH key passphrase",
        )
        .await
        .unwrap();
    }

    let resolved = resolve_saved_ssh_chain(connection_id, &root).await.unwrap();
    let passphrases = resolved
        .iter()
        .map(|hop| match &hop.auth {
            SshAuth::PrivateKey { passphrase, .. } => passphrase
                .as_ref()
                .map(|secret| secrecy::ExposeSecret::expose_secret(secret).to_owned()),
            _ => panic!("expected private-key auth"),
        })
        .collect::<Vec<_>>();

    for hop in hops {
        tablepro_storage::delete_ssh_hop_passphrase(connection_id, hop.hop_id, hop.credential_revision)
            .await
            .unwrap();
    }
    assert_eq!(passphrases, [Some(root_passphrase), Some(jump_passphrase)]);
}

#[tokio::test]
#[ignore = "requires a running Secret Service; scripts/test-secret-service.sh provides one"]
async fn a_missing_jump_key_passphrase_does_not_receive_the_root_secret() {
    let connection_id = Uuid::new_v4();
    let root_passphrase = Uuid::new_v4().to_string();
    let root = encrypted_key_chain();
    let hops = root.flatten_hops();
    tablepro_storage::store_ssh_hop_passphrase(
        connection_id,
        hops[0].hop_id,
        hops[0].credential_revision,
        &root_passphrase,
        "BookiE test root SSH key passphrase",
    )
    .await
    .unwrap();

    let resolved = resolve_saved_ssh_chain(connection_id, &root).await.unwrap();
    tablepro_storage::delete_ssh_hop_passphrase(connection_id, hops[0].hop_id, hops[0].credential_revision)
        .await
        .unwrap();

    let passphrases = resolved
        .iter()
        .map(|hop| match &hop.auth {
            SshAuth::PrivateKey { passphrase, .. } => passphrase
                .as_ref()
                .map(|secret| secrecy::ExposeSecret::expose_secret(secret).to_owned()),
            _ => panic!("expected private-key auth"),
        })
        .collect::<Vec<_>>();
    assert_eq!(passphrases, [Some(root_passphrase), None]);
}

fn encrypted_key_chain() -> SavedSshConfig {
    SavedSshConfig {
        hop_id: Uuid::new_v4(),
        credential_revision: 3,
        auth: SavedSshAuth::PrivateKey {
            path: "/unused/root-key".into(),
            has_passphrase: true,
        },
        jump: Some(Box::new(SavedSshConfig {
            hop_id: Uuid::new_v4(),
            credential_revision: 8,
            auth: SavedSshAuth::PrivateKey {
                path: "/unused/jump-key".into(),
                has_passphrase: true,
            },
            ..key_hop("jump.example")
        })),
        ..key_hop("root.example")
    }
}
