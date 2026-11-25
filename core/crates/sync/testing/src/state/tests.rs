use tablepro_keys::encoding::{AccountId, Origin, Version};
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::trust::PinHow;
use tablepro_records::Kind;
use tablepro_sync::api::ids::{ChangeTag, DeviceRowId, RecordKey, ScopeName};
use tablepro_sync::api::state::{
    BaseRow, KeyPinRow, KeyTrust, Opened, Row, RowKey, RowRange, ScopeRow, StateFiles, StateIdentity, SyncTrust, Table,
};
use uuid::Uuid;

use super::MemoryStateFiles;

fn identity(account: u128) -> StateIdentity {
    StateIdentity::Service {
        origin: Origin::parse("https://api.tablepro.app").unwrap(),
        sign_in: "sign-in".to_owned(),
        account: AccountId(Uuid::from_u128(account)),
        device_row: DeviceRowId("dev_a".to_owned()),
    }
}

fn base(id: &str) -> Row {
    Row::Base(BaseRow {
        key: RecordKey::new(ScopeName::Personal, Kind::Connection, id),
        tag: ChangeTag::Service("t".to_owned()),
        version: Some(1),
        revision: Some(1),
        epoch: None,
        deleted: None,
        fields: None,
    })
}

fn pin() -> Row {
    Row::KeyPin(KeyPinRow {
        account: AccountId(Uuid::nil()),
        ik: Ed25519Public([1; 32]),
        av: Version::new(1).unwrap(),
        how: PinHow::FirstUse,
        alert: false,
        replaced: Vec::new(),
    })
}

#[tokio::test]
async fn a_commit_lands_whole_and_raises_the_counter() {
    let files = MemoryStateFiles::new();
    let store = files.open(identity(1)).await.unwrap();
    let mut txn = store.begin().await.unwrap();
    txn.put(base("A")).await.unwrap();
    txn.put(Row::Scope(ScopeRow::new(ScopeName::Personal))).await.unwrap();

    let before = store
        .begin()
        .await
        .unwrap()
        .scan(&RowRange::Table(Table::Bases))
        .await
        .unwrap();
    let committed = txn.commit().await.unwrap();
    let after = store
        .begin()
        .await
        .unwrap()
        .scan(&RowRange::Table(Table::Bases))
        .await
        .unwrap();

    assert!(before.is_empty());
    assert_eq!(after, [base("A")]);
    assert_eq!(committed.counter, 1);
}

#[tokio::test]
async fn a_transaction_dropped_uncommitted_writes_nothing() {
    let files = MemoryStateFiles::new();
    let store = files.open(identity(1)).await.unwrap();
    {
        let mut txn = store.begin().await.unwrap();
        txn.put(base("A")).await.unwrap();
        assert!(txn.get(&base("A").key()).await.unwrap().is_some());
    }

    let mut txn = store.begin().await.unwrap();

    assert!(txn.get(&base("A").key()).await.unwrap().is_none());
}

#[tokio::test]
async fn each_identity_opens_its_own_file() {
    let files = MemoryStateFiles::new();
    let first = files.open(identity(1)).await.unwrap();
    let mut txn = first.begin().await.unwrap();
    txn.put(base("A")).await.unwrap();
    txn.commit().await.unwrap();

    let other = files.open(identity(2)).await.unwrap();
    let again = files.open(identity(1)).await.unwrap();

    assert!(
        other
            .begin()
            .await
            .unwrap()
            .get(&base("A").key())
            .await
            .unwrap()
            .is_none()
    );
    assert!(
        again
            .begin()
            .await
            .unwrap()
            .get(&base("A").key())
            .await
            .unwrap()
            .is_some()
    );
    files.delete(identity(1)).await.unwrap();
    assert!(!files.exists(&identity(1)));
}

#[tokio::test]
async fn clearing_the_key_tables_keeps_the_sync_tables() {
    let files = MemoryStateFiles::new();
    let store = files.open(identity(1)).await.unwrap();
    let mut txn = store.begin().await.unwrap();
    txn.put(base("A")).await.unwrap();
    txn.put(pin()).await.unwrap();
    txn.commit().await.unwrap();

    let mut txn = store.begin().await.unwrap();
    txn.clear_key_tables().await.unwrap();
    txn.commit().await.unwrap();

    let mut txn = store.begin().await.unwrap();
    assert!(txn.get(&pin().key()).await.unwrap().is_none());
    assert!(txn.get(&base("A").key()).await.unwrap().is_some());
    assert!(txn.get(&RowKey::Binding).await.unwrap().is_some());
}

#[tokio::test]
async fn an_open_reports_what_the_test_set_for_it() {
    let files = MemoryStateFiles::new();
    let stale = Opened {
        sync_tables: SyncTrust::Refill,
        key_tables: KeyTrust::Unanchored,
    };
    files.set_opened(identity(1), stale.clone());

    let first = files.open(identity(1)).await.unwrap();
    let second = files.open(identity(1)).await.unwrap();

    assert_eq!(first.opened(), &stale);
    assert_eq!(second.opened(), &Opened::FRESH);
}

#[tokio::test]
async fn a_refused_commit_writes_nothing() {
    let files = MemoryStateFiles::new();
    let store = files.open(identity(1)).await.unwrap();
    let mut txn = store.begin().await.unwrap();
    txn.put(base("A")).await.unwrap();
    txn.delete(&RowKey::Binding).await.unwrap();

    let refused = txn.commit().await;

    let mut txn = store.begin().await.unwrap();
    assert!(refused.is_err());
    assert!(txn.get(&base("A").key()).await.unwrap().is_none());
    assert!(txn.get(&RowKey::Binding).await.unwrap().is_some());
}
