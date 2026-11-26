// A team's key life on the fake server: creation, a member's certificate copied in, confirmation, envelopes both ways,
// and the rotation a member's removal starts on the next roster read.

use std::sync::Arc;

use secrecy::{ExposeSecret, SecretString};
use serde_json::json;
use tablepro_keys::encoding::{AccountId, TeamId, Version, random_uuid};
use tablepro_keys::envelope::{EnvelopeId, ParentKind, SecretKind};
use tablepro_sync::SyncError;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::{
    ArrivalOrder, CaughtUp, KeyApplied, KeyArrival, MemberKeyStatus, Roster, TeamFlows,
};
use tablepro_sync::api::scopes::{Role, ScopesAnswer};
use tablepro_sync::api::state::{Row, RowKey, ScopeRow};
use tablepro_sync::api::transport::{Proof, PullRequest, RejectedCode, ServiceTransport, Transport};
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::service::ScopeOwner;

use super::harness::{Device, new_account};

fn new_team() -> TeamId {
    TeamId(random_uuid().unwrap())
}

fn envelope() -> EnvelopeId {
    EnvelopeId::new(ParentKind::LibraryConnection, "warehouse", SecretKind::Password).unwrap()
}

pub(super) fn v(value: u32) -> Version {
    Version::new(value).unwrap()
}

// The engine's part of a pass for one team: its pages pulled and their key objects applied in order, then the roster
// read once the pull caught up.
pub(super) async fn team_pass(device: &Device, team: TeamId) -> KeyApplied {
    let scope = ScopeName::Team(team);
    let proof = Proof::Dpop(device.proof().await);
    let mut row = match device.get(RowKey::Scope(scope)).await {
        Some(Row::Scope(row)) => row,
        _ => ScopeRow::new(scope),
    };
    let ScopesAnswer::Body { body, .. } = device.transport.scopes(None, proof.clone()).await.unwrap() else {
        return KeyApplied::default();
    };
    let mut last = KeyApplied::default();
    let caught_up = loop {
        let page = device
            .transport
            .pull(PullRequest {
                scope,
                cursor: row.cursor.clone(),
                limit: None,
                proof: proof.clone(),
            })
            .await
            .unwrap();
        let mark = CaughtUp::from_page(scope, &page);
        let order = if row.cursor.is_none() {
            ArrivalOrder::Snapshot
        } else {
            ArrivalOrder::InOrder
        };
        let records = page
            .records
            .into_iter()
            .filter(|record| record.kind.as_str().starts_with("key."))
            .collect();
        let applied = device
            .service
            .apply_team_objects(KeyArrival { scope, records, order })
            .await
            .unwrap();
        row.epoch = Some(device.server.epoch());
        row.cursor = page.cursor.or(row.cursor);
        row.key_version = applied.in_force.or(row.key_version);
        row.caught_up = page.caught_up;
        device.put(vec![Row::Scope(row.clone())]).await;
        last.refused.extend(applied.refused);
        last.held = applied.held;
        last.in_force = applied.in_force;
        if mark.is_some() {
            break mark;
        }
    };
    let info = body.scopes.iter().find(|info| info.scope == scope).unwrap();
    row.role = info.role;
    row.rotation_due = info.rotation_due;
    device.put(vec![Row::Scope(row)]).await;
    device
        .service
        .roster_read(team, Roster::of(info, caught_up))
        .await
        .unwrap();
    last
}

pub(super) struct Team {
    pub(super) server: Arc<FakeServer>,
    pub(super) team: TeamId,
    pub(super) owner: Device,
    owner_id: AccountId,
}

pub(super) async fn created(members: &[(AccountId, Role)]) -> Team {
    let server = FakeServer::new();
    let owner_id = new_account();
    let team = new_team();
    let mut roster = vec![(owner_id, Role::Owner)];
    roster.extend_from_slice(members);
    server.add_team(team, &roster);
    let owner = Device::new(&server, owner_id, "owner-row").await;
    owner.genesis().await;
    team_pass(&owner, team).await;
    owner.service.create_team_keys(team).await.unwrap();
    Team {
        server,
        team,
        owner,
        owner_id,
    }
}

impl Team {
    // A member's device after genesis and its first team pass, which copies its certificate in.
    pub(super) async fn joined(&self, account: AccountId, row: &str) -> Device {
        self.joined_with_recovery(account, row).await.0
    }

    pub(super) async fn joined_with_recovery(&self, account: AccountId, row: &str) -> (Device, SecretString) {
        let device = Device::new(&self.server, account, row).await;
        let recovery = device.genesis().await;
        team_pass(&device, self.team).await;
        (device, recovery)
    }

    pub(super) async fn confirmed(&self, account: AccountId, row: &str) -> Device {
        let device = self.joined(account, row).await;
        team_pass(&self.owner, self.team).await;
        self.owner.service.confirm_member(self.team, account).await.unwrap();
        team_pass(&device, self.team).await;
        device
    }
}

fn wrapped_to(server: &FakeServer, team: TeamId, version: u32, account: AccountId) -> bool {
    let prefix = format!(
        "{}/team/{version}/account/{}/",
        tablepro_keys::encoding::uuid_to_wire(team.0),
        account.to_wire()
    );
    (1..=8).any(|av| {
        server
            .stored(ScopeOwner::Team(team), "key.wrap", &format!("{prefix}{av}"))
            .is_some()
    })
}

#[tokio::test]
async fn an_owner_creates_the_key_confirms_an_editor_and_each_opens_what_the_other_sealed() {
    let editor_id = new_account();
    let t = created(&[(editor_id, Role::Editor)]).await;
    let created_keys = t.owner.service.team_keys(t.team).await.unwrap();
    assert_eq!((created_keys.version, created_keys.holder), (Some(v(1)), true));

    let editor = t.joined(editor_id, "editor-row").await;
    let waiting = editor.service.team_keys(t.team).await.unwrap();
    assert!(!waiting.holder);
    let early = editor
        .service
        .seal_team_envelope(t.team, envelope(), SecretString::from("s3cret"), json!({}))
        .await;
    assert!(matches!(early, Err(SyncError::NotAllowed { .. })), "{early:?}");

    team_pass(&t.owner, t.team).await;
    let before = t.owner.service.team_keys(t.team).await.unwrap();
    let editor_status = before
        .members
        .iter()
        .find(|member| member.account == editor_id)
        .unwrap();
    assert_eq!(editor_status.status, MemberKeyStatus::AwaitingConfirmation);
    t.owner.service.confirm_member(t.team, editor_id).await.unwrap();
    team_pass(&editor, t.team).await;

    let held = editor.service.team_keys(t.team).await.unwrap();
    assert_eq!((held.version, held.holder), (Some(v(1)), true));
    let dest = json!({"host": "db.internal", "port": 5432});
    let fields = editor
        .service
        .seal_team_envelope(t.team, envelope(), SecretString::from("s3cret"), dest.clone())
        .await
        .unwrap();
    let opened = t
        .owner
        .service
        .open_team_envelope(t.team, envelope(), fields, Some(v(1)))
        .await
        .unwrap();
    assert_eq!(opened.secret.expose_secret(), "s3cret");
    assert_eq!((opened.dest, opened.kv), (dest, v(1)));
}

#[tokio::test]
async fn a_member_removed_from_the_roster_is_left_out_of_the_rotation_its_removal_starts() {
    let (stays, leaves) = (new_account(), new_account());
    let t = created(&[(stays, Role::Editor), (leaves, Role::Editor)]).await;
    let staying = t.confirmed(stays, "stays-row").await;
    t.confirmed(leaves, "leaves-row").await;
    team_pass(&t.owner, t.team).await;
    assert!(wrapped_to(&t.server, t.team, 1, leaves));

    t.server.set_role(t.team, leaves, None);
    team_pass(&t.owner, t.team).await;

    let rotated = t.owner.service.team_keys(t.team).await.unwrap();
    assert_eq!(rotated.version, Some(v(2)));
    assert!(wrapped_to(&t.server, t.team, 2, stays) && wrapped_to(&t.server, t.team, 2, t.owner_id));
    assert!(!wrapped_to(&t.server, t.team, 2, leaves));
    // The real server clears the mark once the rotation applies; the fake leaves that to the test.
    t.server.set_rotation_due(t.team, false);
    team_pass(&staying, t.team).await;
    let fields = staying
        .service
        .seal_team_envelope(t.team, envelope(), SecretString::from("rotated"), json!({}))
        .await
        .unwrap();
    assert_eq!(fields["kv"], 2);
}

#[tokio::test]
async fn confirming_and_rotating_need_the_right_role_and_the_key_held() {
    let (editor_id, member_id) = (new_account(), new_account());
    let t = created(&[(editor_id, Role::Editor), (member_id, Role::Member)]).await;
    let editor = t.confirmed(editor_id, "editor-row").await;
    t.joined(member_id, "member-row").await;
    team_pass(&editor, t.team).await;

    let by_editor = editor.service.confirm_member(t.team, member_id).await;
    assert_eq!(
        by_editor,
        Err(SyncError::Rejected {
            code: RejectedCode::Role
        })
    );
    let rotation = editor.service.rotate_team(t.team, Vec::new()).await;
    assert_eq!(
        rotation,
        Err(SyncError::Rejected {
            code: RejectedCode::Role
        })
    );
    let restart = t.owner.service.restart_team(t.team, Vec::new()).await;
    assert!(matches!(restart, Err(SyncError::NotAllowed { .. })), "{restart:?}");
}
