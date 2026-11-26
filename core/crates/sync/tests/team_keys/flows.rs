// A team's key life on the fake server: creation, a member's certificate copied in, confirmation, envelopes both ways,
// and the rotation a member's removal starts on the next roster read.

use std::sync::Arc;

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use serde_json::json;
use tablepro_keys::encoding::{AccountId, TeamId, Version, random_uuid};
use tablepro_keys::envelope::{EnvelopeId, ParentKind, SecretKind};
use tablepro_sync::SyncError;
use tablepro_sync::api::error::StateError;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::{
    ArrivalOrder, CaughtUp, KeyApplied, KeyArrival, MemberKeyStatus, Roster, StopFlows, TeamFlows,
};
use tablepro_sync::api::scopes::{Role, ScopesAnswer};
use tablepro_sync::api::state::{
    Checkpoint, KeyPendingRow, KeyTrust, Opened, PendingFlow, Row, RowKey, RowRange, ScopeRow, StateIdentity,
    StateStore, StateTxn, SyncTrust, Table,
};
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
    let (applied, read) = team_pass_read(device, team).await;
    read.unwrap();
    applied
}

// The same, with what the roster read answered.
async fn team_pass_read(device: &Device, team: TeamId) -> (KeyApplied, Result<(), SyncError>) {
    let proof = Proof::Dpop(device.proof().await);
    let ScopesAnswer::Body { body, .. } = device.transport.scopes(None, proof).await.unwrap() else {
        return (KeyApplied::default(), Ok(()));
    };
    let (last, caught_up) = pull_team(device, team).await;
    let read = read_roster_from(device, team, &body, caught_up).await;
    (last, read)
}

// The team's pages pulled until caught up, their key objects applied in order.
async fn pull_team(device: &Device, team: TeamId) -> (KeyApplied, Option<CaughtUp>) {
    let scope = ScopeName::Team(team);
    let proof = Proof::Dpop(device.proof().await);
    let mut row = match device.get(RowKey::Scope(scope)).await {
        Some(Row::Scope(row)) => row,
        _ => ScopeRow::new(scope),
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
            .apply_team_objects(KeyArrival {
                scope,
                records,
                order,
                in_force: (order == ArrivalOrder::InOrder).then_some(row.key_version).flatten(),
            })
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
    (last, caught_up)
}

// The roster as the engine reads it from `body` once the team's pull caught up: the scope row refreshed from the body,
// then the read.
async fn read_roster_from(
    device: &Device,
    team: TeamId,
    body: &tablepro_sync::api::scopes::ScopesBody,
    caught_up: Option<CaughtUp>,
) -> Result<(), SyncError> {
    let scope = ScopeName::Team(team);
    let Some(Row::Scope(mut row)) = device.get(RowKey::Scope(scope)).await else {
        panic!("no scope row");
    };
    let info = body.scopes.iter().find(|info| info.scope == scope).unwrap();
    row.role = info.role;
    row.horizon = Some(info.horizon);
    row.rotation_due = info.rotation_due;
    device.put(vec![Row::Scope(row)]).await;
    device.service.roster_read(team, Roster::of(info, caught_up)).await
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

// The same rows, opened as a stale file's open reports them.
struct OpenedAs {
    inner: Arc<dyn StateStore>,
    opened: Opened,
}

#[async_trait]
impl StateStore for OpenedAs {
    fn identity(&self) -> &StateIdentity {
        self.inner.identity()
    }

    fn opened(&self) -> &Opened {
        &self.opened
    }

    async fn begin(&self) -> Result<Box<dyn StateTxn>, StateError> {
        self.inner.begin().await
    }
}

// The device after a restart whose open found its state file as `opened` says, its rows as they were.
fn reopened(device: &Device, opened: Opened) -> Device {
    let mut again = device.restarted();
    again.state = Arc::new(OpenedAs {
        inner: Arc::clone(&device.state),
        opened,
    });
    again.restarted()
}

// The checkpoint an anchor holds of the device's key tables as they stand.
async fn checkpoint_of(device: &Device) -> Checkpoint {
    let mut txn = device.txn().await;
    let mut checkpoint = Checkpoint::default();
    for table in [Table::KeyPins, Table::KeyVersions, Table::KeyEnvelopes] {
        for row in txn.scan(&RowRange::Table(table)).await.unwrap() {
            match row {
                Row::KeyPin(pin) => checkpoint.pins.push(pin),
                Row::KeyVersion(version) => checkpoint.versions.push(version),
                Row::KeyEnvelope(envelope) => checkpoint.envelopes.push(envelope),
                _ => {}
            }
        }
    }
    checkpoint
}

// A stale file takes no wrap until the server showed every anchored pin and version (0054, A stale file): a rotation
// that reaches the member while it rebuilds is kept, and taken in the commit that ends the rebuild.
#[tokio::test]
async fn a_member_rebuilding_its_key_tables_takes_no_wrap_until_the_rebuild_ends() {
    let member_id = new_account();
    let t = created(&[(member_id, Role::Editor)]).await;
    let member = t.confirmed(member_id, "member-row").await;
    let checkpoint = checkpoint_of(&member).await;
    let member = reopened(
        &member,
        Opened {
            sync_tables: SyncTrust::Refill,
            key_tables: KeyTrust::Rebuild {
                checkpoint: Box::new(checkpoint),
            },
        },
    );
    team_pass(&t.owner, t.team).await;
    t.owner.service.rotate_team(t.team, Vec::new()).await.unwrap();

    team_pass(&member, t.team).await;
    let during = member.service.team_keys(t.team).await.unwrap().version;
    member.service.stop_actions().await.unwrap();

    assert_eq!(during, Some(v(1)));
    assert!(!member.service.is_rebuilding());
    let after = member.service.team_keys(t.team).await.unwrap();
    assert_eq!((after.version, after.holder), (Some(v(2)), true));
}

// A rotation the roster read makes while the team is due, which the server refuses, is not sent again on every read:
// the device backs off at that version, and a new session tries again.
#[tokio::test]
async fn a_refused_rotation_on_a_roster_read_backs_off_instead_of_going_up_on_every_read() {
    let editor_id = new_account();
    let t = created(&[(editor_id, Role::Editor)]).await;
    t.confirmed(editor_id, "editor-row").await;
    team_pass(&t.owner, t.team).await;
    t.server.set_rotation_due(t.team, true);
    t.owner.transport.refuse_next_push(RejectedCode::TeamFull);

    let (_, refused) = team_pass_read(&t.owner, t.team).await;
    let (_, again) = team_pass_read(&t.owner, t.team).await;
    let held = t.owner.service.team_keys(t.team).await.unwrap().version;
    let restarted = t.owner.restarted();
    team_pass(&restarted, t.team).await;

    assert_eq!(
        refused,
        Err(SyncError::Rejected {
            code: RejectedCode::TeamFull
        })
    );
    assert_eq!(again, Ok(()));
    assert_eq!(held, Some(v(1)));
    assert_eq!(restarted.service.team_keys(t.team).await.unwrap().version, Some(v(2)));
}

// A push conflict pulls the team again and reads its roster from the scopes body the pass started with, which still
// says the team is due though this device's rotation met the mark since: the team rotates once.
#[tokio::test]
async fn a_roster_read_again_from_the_pass_s_first_body_rotates_the_team_once() {
    let editor_id = new_account();
    let t = created(&[(editor_id, Role::Editor)]).await;
    t.confirmed(editor_id, "editor-row").await;
    team_pass(&t.owner, t.team).await;
    t.server.set_rotation_due(t.team, true);
    let proof = Proof::Dpop(t.owner.proof().await);
    let ScopesAnswer::Body { body, .. } = t.owner.transport.scopes(None, proof).await.unwrap() else {
        panic!("no scopes body");
    };
    team_pass(&t.owner, t.team).await;
    let rotated = t.owner.service.team_keys(t.team).await.unwrap().version;
    let (_, caught_up) = pull_team(&t.owner, t.team).await;

    read_roster_from(&t.owner, t.team, &body, caught_up).await.unwrap();

    assert_eq!(rotated, Some(v(2)));
    assert_eq!(t.owner.service.team_keys(t.team).await.unwrap().version, Some(v(2)));
    assert!(!t.owner.service.team_keys(t.team).await.unwrap().rotation_due);
}

// An account rotation's flow row that already wrote this team holds its rotation back no longer, though another team
// keeps the row open; one that has not written it yet does.
#[tokio::test]
async fn a_due_team_waits_only_for_an_account_rotation_that_has_not_rotated_it_yet() {
    let editor_id = new_account();
    let t = created(&[(editor_id, Role::Editor)]).await;
    t.confirmed(editor_id, "editor-row").await;
    team_pass(&t.owner, t.team).await;
    t.server.set_rotation_due(t.team, true);
    // Format 1 of the flow's state: no removals, then the teams done.
    let state = |done: &[TeamId]| {
        let mut state = vec![1, 0, 0, 0, 0];
        state.extend_from_slice(&u32::try_from(done.len()).unwrap().to_be_bytes());
        for team in done {
            state.extend_from_slice(team.0.as_bytes());
        }
        state
    };
    let flow = |done: &[TeamId]| {
        Row::KeyPending(KeyPendingRow {
            flow: PendingFlow::AccountRotation { av: v(2) },
            state: state(done),
        })
    };
    t.owner.put(vec![flow(&[])]).await;

    team_pass(&t.owner, t.team).await;
    let waited = t.owner.service.team_keys(t.team).await.unwrap().version;
    t.owner.put(vec![flow(&[t.team, new_team()])]).await;
    team_pass(&t.owner, t.team).await;

    assert_eq!(waited, Some(v(1)));
    assert_eq!(t.owner.service.team_keys(t.team).await.unwrap().version, Some(v(2)));
}
