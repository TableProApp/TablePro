// A team connection's secrets as team envelopes, end to end on the fake server: sealed under the team key when a
// writer publishes them, kept sealed in each device's Team Library store, and opened for a member only for the
// destination the team's copy names (0056, Envelopes and history; 0079).

use std::sync::Arc;

use secrecy::{ExposeSecret, SecretString};
use serde_json::{Value, json};
use tablepro_keys::encoding::{AccountId, TeamId};
use tablepro_records::envelope::SecretKind;
use tablepro_storage::TeamLibraryKind;
use tablepro_sync::api::control::SyncControl;
use tablepro_sync::api::key_flows::TeamFlows;
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::team_library::{
    SecretsLeftOut, TeamConnection, TeamItemRef, TeamLibraryControl, TeamSecret, TeamSecrets,
};
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::service::{Policies, ScopeOwner};
use uuid::Uuid;

use super::device::Device;
use super::harness::new_account;

const CONNECTION: u128 = 0x0193_0000_0000_7000_8000_0000_0000_00C1;

fn connection_id() -> String {
    Uuid::from_u128(CONNECTION).hyphenated().to_string()
}

fn envelope_id(kind: &str) -> String {
    format!("library_connection/{}/{kind}", connection_id())
}

fn settings(port: u16) -> Value {
    json!({"name": "Shop", "type": "PostgreSQL", "host": "db.internal", "port": port, "database": "shop",
        "username": "app"})
}

fn tunnelled(port: u16) -> Value {
    let mut fields = settings(port);
    fields["sshConfig"] = json!({"enabled": true, "host": "bastion.internal", "port": 22, "username": "ops",
        "authMethod": "Password"});
    fields
}

fn secret(kind: SecretKind, value: &str) -> TeamSecret {
    TeamSecret {
        kind,
        value: SecretString::from(value.to_owned()),
    }
}

fn connection(fields: Value, secrets: TeamSecrets) -> TeamConnection {
    TeamConnection {
        id: Uuid::from_u128(CONNECTION),
        settings: fields,
        secrets,
    }
}

fn with_password(port: u16, password: &str) -> TeamConnection {
    connection(
        settings(port),
        TeamSecrets::Set(vec![secret(SecretKind::Password, password)]),
    )
}

struct World {
    server: Arc<FakeServer>,
    team: TeamId,
    owner: Device,
    editor: Device,
    viewer: Device,
    dir: tempfile::TempDir,
}

// Every value the pass brought, approved, as the person does in the Review sheet.
async fn approve_all(device: &Device) {
    for approval in device.sync.approvals().await.unwrap() {
        device
            .sync
            .decide_record_approval(approval.key, approval.digest, true)
            .await
            .unwrap();
    }
}

async fn pulled(device: &Device) {
    device.pass().await;
    approve_all(device).await;
}

async fn joined(server: &Arc<FakeServer>, account: AccountId, row: &str, dir: &std::path::Path) -> Device {
    let device = Device::with_team_library(server, account, row, dir).await;
    device.genesis().await;
    device.pass().await;
    device
}

// An owner with the team's key, and an editor and a viewer it confirmed.
async fn world() -> World {
    let server = FakeServer::new();
    let (owner_id, editor_id, viewer_id) = (new_account(), new_account(), new_account());
    let team = TeamId(tablepro_keys::encoding::random_uuid().unwrap());
    server.add_team(
        team,
        &[
            (owner_id, Role::Owner),
            (editor_id, Role::Editor),
            (viewer_id, Role::Member),
        ],
    );
    let dir = tempfile::tempdir().unwrap();
    let owner = joined(&server, owner_id, "dev_owner", dir.path()).await;
    owner.keys.create_team_keys(team).await.unwrap();
    let editor = joined(&server, editor_id, "dev_editor", dir.path()).await;
    let viewer = joined(&server, viewer_id, "dev_viewer", dir.path()).await;
    owner.pass().await;
    owner.keys.confirm_member(team, editor_id).await.unwrap();
    owner.keys.confirm_member(team, viewer_id).await.unwrap();
    editor.pass().await;
    viewer.pass().await;
    World {
        server,
        team,
        owner,
        editor,
        viewer,
        dir,
    }
}

async fn secrets(device: &Device, team: TeamId) -> Vec<(SecretKind, String)> {
    device
        .sync
        .team_connection_secrets(team, connection_id())
        .await
        .unwrap()
        .into_iter()
        .map(|secret| (secret.kind, secret.value.expose_secret().to_owned()))
        .collect()
}

fn stored(world: &World, kind: &str) -> Option<Value> {
    world
        .server
        .stored(ScopeOwner::Team(world.team), "secret_envelope", &envelope_id(kind))
        .filter(|record| record.deleted.is_none())
        .and_then(|record| record.fields)
}

fn held_envelopes(device: &Device, team: TeamId) -> Vec<String> {
    device
        .store
        .as_ref()
        .unwrap()
        .team_blocking(&tablepro_sync::api::ids::ScopeName::Team(team).wire())
        .unwrap()
        .map(|team| team.envelopes.into_iter().map(|envelope| envelope.id).collect())
        .unwrap_or_default()
}

// A key passphrase opens a key file on the device that published, which a team copy does not name, so none goes up even
// when the publish carries one.
#[tokio::test]
async fn a_publish_seals_no_key_passphrase() {
    let world = world().await;
    let mut fields = tunnelled(5432);
    fields["sshConfig"]["authMethod"] = json!("Private Key");
    fields["sshConfig"]["privateKeyPath"] = json!("~/.ssh/id_ed25519");
    fields["sslConfig"] = json!({"mode": "Verify CA", "clientKeyPath": "~/certs/me.key"});
    let secrets = TeamSecrets::Set(vec![
        secret(SecretKind::Password, "s3cret"),
        secret(SecretKind::SshKeyPassphrase, "key-pass"),
        secret(SecretKind::SslKeyPassphrase, "tls-pass"),
    ]);

    let published = world
        .owner
        .sync
        .publish_team_connections(world.team, vec![connection(fields, secrets)])
        .await
        .unwrap();

    assert_eq!(published.secrets_left_out, None);
    assert!(stored(&world, "password").is_some());
    assert!(stored(&world, "ssh_key_passphrase").is_none());
    assert!(stored(&world, "ssl_key_passphrase").is_none());
}

#[tokio::test]
async fn an_owner_s_password_goes_up_sealed_and_an_editor_and_a_viewer_connect_with_it() {
    let world = world().await;

    let published = world
        .owner
        .sync
        .publish_team_connections(world.team, vec![with_password(5432, "s3cret")])
        .await
        .unwrap();
    let again = world
        .owner
        .sync
        .publish_team_connections(world.team, vec![with_password(5432, "s3cret")])
        .await
        .unwrap();
    pulled(&world.editor).await;
    pulled(&world.viewer).await;

    assert_eq!((published.edits, published.unsent), (2, 0));
    assert_eq!(published.secrets_left_out, None);
    assert_eq!(again.edits, 0, "{again:?}");
    let sealed = stored(&world, "password").expect("the password's envelope is on the server");
    assert_eq!(sealed["kv"], 1);
    assert!(!sealed.to_string().contains("s3cret"));
    let expected = vec![(SecretKind::Password, "s3cret".to_owned())];
    assert_eq!(secrets(&world.editor, world.team).await, expected);
    assert_eq!(secrets(&world.viewer, world.team).await, expected);
    assert_eq!(secrets(&world.owner, world.team).await, expected);
    let listed = world.viewer.sync.team_library().await.unwrap();
    assert!(listed.iter().all(|team| team.syncs_passwords));
}

#[tokio::test]
async fn an_editor_s_port_change_seals_the_password_again_and_every_member_reads_it() {
    let world = world().await;
    world
        .owner
        .sync
        .publish_team_connections(world.team, vec![with_password(5432, "s3cret")])
        .await
        .unwrap();
    pulled(&world.editor).await;
    let before = stored(&world, "password").unwrap();

    let edited = world
        .editor
        .sync
        .publish_team_connections(world.team, vec![with_password(5433, "s3cret")])
        .await
        .unwrap();
    pulled(&world.owner).await;
    pulled(&world.viewer).await;

    assert_eq!((edited.edits, edited.unsent, edited.secrets_left_out), (2, 0, None));
    assert_ne!(stored(&world, "password").unwrap(), before);
    let expected = vec![(SecretKind::Password, "s3cret".to_owned())];
    assert_eq!(secrets(&world.owner, world.team).await, expected);
    assert_eq!(secrets(&world.viewer, world.team).await, expected);
}

#[tokio::test]
async fn a_destination_changed_without_a_new_seal_opens_no_secret() {
    let world = world().await;
    world
        .owner
        .sync
        .publish_team_connections(world.team, vec![with_password(5432, "s3cret")])
        .await
        .unwrap();
    pulled(&world.editor).await;
    let sealed = stored(&world, "password").unwrap();

    let moved = world
        .owner
        .sync
        .publish_team_connections(world.team, vec![connection(settings(6000), TeamSecrets::Keep)])
        .await
        .unwrap();
    pulled(&world.editor).await;

    assert_eq!(moved.edits, 1);
    assert_eq!(stored(&world, "password").unwrap(), sealed);
    assert!(secrets(&world.editor, world.team).await.is_empty());
}

#[tokio::test]
async fn with_password_sync_off_the_connection_goes_up_without_its_envelope_and_says_so() {
    let world = world().await;
    world.server.set_policies(Policies {
        password_sync: false,
        ..Policies::default()
    });

    let published = world
        .owner
        .sync
        .publish_team_connections(world.team, vec![with_password(5432, "s3cret")])
        .await
        .unwrap();
    let listed = world.owner.sync.team_library().await.unwrap();

    assert_eq!(published.secrets_left_out, Some(SecretsLeftOut::PasswordsOff));
    assert_eq!(published.edits, 1);
    assert!(stored(&world, "password").is_none());
    assert!(
        world
            .server
            .stored(ScopeOwner::Team(world.team), "library_connection", &connection_id())
            .is_some()
    );
    assert!(held_envelopes(&world.owner, world.team).is_empty());
    assert!(listed.iter().all(|team| !team.syncs_passwords));
}

#[tokio::test]
async fn a_viewer_s_edit_is_refused_and_writes_nothing() {
    let world = world().await;
    world
        .owner
        .sync
        .publish_team_connections(world.team, vec![with_password(5432, "s3cret")])
        .await
        .unwrap();
    pulled(&world.viewer).await;
    let sealed = stored(&world, "password").unwrap();

    let refused = world
        .viewer
        .sync
        .publish_team_connections(world.team, vec![with_password(7000, "other")])
        .await;

    assert_eq!(refused.unwrap_err().code(), "sync.team_library.not_writable");
    assert_eq!(stored(&world, "password").unwrap(), sealed);
}

// The owner's own rotation meets the mark on its device, while the server still holds it: the server turns the sealed
// password down, and the engine holds it until the team is no longer due, sealed again under each version the key
// moved on to meanwhile, then sends it.
#[tokio::test]
async fn a_password_the_server_turns_down_while_the_team_is_due_goes_up_once_the_rotation_applies() {
    let world = world().await;
    world.server.set_rotation_due(world.team, true);
    world.owner.pass().await;

    let published = world
        .owner
        .sync
        .publish_team_connections(world.team, vec![with_password(5432, "s3cret")])
        .await
        .unwrap();
    let held_back = stored(&world, "password");
    world.server.set_rotation_due(world.team, false);
    world.owner.pass().await;
    pulled(&world.editor).await;

    assert_eq!(
        (published.unsent, published.problem.as_deref()),
        (1, Some("rotation_due"))
    );
    assert!(held_back.is_none());
    assert!(
        world
            .server
            .stored(ScopeOwner::Team(world.team), "library_connection", &connection_id())
            .is_some()
    );
    let current = world.owner.keys.team_keys(world.team).await.unwrap().version.unwrap();
    assert_eq!(stored(&world, "password").unwrap()["kv"], current.get());
    assert_eq!(
        secrets(&world.editor, world.team).await,
        vec![(SecretKind::Password, "s3cret".to_owned())]
    );
}

#[tokio::test]
async fn an_editor_not_yet_confirmed_publishes_the_connection_without_its_secrets() {
    let world = world().await;
    let late = new_account();
    world.server.set_role(world.team, late, Some(Role::Editor));
    let unconfirmed = joined(&world.server, late, "dev_late", world.dir.path()).await;

    let published = unconfirmed
        .sync
        .publish_team_connections(world.team, vec![with_password(5432, "s3cret")])
        .await
        .unwrap();

    assert_eq!(published.secrets_left_out, Some(SecretsLeftOut::NotConfirmed));
    assert_eq!(published.edits, 1);
    assert!(stored(&world, "password").is_none());
}

#[tokio::test]
async fn a_kind_left_out_loses_its_envelope_keep_changes_none_and_a_removal_takes_them_all() {
    let world = world().await;
    let both = TeamSecrets::Set(vec![
        secret(SecretKind::Password, "s3cret"),
        secret(SecretKind::SshPassword, "tunnel"),
    ]);
    world
        .owner
        .sync
        .publish_team_connections(world.team, vec![connection(tunnelled(5432), both)])
        .await
        .unwrap();
    let tunnel_sealed = stored(&world, "ssh_password").is_some();

    let narrowed = world
        .owner
        .sync
        .publish_team_connections(
            world.team,
            vec![connection(
                tunnelled(5432),
                TeamSecrets::Set(vec![secret(SecretKind::Password, "s3cret")]),
            )],
        )
        .await
        .unwrap();
    let password = stored(&world, "password").unwrap();
    let kept = world
        .owner
        .sync
        .publish_team_connections(world.team, vec![connection(tunnelled(5432), TeamSecrets::Keep)])
        .await
        .unwrap();
    let password_after_keep = stored(&world, "password");
    let removed = world
        .owner
        .sync
        .remove_team_items(
            world.team,
            vec![TeamItemRef {
                kind: TeamLibraryKind::Connection,
                id: connection_id(),
            }],
        )
        .await
        .unwrap();

    assert!(tunnel_sealed);
    assert_eq!(narrowed.edits, 1, "{narrowed:?}");
    assert_eq!(kept.edits, 0, "{kept:?}");
    assert_eq!(password_after_keep, Some(password));
    assert_eq!(removed.edits, 2, "{removed:?}");
    assert!(stored(&world, "password").is_none());
    assert!(stored(&world, "ssh_password").is_none());
    assert!(held_envelopes(&world.owner, world.team).is_empty());
}
