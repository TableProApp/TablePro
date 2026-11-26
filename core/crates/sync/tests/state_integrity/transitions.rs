// The device store coming and going, a MAC key made again, an anchor this build cannot read, the schema a local writer
// could change, and a writer while the store holds the file: none leaves a file that can never open again, and none
// trusts what nothing proves.

use tablepro_keys::encoding::Version;
use tablepro_sync::api::device_store::{DeviceItem, HostDeviceStore};
use tablepro_sync::api::error::StateError;
use tablepro_sync::api::ids::{Cursor, ScopeName};
use tablepro_sync::api::state::{
    KeyEnvelopeRow, KeyTrust, KeysSettled, Opened, Row, RowKey, ScopeRow, StateFiles, StoreRow, SyncTrust, Table,
};
use tablepro_sync::state::state_name;
use uuid::Uuid;
use zeroize::Zeroizing;

use super::support::{Disk, get, icloud, identity, put, table};

fn store_row(sequence: u64) -> Row {
    Row::Store(StoreRow {
        store: "connections".to_owned(),
        generation: Uuid::from_u128(9),
        sequence,
    })
}

fn envelope(kv: u32) -> Row {
    Row::KeyEnvelope(KeyEnvelopeRow {
        scope: ScopeName::Personal,
        record_id: "connection/A/password".to_owned(),
        kv: Version::new(kv).unwrap(),
    })
}

fn unanchored_refill() -> Opened {
    Opened {
        sync_tables: SyncTrust::Refill,
        key_tables: KeyTrust::Unanchored,
    }
}

// A sealed file waits while its store is away, rather than taking commits it could not seal.
#[tokio::test]
async fn a_sealed_file_waits_for_its_store_and_opens_fresh_once_it_is_back() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![store_row(1)]).await;
    drop(state);

    disk.store.set_unavailable(true);
    let waiting = disk.files.open(identity()).await.err();
    disk.store.set_unavailable(false);
    let state = disk.open().await;

    assert_eq!(waiting, Some(StateError::AnchorUnsettled));
    assert_eq!(state.opened(), &Opened::FRESH);
}

// A file a device with no store kept, met once a store appears: nothing proves it, so it opens with no anchor and is
// sealed from then on.
#[tokio::test]
async fn a_file_no_store_sealed_opens_with_no_anchor_once_a_store_appears() {
    let disk = Disk::new();
    disk.store.set_unavailable(true);
    let state = disk.open().await;
    let unsealed = state.opened().clone();
    put(&state, vec![store_row(1), envelope(1)]).await;
    drop(state);

    disk.store.set_unavailable(false);
    let state = disk.open().await;
    let first = state.opened().clone();
    drop(state);
    let again = disk.open().await;

    assert_eq!(
        unsealed,
        Opened {
            sync_tables: SyncTrust::Trusted,
            key_tables: KeyTrust::Unanchored,
        }
    );
    assert_eq!(first, unanchored_refill());
    assert_eq!(again.opened().sync_tables, SyncTrust::Trusted);
    assert_eq!(again.opened().key_tables, KeyTrust::Unanchored);
    assert_eq!(table(&again, Table::KeyEnvelopes).await, vec![envelope(1)]);
}

// A file made while the store was away, after an earlier file of the identity left its key and anchor: it never
// verified under that key, so none of it is kept, and the anchor's floor stands in for its key tables.
#[tokio::test]
async fn a_file_made_without_its_store_starts_over_on_the_anchor_once_the_store_is_back() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![envelope(2)]).await;
    drop(state);
    disk.remove(&identity()).await;
    disk.store.set_unavailable(true);
    let state = disk.open().await;
    put(&state, vec![store_row(1), envelope(1)]).await;
    drop(state);

    disk.store.set_unavailable(false);
    let state = disk.open().await;

    assert_eq!(state.opened().sync_tables, SyncTrust::Refill);
    assert!(matches!(&state.opened().key_tables, KeyTrust::Rebuild { checkpoint } if checkpoint.envelopes.len() == 1));
    assert_eq!(table(&state, Table::KeyEnvelopes).await, vec![envelope(2)]);
    assert_eq!(get(&state, RowKey::Store("connections".to_owned())).await, None);
}

// A MAC key made again goes into the store only once the file it seals landed: a crash or a failed write before leaves
// a file whose key is gone, never one the stored key does not verify.
#[tokio::test]
async fn a_mac_key_made_again_never_leaves_a_file_it_does_not_verify() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![envelope(1)]).await;
    drop(state);
    disk.store.remove_passcode();

    disk.store.fail_root_write(1);
    let before_commit = disk.files.open(identity()).await.err();
    disk.store.fail_mac_key_write();
    let after_commit = disk.files.open(identity()).await.err();
    let key_stored = disk.store.count(|item| matches!(item, DeviceItem::StateMacKey { .. }));
    let state = disk.open().await;
    let opened = state.opened().clone();
    drop(state);
    let again = disk.open().await;

    assert_eq!(before_commit, Some(StateError::AnchorUnsettled));
    assert_eq!(after_commit, Some(StateError::AnchorUnsettled));
    assert_eq!(key_stored, 0);
    assert_eq!(opened, unanchored_refill());
    assert_eq!(again.opened().key_tables, KeyTrust::Unanchored);
}

#[tokio::test]
async fn an_anchor_this_build_cannot_read_counts_as_one_whose_content_is_unknown() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![envelope(1)]).await;
    drop(state);
    let root = DeviceItem::AnchorRoot {
        state: state_name(&identity()),
    };
    disk.store
        .store(root.clone(), Zeroizing::new(vec![9, 9]))
        .await
        .unwrap();

    let existing = disk.open().await.opened().clone();
    disk.store.store(root, Zeroizing::new(vec![9, 9])).await.unwrap();
    disk.remove(&identity()).await;
    let new_file = disk.open().await.opened().clone();

    assert_eq!(existing, unanchored_refill());
    assert_eq!(new_file.key_tables, KeyTrust::Unanchored);
}

// A MAC key with no root beside it says an anchor existed and was lost: a new file of that identity trusts nothing.
#[tokio::test]
async fn a_new_file_beside_a_lost_anchor_opens_with_no_anchor() {
    let disk = Disk::new();
    drop(disk.open().await);
    disk.store
        .delete(DeviceItem::AnchorRoot {
            state: state_name(&identity()),
        })
        .await
        .unwrap();
    disk.remove(&identity()).await;

    let state = disk.open().await;

    assert_eq!(state.opened(), &unanchored_refill());
}

// The MAC covers rows, not the schema: a trigger or a view would change what a commit seals, so a file with one is
// refused.
#[tokio::test]
async fn a_file_whose_schema_a_writer_changed_is_refused() {
    for statement in [
        "CREATE TRIGGER keep AFTER UPDATE ON key_pins BEGIN UPDATE key_pins SET columns = OLD.columns WHERE key = NEW.key; END",
        "CREATE VIEW seen AS SELECT key FROM key_pins",
        "CREATE INDEX extra ON key_pins (columns)",
        "CREATE TABLE extra (x)",
    ] {
        let disk = Disk::new();
        drop(disk.open().await);

        disk.tamper(&identity(), statement, Vec::new()).await;

        assert_eq!(
            disk.files.open(identity()).await.err(),
            Some(StateError::Integrity),
            "{statement}"
        );
    }
}

// While the store holds the file, no other connection writes it: a row it could write would be sealed by the next
// commit.
#[tokio::test]
async fn no_other_connection_writes_the_file_while_it_is_open() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![store_row(1)]).await;

    let options = sqlx::sqlite::SqliteConnectOptions::new()
        .filename(disk.path(&identity()))
        .busy_timeout(std::time::Duration::from_millis(50));
    let other = sqlx::sqlite::SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await;
    let written = match other {
        Ok(pool) => sqlx::query("DELETE FROM stores").execute(&pool).await.is_ok(),
        Err(_) => false,
    };

    assert!(!written);
    assert_eq!(
        get(&state, RowKey::Store("connections".to_owned())).await,
        Some(store_row(1))
    );
}

// An iCloud file has no key tables, so a stale one only refills.
#[tokio::test]
async fn a_stale_icloud_file_owes_nothing_of_key_tables() {
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
    drop(state);
    disk.store.remove_passcode();

    let state = disk.open_as(&icloud()).await;
    let first = state.opened().clone();
    drop(state);
    let again = disk.open_as(&icloud()).await;

    assert_eq!(
        first,
        Opened {
            sync_tables: SyncTrust::Refill,
            key_tables: KeyTrust::Trusted,
        }
    );
    assert_eq!(again.opened(), &Opened::FRESH);
}

// A settle whose commit landed takes effect even when the anchor's second step was lost with the process: the root
// keeps it with the pending entry, and the next open finishes that step.
#[tokio::test]
async fn a_settle_whose_commit_landed_survives_a_lost_second_step() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![store_row(1)]).await;
    drop(state);
    disk.store.remove_passcode();
    drop(disk.open().await);
    let state = disk.open().await;

    disk.store.fail_root_write(2);
    let mut txn = state.begin().await.unwrap();
    txn.settle_keys(KeysSettled::Reapproved);
    txn.put(store_row(2)).await.unwrap();
    txn.commit().await.unwrap();
    drop(state);
    let reopened = disk.open().await;

    assert_eq!(reopened.opened(), &Opened::FRESH);
    assert_eq!(
        get(&reopened, RowKey::Store("connections".to_owned())).await,
        Some(store_row(2))
    );
}

// A copy sealed under a MAC key since deleted, put back after the identity started a new file: the key the device holds
// does not verify it and the anchor does not name it, so it starts over on the anchor rather than being refused for
// good.
#[tokio::test]
async fn a_copy_sealed_under_a_key_since_made_again_starts_over_on_the_anchor() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![store_row(1), envelope(1)]).await;
    drop(state);
    let copy = disk.copy(&identity()).await;
    disk.files.delete(identity()).await.unwrap();
    let state = disk.open().await;
    put(&state, vec![envelope(2)]).await;
    drop(state);

    disk.restore(&identity(), &copy).await;
    let state = disk.open().await;

    assert_eq!(state.opened().sync_tables, SyncTrust::Refill);
    assert!(matches!(state.opened().key_tables, KeyTrust::Rebuild { .. }));
    assert_eq!(table(&state, Table::KeyEnvelopes).await, vec![envelope(2)]);
    assert_eq!(get(&state, RowKey::Store("connections".to_owned())).await, None);
}

// The file the anchor names, with its MAC written over, is refused: only a file the anchor does not know starts over.
#[tokio::test]
async fn the_anchored_file_with_its_mac_zeroed_is_refused() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![store_row(1)]).await;
    drop(state);
    let binding = disk.raw(&identity(), Table::Binding, &RowKey::Binding).await;
    let zeroed = [&binding[..binding.len() - 32], &[0; 32]].concat();

    disk.tamper(&identity(), "UPDATE binding SET columns = ?", vec![zeroed])
        .await;

    assert_eq!(disk.files.open(identity()).await.err(), Some(StateError::Integrity));
}

// A key stored as text sorts and hashes as the blob it was, so the MAC still verifies, yet no lookup finds it: a file
// with one is refused.
#[tokio::test]
async fn a_row_whose_key_a_writer_stored_as_text_is_refused() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(&state, vec![envelope(1)]).await;
    drop(state);

    disk.tamper(
        &identity(),
        "UPDATE key_envelopes SET key = CAST(key AS TEXT)",
        Vec::new(),
    )
    .await;

    assert_eq!(disk.files.open(identity()).await.err(), Some(StateError::Integrity));
}
