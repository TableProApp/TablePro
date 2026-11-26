// What an open finds against the anchor (0054, On open): a fresh file, the restore cases, a file or an anchor alone,
// a crash at each step of a commit, and what stays owed until a key flow settles it.

use std::sync::Arc;

use tablepro_keys::encoding::{KeyPurpose, TeamId, Version};
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::trust::PinHow;
use tablepro_records::Kind;
use tablepro_sync::api::device_store::{DeviceItem, HostDeviceStore};
use tablepro_sync::api::error::StateError;
use tablepro_sync::api::ids::{ChangeTag, Cursor, IdempotencyKey, KindName, RecordKey, ScopeName};
use tablepro_sync::api::state::{
    ApprovalDecision, ApprovalRow, BaseRow, Checkpoint, DeletedHistoryRow, Holder, KeyEnvelopeRow, KeyObjectRow,
    KeyPinRow, KeyTrust, KeyVersionRow, KeyVersionState, KeysSettled, Opened, OutboxRow, Row, RowKey, ScopeRow,
    StateFiles, StateStore, StoppedCause, StoreRow, SyncTrust, Table,
};
use tablepro_sync::state::SqliteStateFiles;
use tablepro_sync_testing::FakeDeviceStore;
use uuid::Uuid;

use super::support::{Disk, account, get, icloud, identity, is_checkpoint, is_root, put, table};

fn v(value: u32) -> Version {
    Version::new(value).unwrap()
}

fn team() -> ScopeName {
    ScopeName::Team(TeamId(Uuid::from_u128(0x7e)))
}

fn pin(av: u32, alert: bool, replaced: Vec<Ed25519Public>) -> KeyPinRow {
    KeyPinRow {
        account: account(),
        ik: Ed25519Public([u8::try_from(av).unwrap(); 32]),
        av: v(av),
        how: PinHow::Compared,
        alert,
        replaced,
    }
}

fn team_version(version: u32, state: KeyVersionState, cause: Option<StoppedCause>) -> KeyVersionRow {
    KeyVersionRow {
        scope: team(),
        purpose: KeyPurpose::Team,
        version: v(version),
        record: [u8::try_from(version).unwrap(); 32],
        holders: vec![Holder {
            account: account(),
            ik: Ed25519Public([1; 32]),
        }],
        state,
        stopped_cause: cause,
        epoch: None,
    }
}

fn envelope(kv: u32) -> KeyEnvelopeRow {
    KeyEnvelopeRow {
        scope: ScopeName::Personal,
        record_id: "connection/A/password".to_owned(),
        kv: v(kv),
    }
}

fn object(record: &str) -> Row {
    Row::KeyObject(KeyObjectRow {
        scope: ScopeName::Personal,
        kind: KindName::of(Kind::KeyAccount),
        record_id: record.to_owned(),
        fields: "{}".to_owned(),
        applied: true,
    })
}

fn store_row() -> Row {
    Row::Store(StoreRow {
        store: "connections".to_owned(),
        generation: Uuid::from_u128(9),
        sequence: 4,
    })
}

fn keys_at(av: u32, version: KeyVersionRow, kv: u32) -> Vec<Row> {
    vec![
        Row::KeyPin(pin(
            av,
            av > 1,
            (1..av).map(|n| Ed25519Public([u8::try_from(n).unwrap(); 32])).collect(),
        )),
        Row::KeyVersion(version),
        Row::KeyEnvelope(envelope(kv)),
        object(&format!("A/{av}")),
        Row::DeletedHistory(DeletedHistoryRow {
            record_id: format!("H{av}"),
        }),
    ]
}

fn rebuilt_from(opened: &Opened) -> Option<Checkpoint> {
    match &opened.key_tables {
        KeyTrust::Rebuild { checkpoint } => Some((**checkpoint).clone()),
        KeyTrust::Trusted | KeyTrust::Unanchored => None,
    }
}

fn checkpoint_of(opened: &Opened) -> Checkpoint {
    rebuilt_from(opened).unwrap()
}

fn rebuild(opened: &Opened) -> bool {
    matches!(opened.key_tables, KeyTrust::Rebuild { .. })
}

// A file at av 1 copied, then moved on to av 2 with a held restart, which a restore of the copy must not undo.
async fn moved_on(disk: &Disk) -> Vec<u8> {
    let state = disk.open().await;
    let mut first = keys_at(1, team_version(1, KeyVersionState::Ok, None), 1);
    first.push(store_row());
    put(&state, first).await;
    drop(state);
    let copy = disk.copy(&identity()).await;
    let state = disk.open().await;
    let mut txn = state.begin().await.unwrap();
    txn.clear_key_tables().await.unwrap();
    txn.commit().await.unwrap();
    put(
        &state,
        keys_at(
            2,
            team_version(2, KeyVersionState::Stopped, Some(StoppedCause::RestartHeld)),
            2,
        ),
    )
    .await;
    drop(state);
    copy
}

#[tokio::test]
async fn a_new_file_anchors_itself_and_opens_fresh_again() {
    let disk = Disk::new();
    let state = disk.open().await;
    let opened = state.opened().clone();
    put(&state, vec![store_row()]).await;
    drop(state);

    let again = disk.open().await;

    assert_eq!(opened, Opened::FRESH);
    assert_eq!(again.opened(), &Opened::FRESH);
    assert_eq!(disk.store.count(is_root), 1);
    assert_eq!(disk.store.count(is_checkpoint), 1);
    assert_eq!(
        get(&again, RowKey::Store("connections".to_owned())).await,
        Some(store_row())
    );
}

// 0054, Verification: an older copy with a valid MAC and its anchor intact opens stale; its sync tables refill and its
// key tables rebuild from the anchored checkpoint, with every stop cause as the anchor holds it.
#[tokio::test]
async fn an_older_copy_with_its_anchor_intact_opens_stale_on_the_anchored_checkpoint() {
    let disk = Disk::new();
    let copy = moved_on(&disk).await;

    disk.restore(&identity(), &copy).await;
    let state = disk.open().await;

    let opened = state.opened().clone();
    assert_eq!(opened.sync_tables, SyncTrust::Refill);
    let checkpoint = checkpoint_of(&opened);
    assert_eq!(checkpoint.pins, vec![pin(2, true, vec![Ed25519Public([1; 32])])]);
    assert_eq!(
        checkpoint.versions,
        vec![team_version(
            2,
            KeyVersionState::Stopped,
            Some(StoppedCause::RestartHeld)
        )]
    );
    assert_eq!(checkpoint.envelopes, vec![envelope(2)]);
    assert_eq!(
        get(&state, RowKey::KeyVersion(team(), KeyPurpose::Team)).await,
        Some(Row::KeyVersion(team_version(
            2,
            KeyVersionState::Stopped,
            Some(StoppedCause::RestartHeld)
        )))
    );
    assert_eq!(
        table(&state, Table::KeyPins).await,
        vec![Row::KeyPin(pin(2, true, vec![Ed25519Public([1; 32])]))]
    );
    assert_eq!(
        table(&state, Table::KeyEnvelopes).await,
        vec![Row::KeyEnvelope(envelope(2))]
    );
    // What stays in the file alone goes with the stale copy.
    assert!(table(&state, Table::KeyObjects).await.is_empty());
    assert!(table(&state, Table::DeletedHistory).await.is_empty());
    assert!(table(&state, Table::Stores).await.is_empty());
}

// A restored file must not flip a stop's cause (0062, 0064): the anchor's row wins over the copy's.
#[tokio::test]
async fn a_restored_copy_cannot_turn_a_held_restart_back_into_a_restore_wait() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(
        &state,
        vec![Row::KeyVersion(team_version(
            2,
            KeyVersionState::Stopped,
            Some(StoppedCause::RestoreWait),
        ))],
    )
    .await;
    drop(state);
    let copy = disk.copy(&identity()).await;
    let state = disk.open().await;
    put(
        &state,
        vec![Row::KeyVersion(team_version(
            2,
            KeyVersionState::Stopped,
            Some(StoppedCause::RestartHeld),
        ))],
    )
    .await;
    drop(state);

    disk.restore(&identity(), &copy).await;
    let state = disk.open().await;

    let Some(Row::KeyVersion(row)) = get(&state, RowKey::KeyVersion(team(), KeyPurpose::Team)).await else {
        panic!("no team row");
    };
    assert_eq!(row.stopped_cause, Some(StoppedCause::RestartHeld));
    assert!(rebuild(state.opened()));
}

// A cause written over in the file, as a local writer could, fails the MAC: only the store's own commits move it.
#[tokio::test]
async fn a_cause_edited_in_the_file_fails_the_mac() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(
        &state,
        vec![Row::KeyVersion(team_version(
            2,
            KeyVersionState::Stopped,
            Some(StoppedCause::CatchUp),
        ))],
    )
    .await;
    drop(state);
    let other = Disk::new();
    let state = other.open().await;
    put(
        &state,
        vec![Row::KeyVersion(team_version(
            2,
            KeyVersionState::Stopped,
            Some(StoppedCause::RestoreWait),
        ))],
    )
    .await;
    drop(state);
    let key = RowKey::KeyVersion(team(), KeyPurpose::Team);
    let waiting = other.raw(&identity(), Table::KeyVersions, &key).await;

    disk.tamper(
        &identity(),
        "UPDATE key_versions SET columns = ? WHERE key = ?",
        vec![waiting, key.encoded()],
    )
    .await;

    assert_eq!(disk.files.open(identity()).await.err(), Some(StateError::Integrity));
}

// 0054, Verification: a key table row copied from another copy of the file fails the MAC, and so does a base,
// approval, cursor or outbox row swapped in while the binding, counter and key tables stay current.
#[tokio::test]
async fn a_row_from_another_copy_of_the_file_fails_the_mac() {
    let swaps: Vec<(Table, RowKey, Row, Row)> = {
        let key = RecordKey::new(ScopeName::Personal, Kind::Connection, "A");
        let base = |tag: &str| {
            Row::Base(BaseRow {
                key: key.clone(),
                tag: ChangeTag::Service(tag.to_owned()),
                version: Some(1),
                revision: Some(1),
                epoch: None,
                deleted: None,
                fields: None,
                created_ms: None,
            })
        };
        let approval = |decision| {
            Row::Approval(ApprovalRow {
                key: key.clone(),
                field: "host".to_owned(),
                pulled: serde_json::json!("db"),
                decision,
            })
        };
        let scope = |cursor: &str| {
            Row::Scope(ScopeRow {
                cursor: Some(Cursor::Service(cursor.to_owned())),
                ..ScopeRow::new(ScopeName::Personal)
            })
        };
        let outbox = |key: &str| {
            Row::Outbox(OutboxRow {
                scope: ScopeName::Personal,
                idempotency_key: IdempotencyKey(key.to_owned()),
                request_digest: [1; 32],
                created_at_ms: 1,
            })
        };
        let version = |n| Row::KeyVersion(team_version(n, KeyVersionState::Ok, None));
        vec![
            (Table::Bases, RowKey::Base(key.clone()), base("old"), base("new")),
            (
                Table::Approvals,
                RowKey::Approval(key.clone(), "host".to_owned()),
                approval(ApprovalDecision::Approved),
                approval(ApprovalDecision::Waiting),
            ),
            (
                Table::Scopes,
                RowKey::Scope(ScopeName::Personal),
                scope("c1"),
                scope("c2"),
            ),
            (
                Table::Outbox,
                RowKey::Outbox(ScopeName::Personal),
                outbox("k1"),
                outbox("k2"),
            ),
            (
                Table::KeyVersions,
                RowKey::KeyVersion(team(), KeyPurpose::Team),
                version(1),
                version(2),
            ),
        ]
    };
    for (table, key, old, new) in swaps {
        let disk = Disk::new();
        let state = disk.open().await;
        put(&state, vec![old]).await;
        drop(state);
        let old_columns = disk.raw(&identity(), table, &key).await;
        let state = disk.open().await;
        put(&state, vec![new]).await;
        drop(state);

        disk.tamper(
            &identity(),
            &format!("UPDATE {} SET columns = ? WHERE key = ?", table.name()),
            vec![old_columns, key.encoded()],
        )
        .await;

        assert_eq!(
            disk.files.open(identity()).await.err(),
            Some(StateError::Integrity),
            "{table:?}"
        );
    }
}

// The anchor older than the file, as after a keyring restore on Linux: anything that is not the current or pending
// entry is stale, and the rebuild starts from what the anchor holds.
#[tokio::test]
async fn a_file_newer_than_its_anchor_opens_stale_on_the_anchor_s_checkpoint() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, keys_at(1, team_version(1, KeyVersionState::Ok, None), 1)).await;
    drop(state);
    let anchor = disk.store.items();
    let state = disk.open().await;
    put(&state, vec![Row::KeyEnvelope(envelope(3))]).await;
    drop(state);

    disk.store.set_items(anchor);
    let state = disk.open().await;

    let opened = state.opened().clone();
    assert_eq!(opened.sync_tables, SyncTrust::Refill);
    assert_eq!(checkpoint_of(&opened).envelopes, vec![envelope(1)]);
}

// A file restored to a device that never held its anchor, as on a new device or after the passcode went: it handles no
// secret until it is approved again, and its sync tables refill.
#[tokio::test]
async fn a_file_restored_without_its_anchor_opens_unanchored() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(
        &state,
        [
            keys_at(1, team_version(1, KeyVersionState::Ok, None), 1),
            vec![store_row()],
        ]
        .concat(),
    )
    .await;
    drop(state);
    let copy = disk.copy(&identity()).await;
    let elsewhere = Disk::new();
    std::fs::create_dir_all(elsewhere.path(&identity()).parent().unwrap()).unwrap();
    std::fs::write(elsewhere.path(&identity()), &copy).unwrap();
    disk.store.remove_passcode();

    let moved = elsewhere.open().await;
    let passcode_off = disk.open().await;

    for state in [&moved, &passcode_off] {
        assert_eq!(
            state.opened(),
            &Opened {
                sync_tables: SyncTrust::Refill,
                key_tables: KeyTrust::Unanchored,
            }
        );
        assert!(table(state, Table::Stores).await.is_empty());
    }
}

async fn settle(state: &Arc<dyn StateStore>, settled: KeysSettled) -> Result<u64, StateError> {
    let mut txn = state.begin().await.unwrap();
    txn.settle_keys(settled);
    txn.put(store_row()).await.unwrap();
    txn.commit().await.map(|committed| committed.counter)
}

// What an open found stays owed until a commit settles it: a restart forgets neither an unanchored file nor a rebuild,
// a settle whose commit did not land settles nothing, and only the settle the finding calls for ends it.
#[tokio::test]
async fn an_unanchored_file_stays_unanchored_across_restarts_until_a_commit_reapproves_it() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![store_row()]).await;
    drop(state);
    disk.store.remove_passcode();
    let state = disk.open().await;
    put(&state, vec![store_row()]).await;
    drop(state);

    let restarted = disk.open().await;
    let still = restarted.opened().clone();
    settle(&restarted, KeysSettled::Rebuilt).await.unwrap();
    drop(restarted);
    let wrong_settle = disk.open().await.opened().clone();
    let state = disk.open().await;
    disk.store.set_locked(true);
    let refused = settle(&state, KeysSettled::Reapproved).await.err();
    disk.store.set_locked(false);
    let mut dropped = state.begin().await.unwrap();
    dropped.settle_keys(KeysSettled::Reapproved);
    drop(dropped);
    put(&state, vec![store_row()]).await;
    drop(state);
    let unlanded = disk.open().await.opened().clone();
    let state = disk.open().await;
    settle(&state, KeysSettled::Reapproved).await.unwrap();
    drop(state);
    let approved = disk.open().await;

    assert_eq!(still.key_tables, KeyTrust::Unanchored);
    assert_eq!(still.sync_tables, SyncTrust::Trusted);
    assert_eq!(wrong_settle.key_tables, KeyTrust::Unanchored);
    assert_eq!(refused, Some(StateError::AnchorUnsettled));
    assert_eq!(unlanded.key_tables, KeyTrust::Unanchored);
    assert_eq!(approved.opened(), &Opened::FRESH);
}

#[tokio::test]
async fn a_rebuild_stays_owed_across_restarts_until_its_commit_lands() {
    let disk = Disk::new();
    let copy = moved_on(&disk).await;
    disk.restore(&identity(), &copy).await;
    let state = disk.open().await;
    let floor = checkpoint_of(state.opened());
    put(&state, vec![object("A/2")]).await;
    drop(state);

    let restarted = disk.open().await;
    let still = restarted.opened().clone();
    let kept = table(&restarted, Table::KeyObjects).await;
    settle(&restarted, KeysSettled::Rebuilt).await.unwrap();
    let unchanged = restarted.opened().clone();
    drop(restarted);
    let rebuilt = disk.open().await;

    assert_eq!(still.sync_tables, SyncTrust::Trusted);
    assert_eq!(checkpoint_of(&still), floor);
    assert_eq!(kept, vec![object("A/2")]);
    assert!(rebuild(&unchanged));
    assert_eq!(rebuilt.opened(), &Opened::FRESH);
    assert_eq!(disk.store.count(is_checkpoint), 1);
}

// Sign Out clears the key tables and the device joins again as a new device would, so no floor stays owed.
#[tokio::test]
async fn clearing_the_key_tables_ends_what_was_owed() {
    let disk = Disk::new();
    let copy = moved_on(&disk).await;
    disk.restore(&identity(), &copy).await;
    let state = disk.open().await;
    let opened = state.opened().clone();
    let mut txn = state.begin().await.unwrap();
    txn.clear_key_tables().await.unwrap();
    txn.commit().await.unwrap();
    drop(state);

    let state = disk.open().await;

    assert!(rebuild(&opened));
    assert_eq!(state.opened(), &Opened::FRESH);
    assert!(table(&state, Table::KeyPins).await.is_empty());
    assert_eq!(disk.store.count(is_checkpoint), 1);
}

// A second restore replaces the floor the first left: the first floor's items go with it.
#[tokio::test]
async fn a_newer_floor_retires_the_one_it_replaces() {
    let disk = Disk::new();
    let copy = moved_on(&disk).await;
    disk.restore(&identity(), &copy).await;
    let state = disk.open().await;
    let first = checkpoint_of(state.opened());
    put(&state, vec![Row::KeyEnvelope(envelope(3))]).await;
    drop(state);

    disk.restore(&identity(), &copy).await;
    let state = disk.open().await;
    let second = checkpoint_of(state.opened());
    drop(state);

    assert_eq!(first.envelopes, vec![envelope(2)]);
    assert_eq!(second.envelopes, vec![envelope(3)]);
    assert_eq!(disk.store.count(is_checkpoint), 1);
}

// An anchor with no file, as after a reinstall that kept the device store, rebuilds from its checkpoint.
#[tokio::test]
async fn an_anchor_with_no_file_rebuilds_from_its_checkpoint() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, keys_at(2, team_version(3, KeyVersionState::Ended, None), 2)).await;
    drop(state);

    disk.remove(&identity()).await;
    let state = disk.open().await;

    let opened = state.opened().clone();
    assert_eq!(opened.sync_tables, SyncTrust::Refill);
    assert_eq!(
        checkpoint_of(&opened).versions,
        vec![team_version(3, KeyVersionState::Ended, None)]
    );
    assert_eq!(
        table(&state, Table::KeyVersions).await,
        vec![Row::KeyVersion(team_version(3, KeyVersionState::Ended, None))]
    );
}

#[tokio::test]
async fn a_file_deleted_whole_takes_its_anchor_with_it() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, keys_at(1, team_version(1, KeyVersionState::Ok, None), 1)).await;
    drop(state);

    disk.files.delete(identity()).await.unwrap();
    let anchor_left = disk.store.items().len();
    let state = disk.open().await;

    assert_eq!(anchor_left, 0);
    assert_eq!(state.opened(), &Opened::FRESH);
}

#[tokio::test]
async fn a_file_whose_state_mac_does_not_verify_is_refused() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![store_row()]).await;
    drop(state);
    let binding = disk.raw(&identity(), Table::Binding, &RowKey::Binding).await;
    let mut forged = binding.clone();
    let last = forged.len() - 1;
    forged[last] ^= 1;

    disk.tamper(&identity(), "UPDATE binding SET columns = ?", vec![forged])
        .await;

    assert_eq!(disk.files.open(identity()).await.err(), Some(StateError::Integrity));
}

// A crash at each step of a commit and its anchor (0054, Verification), opened with the file as the commit left it, as
// it was before, or restored to an older copy. A restore of the copy before a commit whose anchor did not settle leaves
// the key tables untrusted when that commit changed them, and rebuilds them on the pending checkpoint.
#[tokio::test]
async fn a_crash_at_each_step_of_a_commit_opens_as_the_rules_say() {
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Copy {
        Oldest,
        Before,
        After,
    }
    for changes_keys in [true, false] {
        let disk = Disk::new();
        drop(disk.open().await);
        let oldest = disk.copy(&identity()).await;
        let state = disk.open().await;
        put(&state, keys_at(1, team_version(1, KeyVersionState::Ok, None), 1)).await;
        drop(state);
        let before = disk.copy(&identity()).await;
        let state = disk.open().await;
        disk.store.record();
        let rows = if changes_keys {
            vec![Row::KeyEnvelope(envelope(2))]
        } else {
            vec![store_row()]
        };
        put(&state, rows).await;
        drop(state);
        let after = disk.copy(&identity()).await;
        let steps = disk.store.recorded();
        let pending_at = steps
            .iter()
            .position(|items| {
                items
                    .iter()
                    .any(|(item, value)| is_root(item) && Some(value) != steps[0].get(item))
            })
            .unwrap();
        let committed = if changes_keys { envelope(2) } else { envelope(1) };

        for (step, items) in steps.iter().enumerate() {
            for copy in [Copy::Oldest, Copy::Before, Copy::After] {
                let file = match copy {
                    Copy::Oldest => &oldest,
                    Copy::Before => &before,
                    Copy::After => &after,
                };
                disk.store.set_items(items.clone());
                disk.restore(&identity(), file).await;
                let state = disk.open().await;
                let opened = state.opened().clone();
                let envelopes = table(&state, Table::KeyEnvelopes).await;
                drop(state);

                let label = format!("keys {changes_keys}, step {step}, {copy:?}");
                // The newest entry the root holds at this step: the pending one from its first write on.
                let newest = if step < pending_at {
                    envelope(1)
                } else {
                    committed.clone()
                };
                let fresh = match copy {
                    Copy::Oldest => false,
                    Copy::Before => step < pending_at,
                    Copy::After => step >= pending_at,
                };
                if fresh {
                    assert_eq!(opened, Opened::FRESH, "{label}");
                } else if copy == Copy::Before && step == pending_at && !changes_keys {
                    assert_eq!(opened.sync_tables, SyncTrust::Refill, "{label}");
                    assert_eq!(opened.key_tables, KeyTrust::Trusted, "{label}");
                } else {
                    assert_eq!(opened.sync_tables, SyncTrust::Refill, "{label}");
                    assert_eq!(checkpoint_of(&opened).envelopes, vec![newest.clone()], "{label}");
                    assert_eq!(envelopes, vec![Row::KeyEnvelope(newest)], "{label}");
                }
            }
        }
    }
}

// The second step lost while the process runs: the next commit settles it first, and no commit starts while it cannot.
#[tokio::test]
async fn a_pending_entry_the_second_step_left_settles_before_the_next_commit() {
    let disk = Disk::new();
    let state = disk.open().await;
    disk.store.fail_root_write(2);
    put(&state, vec![Row::KeyEnvelope(envelope(1))]).await;
    disk.store.set_locked(true);
    let mut txn = state.begin().await.unwrap();
    txn.put(store_row()).await.unwrap();
    let refused = txn.commit().await.err();
    disk.store.set_locked(false);
    put(&state, vec![Row::KeyEnvelope(envelope(2))]).await;
    drop(state);

    let state = disk.open().await;

    assert_eq!(refused, Some(StateError::AnchorUnsettled));
    assert_eq!(get(&state, RowKey::Store("connections".to_owned())).await, None);
    assert_eq!(state.opened(), &Opened::FRESH);
    assert_eq!(disk.store.count(is_checkpoint), 1);
}

#[tokio::test]
async fn a_locked_device_refuses_a_commit_and_the_file_keeps_its_rows() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![Row::KeyEnvelope(envelope(1))]).await;

    disk.store.set_locked(true);
    let mut txn = state.begin().await.unwrap();
    txn.put(Row::KeyEnvelope(envelope(2))).await.unwrap();
    let refused = txn.commit().await.err();
    disk.store.set_locked(false);
    drop(state);
    let state = disk.open().await;

    assert_eq!(refused, Some(StateError::AnchorUnsettled));
    assert_eq!(state.opened(), &Opened::FRESH);
    assert_eq!(
        table(&state, Table::KeyEnvelopes).await,
        vec![Row::KeyEnvelope(envelope(1))]
    );
}

#[tokio::test]
async fn a_checkpoint_too_big_for_one_item_is_split_and_comes_back_whole() {
    let disk = Disk::new();
    let state = disk.open().await;
    let envelopes: Vec<Row> = (0..800)
        .map(|n| {
            Row::KeyEnvelope(KeyEnvelopeRow {
                scope: ScopeName::Personal,
                record_id: format!("connection/{}/password", Uuid::from_u128(n).hyphenated()),
                kv: v(1),
            })
        })
        .collect();
    put(&state, envelopes.clone()).await;
    drop(state);
    let parts = disk.store.count(is_checkpoint);

    disk.remove(&identity()).await;
    let state = disk.open().await;

    assert!(parts > 1, "{parts}");
    assert_eq!(table(&state, Table::KeyEnvelopes).await.len(), envelopes.len());
}

// A device with no store syncs team plaintext records only, and nothing proves its key tables are its latest.
#[tokio::test]
async fn a_device_without_a_store_opens_and_commits_without_an_anchor() {
    let dir = tempfile::tempdir().unwrap();
    let files = SqliteStateFiles::at(
        dir.path().to_path_buf(),
        Arc::new(FakeDeviceStore::without_store()) as Arc<dyn HostDeviceStore>,
    );
    let state = files.open(identity()).await.unwrap();

    let committed = put(&state, vec![store_row()]).await;

    assert_eq!(
        state.opened(),
        &Opened {
            sync_tables: SyncTrust::Trusted,
            key_tables: KeyTrust::Unanchored,
        }
    );
    assert!(committed >= 1);
}

#[tokio::test]
async fn an_icloud_file_is_sealed_holds_no_key_tables_and_refills_whole_when_stale() {
    let disk = Disk::new();
    let state = disk.open_as(&icloud()).await;
    put(
        &state,
        vec![Row::Scope(ScopeRow {
            cursor: Some(Cursor::CloudKit(vec![1])),
            ..ScopeRow::new(ScopeName::Personal)
        })],
    )
    .await;
    let mut txn = state.begin().await.unwrap();
    let refused = txn.put(Row::KeyEnvelope(envelope(1))).await.err();
    drop(txn);
    drop(state);
    let copy = disk.copy(&icloud()).await;
    let fresh = disk.open_as(&icloud()).await.opened().clone();
    let state = disk.open_as(&icloud()).await;
    put(&state, vec![store_row()]).await;
    drop(state);

    disk.restore(&icloud(), &copy).await;
    let state = disk.open_as(&icloud()).await;

    assert_eq!(refused, Some(StateError::WrongIdentity));
    assert_eq!(fresh, Opened::FRESH);
    assert_eq!(state.opened().sync_tables, SyncTrust::Refill);
    let Some(Row::Scope(scope)) = get(&state, RowKey::Scope(ScopeName::Personal)).await else {
        panic!("no scope row");
    };
    assert!(scope.refill);
}

#[tokio::test]
async fn the_mac_key_and_the_anchor_live_in_the_anchor_s_class() {
    let disk = Disk::new();
    drop(disk.open().await);

    let classes: Vec<_> = disk.store.items().keys().map(DeviceItem::class).collect();

    assert!(!classes.is_empty());
    assert!(
        classes
            .iter()
            .all(|class| *class == tablepro_sync::api::device_store::DeviceItemClass::Anchor)
    );
    assert_eq!(
        disk.store.count(|item| matches!(item, DeviceItem::StateMacKey { .. })),
        1
    );
}
