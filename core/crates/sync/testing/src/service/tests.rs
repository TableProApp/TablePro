use std::sync::Arc;

use serde_json::{Value, json};
use tablepro_keys::encoding::{AccountId, TeamId, Version};
use tablepro_keys::keys::Ed25519Seed;
use tablepro_sync::api::ids::{ChangeTag, Cursor, DeviceRowId, IdempotencyKey, KindName, ScopeName};
use tablepro_sync::api::scopes::{Role, ScopesAnswer};
use tablepro_sync::api::transport::{
    Change, ChangeOp, ChangeOutcome, DeletedReason, DpopKey, Proof, PullRequest, PulledPage, PushBatch, RejectedCode,
    ServiceTransport, Transport, TransportError,
};
use uuid::Uuid;

use super::{FakeClient, FakeServer, Policies, ScopeOwner};

const ACCOUNT: &str = "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8";
const CONNECTION: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";

struct Device {
    client: FakeClient,
    key: DpopKey,
}

impl Device {
    fn proof(&self) -> Proof {
        Proof::Dpop(self.key.clone())
    }

    async fn push(&self, scope: ScopeName, changes: Vec<Change>) -> Result<Vec<ChangeOutcome>, TransportError> {
        let batch = self.batch(scope, changes);
        self.client.push(batch).await.map(|answer| answer.outcomes)
    }

    fn batch(&self, scope: ScopeName, changes: Vec<Change>) -> PushBatch {
        PushBatch {
            scope,
            epoch: Some(self.client.server().epoch()),
            idempotency_key: Some(IdempotencyKey(Uuid::new_v4().to_string())),
            changes,
            proof: self.proof(),
        }
    }

    async fn pull(&self, scope: ScopeName, cursor: Option<Cursor>) -> Result<PulledPage, TransportError> {
        let request = PullRequest {
            scope,
            cursor,
            limit: None,
            proof: self.proof(),
        };
        self.client.pull(request).await
    }

    async fn pull_all(&self, scope: ScopeName) -> (Vec<String>, Cursor) {
        let mut ids = Vec::new();
        let mut cursor = None;
        loop {
            let page = self.pull(scope, cursor.clone()).await.unwrap();
            ids.extend(page.records.iter().map(|record| record.record_id.clone()));
            cursor = page.cursor;
            if page.caught_up {
                return (ids, cursor.unwrap());
            }
        }
    }
}

fn account() -> AccountId {
    AccountId::from_wire(ACCOUNT).unwrap()
}

fn device(server: &Arc<FakeServer>, row: &str, approved: bool) -> Device {
    let seed = Ed25519Seed::generate().unwrap();
    let row = DeviceRowId(row.to_owned());
    if approved {
        server.approve(&row, seed.public().unwrap().0);
    }
    Device {
        client: server.client(account(), row),
        key: DpopKey(Arc::new(seed)),
    }
}

fn write(kind: &str, id: &str, base: Option<ChangeTag>, fields: Value) -> Change {
    Change {
        kind: KindName::parse(kind).unwrap(),
        record_id: id.to_owned(),
        base,
        op: ChangeOp::Write {
            patch: fields.clone(),
            fields,
        },
    }
}

fn delete(kind: &str, id: &str, base: Option<ChangeTag>) -> Change {
    Change {
        kind: KindName::parse(kind).unwrap(),
        record_id: id.to_owned(),
        base,
        op: ChangeOp::Delete,
    }
}

fn tag_of(outcome: &ChangeOutcome) -> ChangeTag {
    match outcome {
        ChangeOutcome::Applied { tag: Some(tag), .. } => tag.clone(),
        other => panic!("not applied: {other:?}"),
    }
}

fn rejected(outcome: &ChangeOutcome) -> RejectedCode {
    match outcome {
        ChangeOutcome::Rejected { code } => code.clone(),
        other => panic!("not rejected: {other:?}"),
    }
}

fn member(av: u32) -> String {
    format!("{ACCOUNT}/{av}")
}

// The personal and history key versions up to `upto`, each its own change set.
async fn key_versions(device: &Device, upto: u32) {
    for version in 1..=upto {
        for purpose in ["personal", "history"] {
            let id = format!("{ACCOUNT}/{purpose}/{version}");
            let outcomes = device
                .push(
                    ScopeName::Personal,
                    vec![write("key.version", &id, None, json!({"suite": "tp1"}))],
                )
                .await
                .unwrap();
            tag_of(&outcomes[0]);
        }
    }
}

#[tokio::test]
async fn a_write_applies_only_on_the_stored_tag_and_a_create_over_a_record_conflicts() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);

    let created = mac
        .push(
            ScopeName::Personal,
            vec![write("connection", CONNECTION, None, json!({"name": "a"}))],
        )
        .await;
    let tag = tag_of(&created.unwrap()[0]);
    let again = mac
        .push(
            ScopeName::Personal,
            vec![write("connection", CONNECTION, None, json!({"name": "b"}))],
        )
        .await;
    let edited = mac
        .push(
            ScopeName::Personal,
            vec![write("connection", CONNECTION, Some(tag.clone()), json!({"name": "c"}))],
        )
        .await;
    let stale = mac
        .push(
            ScopeName::Personal,
            vec![write("connection", CONNECTION, Some(tag), json!({"name": "d"}))],
        )
        .await;

    assert!(matches!(&again.unwrap()[0], ChangeOutcome::Conflict { stored: Some(stored) } if !stored.tombstone));
    assert!(matches!(&edited.unwrap()[0], ChangeOutcome::Applied { service: Some(stamp), .. } if stamp.version == 2));
    assert!(
        matches!(&stale.unwrap()[0], ChangeOutcome::Conflict { stored: Some(stored) }
        if stored.service.is_some_and(|stamp| stamp.version == 2) && stored.fields.is_none())
    );
    let stored = server
        .stored(ScopeOwner::Personal(account()), "connection", CONNECTION)
        .unwrap();
    assert_eq!(stored.fields, Some(json!({"name": "c"})));
}

#[tokio::test]
async fn a_delete_tombstones_and_a_patch_on_the_tombstone_s_tag_revives_it() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let created = mac
        .push(
            ScopeName::Personal,
            vec![write("connection", CONNECTION, None, json!({"name": "a"}))],
        )
        .await;

    let deleted = mac
        .push(
            ScopeName::Personal,
            vec![delete("connection", CONNECTION, Some(tag_of(&created.unwrap()[0])))],
        )
        .await;
    let tombstone_tag = tag_of(&deleted.unwrap()[0]);
    let deleted_again = mac
        .push(ScopeName::Personal, vec![delete("connection", CONNECTION, None)])
        .await;
    let absent = mac
        .push(ScopeName::Personal, vec![delete("group", CONNECTION, None)])
        .await;
    let revived = mac
        .push(
            ScopeName::Personal,
            vec![write(
                "connection",
                CONNECTION,
                Some(tombstone_tag),
                json!({"name": "b"}),
            )],
        )
        .await;

    assert!(matches!(
        &deleted_again.unwrap()[0],
        ChangeOutcome::Applied { tag: Some(_), .. }
    ));
    assert!(matches!(
        &absent.unwrap()[0],
        ChangeOutcome::Applied {
            tag: None,
            service: None
        }
    ));
    tag_of(&revived.unwrap()[0]);
    let stored = server
        .stored(ScopeOwner::Personal(account()), "connection", CONNECTION)
        .unwrap();
    assert_eq!((stored.deleted, stored.fields), (None, Some(json!({"name": "b"}))));
}

#[tokio::test]
async fn a_tag_from_before_a_restore_never_matches_even_at_the_same_version() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let backup = server.backup();
    let lost = mac
        .push(
            ScopeName::Personal,
            vec![write("connection", CONNECTION, None, json!({"name": "lost"}))],
        )
        .await;
    let lost_tag = tag_of(&lost.unwrap()[0]);

    server.restore(&backup);
    let other = mac
        .push(
            ScopeName::Personal,
            vec![write("connection", CONNECTION, None, json!({"name": "new"}))],
        )
        .await;
    let other_tag = tag_of(&other.unwrap()[0]);
    let stale = mac
        .push(
            ScopeName::Personal,
            vec![write("connection", CONNECTION, Some(lost_tag.clone()), json!({"x": 1}))],
        )
        .await;

    assert_ne!(lost_tag, other_tag);
    assert_eq!(
        server
            .stored(ScopeOwner::Personal(account()), "connection", CONNECTION)
            .unwrap()
            .version,
        1
    );
    assert!(matches!(&stale.unwrap()[0], ChangeOutcome::Conflict { .. }));
}

#[tokio::test]
async fn a_push_in_another_epoch_is_refused_whole_and_an_old_cursor_expires() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    mac.push(
        ScopeName::Personal,
        vec![write("tag", CONNECTION, None, json!({"name": "a"}))],
    )
    .await
    .unwrap();
    let (_, cursor) = mac.pull_all(ScopeName::Personal).await;
    let old = mac.batch(ScopeName::Personal, vec![write("group", CONNECTION, None, json!({}))]);

    server.new_epoch();

    assert_eq!(mac.client.push(old).await.unwrap_err(), TransportError::EpochChanged);
    assert_eq!(
        mac.pull(ScopeName::Personal, Some(cursor)).await.unwrap_err(),
        TransportError::CursorExpired
    );
    let garbled = Cursor::Service("not-a-cursor".to_owned());
    assert_eq!(
        mac.pull(ScopeName::Personal, Some(garbled)).await.unwrap_err(),
        TransportError::CursorExpired
    );
}

#[tokio::test]
async fn a_restore_lists_the_new_epoch_with_each_scope_s_kept_revision() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    mac.push(
        ScopeName::Personal,
        vec![write("tag", CONNECTION, None, json!({"name": "a"}))],
    )
    .await
    .unwrap();
    let kept = server.horizon(ScopeOwner::Personal(account()));
    let backup = server.backup();
    let first = server.epoch();
    mac.push(
        ScopeName::Personal,
        vec![write("group", CONNECTION, None, json!({"name": "b"}))],
    )
    .await
    .unwrap();
    let lost_epoch = server.new_epoch();

    let restored = server.restore(&backup);

    let lineage = server.lineage();
    let ids: Vec<_> = lineage.iter().map(|(id, _)| *id).collect();
    assert_eq!(ids, [first, restored]);
    assert!(!ids.contains(&lost_epoch));
    assert_eq!(lineage[1].1.get(&ScopeOwner::Personal(account())), Some(&kept));
    assert!(server.horizon(ScopeOwner::Personal(account())) < (1 << 40));
    let next = mac
        .push(ScopeName::Personal, vec![write("group", CONNECTION, None, json!({}))])
        .await
        .unwrap();
    assert!(matches!(&next[0], ChangeOutcome::Applied { service: Some(stamp), .. } if stamp.revision > 1 << 40));
}

#[tokio::test]
async fn a_key_kind_is_created_once_and_the_same_object_again_writes_nothing() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let object = json!({"suite": "tp1", "x": "1"});
    let first = mac
        .push(
            ScopeName::Personal,
            vec![write("key.account", &member(1), None, object.clone())],
        )
        .await;
    let revision = server.horizon(ScopeOwner::Personal(account()));

    let retry = mac
        .push(
            ScopeName::Personal,
            vec![write("key.account", &member(1), None, object)],
        )
        .await;
    let other = mac
        .push(
            ScopeName::Personal,
            vec![write("key.account", &member(1), None, json!({"suite": "tp1"}))],
        )
        .await;
    let patch = mac
        .push(
            ScopeName::Personal,
            vec![write(
                "key.account",
                &member(1),
                Some(tag_of(&first.unwrap()[0])),
                json!({}),
            )],
        )
        .await;
    let removed = mac
        .push(ScopeName::Personal, vec![delete("key.account", &member(1), None)])
        .await;

    tag_of(&retry.unwrap()[0]);
    assert_eq!(server.horizon(ScopeOwner::Personal(account())), revision);
    assert_eq!(rejected(&other.unwrap()[0]), RejectedCode::CreateOnly);
    assert_eq!(rejected(&patch.unwrap()[0]), RejectedCode::CreateOnly);
    assert_eq!(rejected(&removed.unwrap()[0]), RejectedCode::CreateOnly);
}

#[tokio::test]
async fn a_change_set_applies_whole_or_answers_change_set_for_the_rest() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let stranger = "019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63/1";
    let set = vec![
        write("key.account", &member(1), None, json!({"suite": "tp1"})),
        write("key.recovery", &member(1), None, json!({"suite": "tp1"})),
        write("key.account", stranger, None, json!({"suite": "tp1"})),
    ];

    let outcomes = mac.push(ScopeName::Personal, set).await.unwrap();

    assert_eq!(rejected(&outcomes[0]), RejectedCode::ChangeSet);
    assert_eq!(rejected(&outcomes[1]), RejectedCode::ChangeSet);
    assert_eq!(rejected(&outcomes[2]), RejectedCode::WriterBound);
    assert_eq!(server.horizon(ScopeOwner::Personal(account())), 0);
}

#[tokio::test]
async fn a_replay_answers_what_applied_and_another_body_under_the_key_is_refused() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let batch = mac.batch(
        ScopeName::Personal,
        vec![write("tag", CONNECTION, None, json!({"name": "a"}))],
    );

    let first = mac.client.push(batch.clone()).await.unwrap();
    let replay = mac.client.push(batch.clone()).await.unwrap();
    let mut other = batch;
    other.changes = vec![write("group", CONNECTION, None, json!({}))];

    assert_eq!(first, replay);
    assert_eq!(
        server
            .stored(ScopeOwner::Personal(account()), "tag", CONNECTION)
            .unwrap()
            .version,
        1
    );
    assert_eq!(
        mac.client.push(other).await.unwrap_err(),
        TransportError::IdempotencyMismatch
    );
}

#[tokio::test]
async fn a_push_that_names_a_record_twice_or_holds_too_many_changes_is_malformed() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let twice = vec![
        write("tag", CONNECTION, None, json!({})),
        write("tag", CONNECTION, None, json!({})),
    ];
    let many: Vec<Change> = (0..501)
        .map(|_| write("tag", &Uuid::new_v4().to_string().to_uppercase(), None, json!({})))
        .collect();

    assert_eq!(
        mac.push(ScopeName::Personal, twice).await.unwrap_err(),
        TransportError::ValidationFailed
    );
    assert_eq!(
        mac.push(ScopeName::Personal, many).await.unwrap_err(),
        TransportError::ValidationFailed
    );
    let mut unkeyed = mac.batch(ScopeName::Personal, vec![write("tag", CONNECTION, None, json!({}))]);
    unkeyed.idempotency_key = None;
    assert_eq!(
        mac.client.push(unkeyed).await.unwrap_err(),
        TransportError::ValidationFailed
    );
}

#[tokio::test]
async fn a_snapshot_then_the_changes_after_its_mark_then_an_empty_page_caught_up() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let ids: Vec<String> = (0..3).map(|_| Uuid::new_v4().to_string().to_uppercase()).collect();
    for id in &ids {
        mac.push(ScopeName::Personal, vec![write("tag", id, None, json!({}))])
            .await
            .unwrap();
    }

    let first = mac.pull(ScopeName::Personal, None).await.unwrap();
    let late = Uuid::new_v4().to_string().to_uppercase();
    mac.push(ScopeName::Personal, vec![write("tag", &late, None, json!({}))])
        .await
        .unwrap();
    let (rest, _) = mac.pull_all(ScopeName::Personal).await;
    let mut cursor = first.cursor.clone();
    let mut tail = Vec::new();
    loop {
        let page = mac.pull(ScopeName::Personal, cursor).await.unwrap();
        tail.extend(page.records.iter().map(|record| record.record_id.clone()));
        cursor = page.cursor;
        if page.caught_up {
            assert!(page.records.is_empty());
            break;
        }
    }

    assert!(!first.caught_up);
    assert_eq!(first.records.len(), 3);
    assert_eq!(tail, [late]);
    assert_eq!(rest.len(), 4);
}

#[tokio::test]
async fn a_scope_never_written_answers_an_empty_page_with_no_cursor() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);

    let page = mac.pull(ScopeName::Personal, None).await.unwrap();

    assert!(page.records.is_empty() && page.caught_up && page.cursor.is_none());
}

#[tokio::test]
async fn a_page_never_ends_inside_a_change_set() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    mac.push(ScopeName::Personal, vec![write("tag", CONNECTION, None, json!({}))])
        .await
        .unwrap();
    let (_, cursor) = mac.pull_all(ScopeName::Personal).await;
    let set: Vec<Change> = (1..=3)
        .map(|av| write("key.recovery", &member(av), None, json!({"suite": "tp1"})))
        .collect();
    mac.push(ScopeName::Personal, set).await.unwrap();

    let request = PullRequest {
        scope: ScopeName::Personal,
        cursor: Some(cursor),
        limit: Some(1),
        proof: mac.proof(),
    };
    let page = mac.client.pull(request).await.unwrap();

    assert_eq!(page.records.len(), 3);
}

#[tokio::test]
async fn the_history_scope_pages_newest_first_with_a_cursor_for_the_changes() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    key_versions(&mac, 1).await;
    let ids: Vec<String> = (0..3).map(|_| Uuid::new_v4().to_string().to_uppercase()).collect();
    for id in &ids {
        mac.push(
            ScopeName::History,
            vec![write("history_entry", id, None, json!({"kv": 1}))],
        )
        .await
        .unwrap();
    }
    let request = |cursor| PullRequest {
        scope: ScopeName::History,
        cursor,
        limit: Some(2),
        proof: mac.proof(),
    };

    let newest = mac.client.pull(request(None)).await.unwrap();
    let older = mac.client.pull(request(newest.cursor.clone())).await.unwrap();
    let changes = mac.client.pull(request(newest.changes_cursor.clone())).await.unwrap();

    let order: Vec<_> = newest
        .records
        .iter()
        .chain(&older.records)
        .map(|record| record.record_id.clone())
        .collect();
    assert_eq!(order, [ids[2].clone(), ids[1].clone(), ids[0].clone()]);
    assert!(changes.caught_up && changes.records.is_empty());
}

#[tokio::test]
async fn a_history_entry_is_created_once() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    key_versions(&mac, 1).await;
    let id = Uuid::new_v4().to_string().to_uppercase();
    let created = mac
        .push(
            ScopeName::History,
            vec![write("history_entry", &id, None, json!({"kv": 1}))],
        )
        .await;

    let patched = mac
        .push(
            ScopeName::History,
            vec![write(
                "history_entry",
                &id,
                Some(tag_of(&created.unwrap()[0])),
                json!({"kv": 1}),
            )],
        )
        .await;

    assert_eq!(rejected(&patched.unwrap()[0]), RejectedCode::CreateOnly);
}

#[tokio::test]
async fn before_approval_a_device_reads_and_writes_only_the_key_kinds_of_the_personal_scope() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    mac.push(ScopeName::Personal, vec![write("tag", CONNECTION, None, json!({}))])
        .await
        .unwrap();
    mac.push(
        ScopeName::Personal,
        vec![write("key.account", &member(1), None, json!({"suite": "tp1"}))],
    )
    .await
    .unwrap();
    let new = device(&server, "dev_new", false);

    let (seen, cursor) = new.pull_all(ScopeName::Personal).await;
    let data = new
        .push(ScopeName::Personal, vec![write("group", CONNECTION, None, json!({}))])
        .await;
    let history = new.pull(ScopeName::History, None).await;
    server.approve(&new.client.device_row, new.key.0.public().unwrap().0);

    assert_eq!(seen, [member(1)]);
    assert_eq!(data.unwrap_err(), TransportError::DeviceNotApproved);
    assert_eq!(history.unwrap_err(), TransportError::DeviceNotApproved);
    assert_eq!(
        new.pull(ScopeName::Personal, Some(cursor)).await.unwrap_err(),
        TransportError::CursorExpired
    );
}

#[tokio::test]
async fn a_reserved_kind_outside_its_scopes_and_a_value_the_rules_refuse_are_rejected() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);

    let outcomes = mac
        .push(
            ScopeName::Personal,
            vec![
                write("library_folder", CONNECTION, None, json!({})),
                write("tag", CONNECTION, None, json!({"password": "x"})),
            ],
        )
        .await
        .unwrap();
    let history = mac
        .push(ScopeName::History, vec![write("tag", CONNECTION, None, json!({}))])
        .await
        .unwrap();

    assert_eq!(rejected(&outcomes[0]), RejectedCode::KindNotInScope);
    assert_eq!(rejected(&outcomes[1]), RejectedCode::SecretKey);
    assert_eq!(rejected(&history[0]), RejectedCode::KindNotInScope);
}

#[tokio::test]
async fn a_switch_turned_off_tombstones_with_policy_and_refuses_the_kind() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    key_versions(&mac, 1).await;
    let id = format!("connection/{CONNECTION}/password");
    let sealed = json!({"suite": "tp1", "kv": 1, "nonce": "n", "ct": "c"});
    mac.push(
        ScopeName::Personal,
        vec![write("secret_envelope", &id, None, sealed.clone())],
    )
    .await
    .unwrap();

    server.set_policies(Policies {
        password_sync: false,
        ..Policies::default()
    });
    let refused = mac
        .push(ScopeName::Personal, vec![write("secret_envelope", &id, None, sealed)])
        .await
        .unwrap();
    let page = mac.pull(ScopeName::Personal, None).await.unwrap();
    let envelope = page.records.iter().find(|record| record.record_id == id).unwrap();

    assert_eq!(rejected(&refused[0]), RejectedCode::Policy);
    assert_eq!(envelope.deleted, Some(DeletedReason::Policy));
    assert_eq!(envelope.fields, None);
}

#[tokio::test]
async fn a_team_member_writes_only_its_key_member_and_reads_without_a_proof() {
    let server = FakeServer::new();
    let team = TeamId(Uuid::new_v4());
    server.add_team(team, &[(account(), Role::Member)]);
    let mac = device(&server, "dev_mac", true);

    let library = mac
        .push(
            ScopeName::Team(team),
            vec![write("library_folder", CONNECTION, None, json!({}))],
        )
        .await;
    let own = mac
        .push(
            ScopeName::Team(team),
            vec![write("key.member", &member(1), None, json!({"suite": "tp1"}))],
        )
        .await;
    let request = PullRequest {
        scope: ScopeName::Team(team),
        cursor: None,
        limit: None,
        proof: Proof::None,
    };
    let read = mac.client.pull(request).await.unwrap();

    assert_eq!(rejected(&library.unwrap()[0]), RejectedCode::Role);
    tag_of(&own.unwrap()[0]);
    assert_eq!(read.records.len(), 1);
}

#[tokio::test]
async fn the_scopes_body_answers_not_modified_until_a_role_changes() {
    let server = FakeServer::new();
    let team = TeamId(Uuid::new_v4());
    server.add_team(team, &[(account(), Role::Editor)]);
    let mac = device(&server, "dev_mac", true);
    let ScopesAnswer::Body { body, etag } = mac.client.scopes(None, mac.proof()).await.unwrap() else {
        panic!("no body");
    };

    let idle = mac.client.scopes(Some(etag.clone()), mac.proof()).await.unwrap();
    server.set_role(team, account(), Some(Role::Admin));
    let changed = mac.client.scopes(Some(etag), mac.proof()).await.unwrap();

    assert_eq!(body.scopes.len(), 3);
    assert_eq!(body.scopes[0].approved, Some(true));
    assert_eq!(idle, ScopesAnswer::NotModified);
    assert!(matches!(changed, ScopesAnswer::Body { body, .. } if body.scopes[2].role == Some(Role::Admin)));
}

#[tokio::test]
async fn a_stop_report_shows_to_admins_until_withdrawn_or_a_new_epoch() {
    let server = FakeServer::new();
    let team = TeamId(Uuid::new_v4());
    server.add_team(team, &[(account(), Role::Admin)]);
    let mac = device(&server, "dev_mac", true);
    let version = Version::new(4).unwrap();

    mac.client.report_stopped(team, version, mac.key.clone()).await.unwrap();
    let listed = server.stop_reports(team);
    mac.client.withdraw_stopped(team, mac.key.clone()).await.unwrap();
    let withdrawn = server.stop_reports(team);
    mac.client.report_stopped(team, version, mac.key.clone()).await.unwrap();
    server.new_epoch();

    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].version, version);
    assert!(withdrawn.is_empty());
    assert!(server.stop_reports(team).is_empty());
}

#[tokio::test]
async fn removing_a_row_needs_a_step_up_and_the_removed_device_is_told_on_every_call() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let lost = device(&server, "dev_lost", true);

    let without = mac
        .client
        .remove_device_row(lost.client.device_row.clone(), mac.key.clone())
        .await;
    server.set_step_up(&mac.client.device_row, true);
    mac.client
        .remove_device_row(lost.client.device_row.clone(), mac.key.clone())
        .await
        .unwrap();

    assert!(matches!(without, Err(TransportError::StepUpRequired(challenge)) if challenge.max_age_secs == 300));
    assert_eq!(
        lost.pull(ScopeName::Personal, None).await.unwrap_err(),
        TransportError::DeviceRemoved
    );
}

#[tokio::test]
async fn sign_out_s_revoke_clears_the_row_only_under_its_own_key() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let other = DpopKey(Arc::new(Ed25519Seed::generate().unwrap()));

    mac.client.revoke_key_device(other).await.unwrap();
    let kept = server.is_approved(&mac.client.device_row);
    mac.client.revoke_key_device(mac.key.clone()).await.unwrap();

    assert!(kept);
    assert!(!server.is_approved(&mac.client.device_row));
}

#[tokio::test]
async fn past_grace_only_key_objects_are_taken() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    server.set_lapsed(true);

    let data = mac
        .push(ScopeName::Personal, vec![write("tag", CONNECTION, None, json!({}))])
        .await;
    let keys = mac
        .push(
            ScopeName::Personal,
            vec![write("key.account", &member(1), None, json!({"suite": "tp1"}))],
        )
        .await;

    assert_eq!(data.unwrap_err(), TransportError::LicenseExpired);
    tag_of(&keys.unwrap()[0]);
}

#[tokio::test]
async fn an_envelope_is_taken_only_under_the_current_key_version() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    key_versions(&mac, 2).await;
    let id = format!("connection/{CONNECTION}/password");
    let sealed = |kv: u32| json!({"suite": "tp1", "kv": kv, "nonce": "n", "ct": "c"});

    let stale = mac
        .push(
            ScopeName::Personal,
            vec![write("secret_envelope", &id, None, sealed(1))],
        )
        .await
        .unwrap();
    let unknown = mac
        .push(
            ScopeName::Personal,
            vec![write("secret_envelope", &id, None, sealed(3))],
        )
        .await
        .unwrap();
    let current = mac
        .push(
            ScopeName::Personal,
            vec![write("secret_envelope", &id, None, sealed(2))],
        )
        .await
        .unwrap();

    assert_eq!(rejected(&stale[0]), RejectedCode::KeyVersionStale);
    assert_eq!(rejected(&unknown[0]), RejectedCode::KeyVersionUnknown);
    tag_of(&current[0]);
}

#[tokio::test]
async fn a_team_envelope_is_refused_while_the_team_is_due_a_rotation() {
    let server = FakeServer::new();
    let team = TeamId(Uuid::new_v4());
    server.add_team(team, &[(account(), Role::Owner)]);
    let mac = device(&server, "dev_mac", true);
    let version = format!("{}/team/1", tablepro_keys::encoding::uuid_to_wire(team.0));
    mac.push(
        ScopeName::Team(team),
        vec![write("key.version", &version, None, json!({"suite": "tp1"}))],
    )
    .await
    .unwrap();
    server.set_rotation_due(team, true);
    let id = format!("library_connection/{}/password", CONNECTION.to_lowercase());

    let held = mac
        .push(
            ScopeName::Team(team),
            vec![write("secret_envelope", &id, None, json!({"suite": "tp1", "kv": 1}))],
        )
        .await
        .unwrap();

    assert_eq!(rejected(&held[0]), RejectedCode::RotationDue);
}

#[tokio::test]
async fn a_team_library_id_that_matches_another_once_lower_cased_is_refused() {
    let server = FakeServer::new();
    let team = TeamId(Uuid::new_v4());
    server.add_team(team, &[(account(), Role::Editor)]);
    let mac = device(&server, "dev_mac", true);
    let lower = CONNECTION.to_lowercase();
    mac.push(
        ScopeName::Team(team),
        vec![write("library_folder", &lower, None, json!({"name": "a"}))],
    )
    .await
    .unwrap();

    let upper = mac
        .push(
            ScopeName::Team(team),
            vec![write("library_folder", CONNECTION, None, json!({"name": "b"}))],
        )
        .await;

    assert_eq!(rejected(&upper.unwrap()[0]), RejectedCode::IdCaseCollision);
}

#[tokio::test]
async fn a_replay_checks_the_role_again_and_answers_expire_after_a_day() {
    let server = FakeServer::new();
    let team = TeamId(Uuid::new_v4());
    server.add_team(team, &[(account(), Role::Editor)]);
    let mac = device(&server, "dev_mac", true);
    let batch = mac.batch(
        ScopeName::Team(team),
        vec![write("library_folder", CONNECTION, None, json!({"name": "a"}))],
    );
    mac.client.push(batch.clone()).await.unwrap();

    server.set_role(team, account(), Some(Role::Member));
    let demoted = mac.client.push(batch.clone()).await.unwrap();
    server.set_role(team, account(), Some(Role::Editor));
    server.advance_clock(86_400 * 1_000_000);
    let expired = mac.client.push(batch).await.unwrap();

    assert_eq!(rejected(&demoted.outcomes[0]), RejectedCode::Role);
    assert!(matches!(&expired.outcomes[0], ChangeOutcome::Conflict { .. }));
}

#[tokio::test]
async fn a_body_over_four_mebibytes_is_refused_whole() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let big = "x".repeat(900 * 1024);
    let changes: Vec<Change> = (0..5)
        .map(|_| {
            write(
                "tag",
                &Uuid::new_v4().to_string().to_uppercase(),
                None,
                json!({"name": big}),
            )
        })
        .collect();

    let refused = mac.push(ScopeName::Personal, changes).await;

    assert!(matches!(refused, Err(TransportError::Server { status: 413, .. })));
    assert_eq!(server.horizon(ScopeOwner::Personal(account())), 0);
}

#[tokio::test]
async fn before_approval_a_lone_device_certificate_is_refused() {
    let server = FakeServer::new();
    let new = device(&server, "dev_new", false);
    let certificate = format!("{ACCOUNT}/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/1");

    let lone = new
        .push(
            ScopeName::Personal,
            vec![write("key.device", &certificate, None, json!({"suite": "tp1"}))],
        )
        .await;
    let request = new
        .push(
            ScopeName::Personal,
            vec![write(
                "key.request",
                "5E2C8B14-7A3D-4F61-9B08-C4D2E6F1A357",
                None,
                json!({"suite": "tp1"}),
            )],
        )
        .await;

    assert_eq!(lone.unwrap_err(), TransportError::DeviceNotApproved);
    tag_of(&request.unwrap()[0]);
}

#[tokio::test]
async fn a_row_of_another_account_cannot_be_removed_and_a_removed_row_cannot_revoke() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    let stranger = server.client(AccountId(Uuid::from_u128(5)), DeviceRowId("dev_other".to_owned()));
    let lost = device(&server, "dev_lost", true);
    server.set_step_up(&mac.client.device_row, true);

    let other = mac
        .client
        .remove_device_row(stranger.device_row.clone(), mac.key.clone())
        .await;
    mac.client
        .remove_device_row(lost.client.device_row.clone(), mac.key.clone())
        .await
        .unwrap();

    assert_eq!(other.unwrap_err(), TransportError::NotFound);
    assert_eq!(
        lost.client.revoke_key_device(lost.key.clone()).await.unwrap_err(),
        TransportError::DeviceRemoved
    );
}

#[tokio::test]
async fn a_pulled_record_names_the_account_that_wrote_it() {
    let server = FakeServer::new();
    let mac = device(&server, "dev_mac", true);
    mac.push(
        ScopeName::Personal,
        vec![write("tag", CONNECTION, None, json!({"name": "a"}))],
    )
    .await
    .unwrap();

    let page = mac.pull(ScopeName::Personal, None).await.unwrap();
    let meta = page.records[0].service.clone().unwrap();

    assert_eq!(meta.updated_by.as_deref(), Some(ACCOUNT));
    assert_eq!(page.records[0].fields_json.as_deref(), Some(r#"{"name":"a"}"#));
}
