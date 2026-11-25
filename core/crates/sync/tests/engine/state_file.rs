use serde_json::json;
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, RequestId, TeamId, Version};
use tablepro_keys::keys::{Ed25519Public, X25519Public};
use tablepro_keys::sas::{Role as ComparisonRole, SessionState};
use tablepro_keys::trust::PinHow;
use tablepro_records::Kind;
use tablepro_sync::api::error::StateError;
use tablepro_sync::api::ids::{
    ChangeTag, Cursor, DeviceRowId, EpochId, IdempotencyKey, KindName, RecordKey, ScopeName,
};
use tablepro_sync::api::scopes::{LineageEpoch, Role, ScopePolicies};
use tablepro_sync::api::state::{
    ApprovalDecision, ApprovalRow, BaseRow, ConflictRow, DeferredRow, DeletedHistoryRow, HeldReason, HeldRow, Holder,
    KeyComparisonRow, KeyDevicePinRow, KeyEnvelopeRow, KeyObjectRow, KeyPendingRow, KeyPinRow, KeyVersionRow,
    KeyVersionState, LegacyMirrorRow, OutboxRow, PendingFlow, Row, RowKey, RowRange, ScopeRow, Standing, StandingRow,
    StateFiles, StoreRow, Table,
};
use tablepro_sync::api::transport::{DeletedReason, PulledRecord, ServiceMeta};
use tablepro_sync::state::SqliteStateFiles;
use uuid::Uuid;

use super::harness::{account, id, identity};

fn key(kind: Kind, record: &str) -> RecordKey {
    RecordKey::new(ScopeName::Personal, kind, record)
}

fn pulled() -> PulledRecord {
    PulledRecord {
        kind: KindName::of(Kind::Connection),
        record_id: id(1),
        tag: ChangeTag::Service("tag".to_owned()),
        fields: Some(json!({"name": "Prod", "nested": {"b": 1, "a": [1, 2]}})),
        fields_json: Some(r#"{"name":"Prod"}"#.to_owned()),
        deleted: None,
        service: Some(ServiceMeta {
            version: 3,
            revision: 7,
            epoch: EpochId(Uuid::new_v4()),
            updated_at_us: -5,
            taken_at_us: 1_767_225_600_000_000,
            held_until_us: None,
            expires_at_us: Some(9),
            updated_by: Some("someone".to_owned()),
            updated_device: Some(DeviceRowId("dev_mac".to_owned())),
            updated_by_name: None,
        }),
    }
}

fn sync_rows() -> Vec<Row> {
    let team = TeamId(Uuid::new_v4());
    vec![
        Row::Scope(ScopeRow {
            role: Some(Role::Editor),
            epoch: Some(EpochId(Uuid::new_v4())),
            cursor: Some(Cursor::Service("c1".to_owned())),
            key_version: Some(Version::new(4).unwrap()),
            horizon: Some(12),
            policies: ScopePolicies {
                personal_sync: None,
                password_sync: Some(false),
                history_sync: Some(true),
            },
            lineage: vec![LineageEpoch {
                id: EpochId(Uuid::new_v4()),
                kept_revision: 40,
            }],
            older_cursor: None,
            refill: true,
            rotation_due: false,
            caught_up: true,
            ..ScopeRow::new(ScopeName::Team(team))
        }),
        Row::Store(StoreRow {
            store: "connections".to_owned(),
            generation: Uuid::new_v4(),
            sequence: 9,
        }),
        Row::Base(BaseRow {
            key: key(Kind::Connection, &id(1)),
            tag: ChangeTag::CloudKit(vec![0, 1, 255]),
            version: None,
            revision: Some(0),
            epoch: None,
            deleted: Some(DeletedReason::Policy),
            fields: None,
        }),
        Row::Standing(StandingRow {
            key: key(Kind::Connection, &id(2)),
            standing: Standing::LocalOnly,
        }),
        Row::Held(HeldRow {
            key: key(Kind::Connection, &id(3)),
            reason: HeldReason::UnknownKind,
            record: pulled(),
        }),
        Row::Deferred(DeferredRow {
            key: key(Kind::Connection, &id(4)),
            record: PulledRecord {
                fields: None,
                fields_json: None,
                deleted: Some(DeletedReason::User),
                service: None,
                ..pulled()
            },
        }),
        Row::Outbox(OutboxRow {
            scope: ScopeName::History,
            idempotency_key: IdempotencyKey("k".to_owned()),
            request_digest: [7; 32],
            created_at_ms: 1,
        }),
        Row::Approval(ApprovalRow {
            key: key(Kind::Connection, &id(5)),
            field: "host".to_owned(),
            pulled: json!("db"),
            decision: ApprovalDecision::Rejected { local: json!("local") },
        }),
        Row::Conflict(ConflictRow {
            key: key(Kind::Connection, &id(6)),
            base: Some(json!({"name": "a"})),
            mine: None,
            theirs: Some(json!({"name": "b"})),
        }),
        Row::LegacyMirror(LegacyMirrorRow {
            item: "token".to_owned(),
            value: vec![1, 2, 3],
        }),
    ]
}

fn key_rows() -> Vec<Row> {
    let ik = Ed25519Public([3; 32]);
    vec![
        Row::KeyObject(KeyObjectRow {
            scope: ScopeName::Personal,
            kind: KindName::of(Kind::KeyAccount),
            record_id: format!("{}/1", account().to_wire()),
            fields: r#"{"a":1}"#.to_owned(),
            applied: true,
        }),
        Row::KeyPin(KeyPinRow {
            account: account(),
            ik,
            av: Version::new(2).unwrap(),
            how: PinHow::Compared,
            alert: true,
            replaced: vec![Ed25519Public([1; 32]), Ed25519Public([2; 32])],
        }),
        Row::KeyDevicePin(KeyDevicePinRow {
            key_device: KeyDeviceId(Uuid::new_v4()),
            dek: X25519Public([4; 32]),
            dsk: Ed25519Public([5; 32]),
        }),
        Row::KeyVersion(KeyVersionRow {
            scope: ScopeName::Personal,
            purpose: KeyPurpose::History,
            version: Version::new(3).unwrap(),
            record: [6; 32],
            holders: vec![Holder { account: account(), ik }],
            state: KeyVersionState::Ended,
            epoch: Some(EpochId(Uuid::new_v4())),
        }),
        Row::KeyEnvelope(KeyEnvelopeRow {
            scope: ScopeName::Personal,
            record_id: format!("connection/{}/password", id(1)),
            kv: Version::new(2).unwrap(),
        }),
        Row::KeyComparison(KeyComparisonRow {
            session: RequestId(Uuid::new_v4()),
            role: ComparisonRole::Approver,
            peer: vec![1],
            view: Vec::new(),
            state: SessionState::Revealed,
            expires_at_us: 10,
        }),
        Row::KeyPending(KeyPendingRow {
            flow: PendingFlow::StopWithdrawal {
                team: TeamId(Uuid::new_v4()),
            },
            state: vec![9],
        }),
        Row::KeyPending(KeyPendingRow {
            flow: PendingFlow::AccountRotation {
                av: Version::new(5).unwrap(),
            },
            state: Vec::new(),
        }),
        Row::DeletedHistory(DeletedHistoryRow { record_id: id(9) }),
    ]
}

#[tokio::test]
async fn every_row_reads_back_as_it_was_written() {
    let dir = tempfile::tempdir().unwrap();
    let files = SqliteStateFiles::at(dir.path().to_path_buf());
    let state = files.open(identity("dev_mac")).await.unwrap();
    let rows: Vec<Row> = sync_rows().into_iter().chain(key_rows()).collect();

    let mut txn = state.begin().await.unwrap();
    for row in &rows {
        txn.put(row.clone()).await.unwrap();
    }
    txn.commit().await.unwrap();
    drop(state);
    let state = files.open(identity("dev_mac")).await.unwrap();

    let mut txn = state.begin().await.unwrap();
    for row in rows {
        assert_eq!(txn.get(&row.key()).await.unwrap(), Some(row.clone()), "{:?}", row.key());
    }
}

#[tokio::test]
async fn a_scan_reads_its_range_in_key_order() {
    let dir = tempfile::tempdir().unwrap();
    let state = SqliteStateFiles::at(dir.path().to_path_buf())
        .open(identity("dev_mac"))
        .await
        .unwrap();
    let base = |scope, kind: Kind, record: &str| {
        Row::Base(BaseRow {
            key: RecordKey::new(scope, kind, record),
            tag: ChangeTag::Service(record.to_owned()),
            version: Some(1),
            revision: Some(1),
            epoch: None,
            deleted: None,
            fields: Some(json!({})),
        })
    };
    let mut txn = state.begin().await.unwrap();
    for row in [
        base(ScopeName::Personal, Kind::SavedQueryFolder, "B"),
        base(ScopeName::Personal, Kind::SavedQuery, "Z"),
        base(ScopeName::Personal, Kind::SavedQuery, "A"),
        base(ScopeName::History, Kind::HistoryEntry, "H"),
    ] {
        txn.put(row).await.unwrap();
    }
    txn.commit().await.unwrap();

    let mut txn = state.begin().await.unwrap();
    let kind = txn
        .scan(&RowRange::ScopeKind(
            Table::Bases,
            ScopeName::Personal,
            KindName::of(Kind::SavedQuery),
        ))
        .await
        .unwrap();
    let scope = txn
        .scan(&RowRange::Scope(Table::Bases, ScopeName::Personal))
        .await
        .unwrap();
    let all = txn.scan(&RowRange::Table(Table::Bases)).await.unwrap();

    let ids = |rows: &[Row]| -> Vec<RowKey> { rows.iter().map(Row::key).collect() };
    assert_eq!(ids(&kind).len(), 2);
    assert!(matches!(&kind[0], Row::Base(base) if base.key.record_id == "A"));
    assert_eq!(ids(&scope).len(), 3);
    assert_eq!(all.len(), 4);
    let encoded: Vec<Vec<u8>> = all.iter().map(|row| row.key().encoded()).collect();
    let mut sorted = encoded.clone();
    sorted.sort();
    assert_eq!(encoded, sorted);
}

#[tokio::test]
async fn a_commit_raises_the_counter_and_an_unfinished_one_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let state = SqliteStateFiles::at(dir.path().to_path_buf())
        .open(identity("dev_mac"))
        .await
        .unwrap();
    let row = sync_rows().remove(1);

    let mut txn = state.begin().await.unwrap();
    txn.put(row.clone()).await.unwrap();
    drop(txn);
    let first = state.begin().await.unwrap().commit().await.unwrap();
    let mut txn = state.begin().await.unwrap();
    let absent = txn.get(&row.key()).await.unwrap();
    txn.put(row.clone()).await.unwrap();
    let second = txn.commit().await.unwrap();

    assert_eq!(absent, None);
    assert_eq!(second.counter, first.counter + 1);
    assert_eq!(state.begin().await.unwrap().get(&row.key()).await.unwrap(), Some(row));
}

#[tokio::test]
async fn a_file_made_for_another_device_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let files = SqliteStateFiles::at(dir.path().to_path_buf());
    drop(files.open(identity("dev_mac")).await.unwrap());
    // The same sign-in and account name the same file; the device row bound into it differs.
    let other = identity("dev_other");
    assert_eq!(files.path(&other), files.path(&identity("dev_mac")));

    let refused = files.open(other).await.err();

    assert_eq!(refused, Some(StateError::WrongIdentity));
}

#[tokio::test]
async fn one_process_holds_a_state_file_until_it_lets_go() {
    let dir = tempfile::tempdir().unwrap();
    let files = SqliteStateFiles::at(dir.path().to_path_buf());
    let held = files.open(identity("dev_mac")).await.unwrap();

    let second = files.open(identity("dev_mac")).await.err();
    let delete = files.delete(identity("dev_mac")).await.err();
    drop(held);
    let again = files.open(identity("dev_mac")).await;

    assert_eq!(second, Some(StateError::Busy));
    assert_eq!(delete, Some(StateError::Busy));
    assert!(again.is_ok());
}

#[tokio::test]
async fn a_deleted_file_starts_again_empty() {
    let dir = tempfile::tempdir().unwrap();
    let files = SqliteStateFiles::at(dir.path().to_path_buf());
    let state = files.open(identity("dev_mac")).await.unwrap();
    let row = sync_rows().remove(1);
    let mut txn = state.begin().await.unwrap();
    txn.put(row.clone()).await.unwrap();
    txn.commit().await.unwrap();
    drop(state);

    files.delete(identity("dev_mac")).await.unwrap();
    let gone = !files.path(&identity("dev_mac")).exists();
    let state = files.open(identity("dev_mac")).await.unwrap();

    assert!(gone);
    assert_eq!(state.begin().await.unwrap().get(&row.key()).await.unwrap(), None);
}

#[tokio::test]
async fn clearing_the_key_tables_keeps_the_sync_tables() {
    let dir = tempfile::tempdir().unwrap();
    let state = SqliteStateFiles::at(dir.path().to_path_buf())
        .open(identity("dev_mac"))
        .await
        .unwrap();
    let kept = sync_rows();
    let mut txn = state.begin().await.unwrap();
    for row in kept.iter().cloned().chain(key_rows()) {
        txn.put(row).await.unwrap();
    }
    txn.commit().await.unwrap();

    let mut txn = state.begin().await.unwrap();
    txn.clear_key_tables().await.unwrap();
    txn.commit().await.unwrap();

    let mut txn = state.begin().await.unwrap();
    for table in Table::KEY {
        assert!(txn.scan(&RowRange::Table(table)).await.unwrap().is_empty(), "{table:?}");
    }
    for row in kept {
        assert_eq!(txn.get(&row.key()).await.unwrap(), Some(row));
    }
}

#[cfg(unix)]
#[tokio::test]
async fn the_file_is_private_and_in_wal_mode() {
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::tempdir().unwrap();
    let files = SqliteStateFiles::at(dir.path().to_path_buf());
    let state = files.open(identity("dev_mac")).await.unwrap();
    let mut txn = state.begin().await.unwrap();
    txn.put(sync_rows().remove(1)).await.unwrap();
    txn.commit().await.unwrap();
    let path = files.path(&identity("dev_mac"));

    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    let folder = std::fs::metadata(path.parent().unwrap()).unwrap().permissions().mode() & 0o777;
    let mut wal = path.clone().into_os_string();
    wal.push("-wal");

    assert_eq!(mode, 0o600);
    assert_eq!(folder, 0o700);
    assert!(std::path::Path::new(&wal).exists());
    assert!(path.starts_with(dir.path().join("service")));
    let name = path.file_stem().unwrap().to_str().unwrap();
    assert!(name.len() == 64 && name.bytes().all(|byte| byte.is_ascii_hexdigit()));
}
