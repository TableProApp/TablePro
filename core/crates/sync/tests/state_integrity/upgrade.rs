// A file schema 1 wrote, from `fixtures/schema_1.txt`, which that build made (0066, The state file). It opens as the
// file it was, in this schema's rows and sealed again under its anchor, and the anchor's format 1 checkpoint reads.

use std::path::Path;
use std::sync::Arc;

use sqlx::AssertSqlSafe;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use tablepro_keys::encoding::Version;
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::trust::Replaced;
use tablepro_sync::api::device_store::DeviceItem;
use tablepro_sync::api::error::StateError;
use tablepro_sync::api::ids::{Cursor, ScopeName};
use tablepro_sync::api::state::{
    KeyTrust, Opened, Row, RowKey, ScopeRow, StateFiles, StateIdentity, StateStore, StoreRow, SyncTrust, Table,
};
use tablepro_sync::state::{SCHEMA_VERSION, state_name};
use uuid::Uuid;
use zeroize::Zeroizing;

use super::support::{Disk, Items, account, get, icloud, identity, put, table};

const FIXTURE: &str = include_str!("fixtures/schema_1.txt");

type Stored = Vec<(String, Vec<u8>, Vec<u8>)>;

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&text[at..at + 2], 16).unwrap())
        .collect()
}

// The rows and device items the schema 1 build left for one of its files.
fn fixture(file: &str, identity: &StateIdentity) -> (Stored, Items) {
    let state = state_name(identity);
    let mut rows = Stored::new();
    let mut items = Items::new();
    for line in FIXTURE.lines().filter(|line| !line.starts_with('#')) {
        let parts: Vec<&str> = line.split(' ').collect();
        if parts[0] != file {
            continue;
        }
        let read = match parts[1..] {
            ["row", table, key, columns] => {
                rows.push((table.to_owned(), unhex(key), unhex(columns)));
                true
            }
            ["item", "mac_key", value] => {
                items.insert(
                    DeviceItem::StateMacKey { state: state.clone() },
                    Zeroizing::new(unhex(value)),
                );
                true
            }
            ["item", "root", value] => {
                items.insert(
                    DeviceItem::AnchorRoot { state: state.clone() },
                    Zeroizing::new(unhex(value)),
                );
                true
            }
            ["item", "checkpoint", digest, part, value] => {
                let item = DeviceItem::AnchorCheckpoint {
                    state: state.clone(),
                    checkpoint: unhex(digest).try_into().unwrap(),
                    part: part.parse().unwrap(),
                };
                items.insert(item, Zeroizing::new(unhex(value)));
                true
            }
            _ => false,
        };
        assert!(read, "a fixture line this test does not read: {line}");
    }
    assert!(!rows.is_empty() && !items.is_empty(), "no {file} file in the fixture");
    (rows, items)
}

// The file on disk as schema 1 left it: that schema's two migrations, then its rows as they were stored.
async fn write_file(disk: &Disk, identity: &StateIdentity, rows: &Stored) {
    let path = disk.path(identity);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let migrations = tempfile::tempdir().unwrap();
    for name in ["20261126000000_state_tables.sql", "20261126000001_pending_bases.sql"] {
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("migrations/state")
            .join(name);
        std::fs::copy(source, migrations.path().join(name)).unwrap();
    }
    let options = SqliteConnectOptions::new()
        .filename(&path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .unwrap();
    sqlx::migrate::Migrator::new(migrations.path())
        .await
        .unwrap()
        .run(&pool)
        .await
        .unwrap();
    for (table, key, columns) in rows {
        sqlx::query(AssertSqlSafe(format!(
            "INSERT INTO {table} (key, columns) VALUES (?, ?)"
        )))
        .bind(key)
        .bind(columns)
        .execute(&pool)
        .await
        .unwrap();
    }
    pool.close().await;
}

async fn schema_1_disk(file: &str, identity: &StateIdentity) -> Disk {
    let disk = Disk::new();
    let (rows, items) = fixture(file, identity);
    write_file(&disk, identity, &rows).await;
    disk.store.set_items(items);
    disk
}

fn v(value: u32) -> Version {
    Version::new(value).unwrap()
}

// Schema 1 kept no replace point, so each replaced IK verifies nothing under it as history.
fn schema_1_replaced() -> Vec<Replaced> {
    [1, 2]
        .map(|byte| Replaced {
            ik: Ed25519Public([byte; 32]),
            av: v(1),
        })
        .to_vec()
}

async fn binding_of(state: &Arc<dyn StateStore>) -> (u32, u64) {
    let binding = match get(state, RowKey::Binding).await {
        Some(Row::Binding(binding)) => Some(binding),
        _ => None,
    };
    let binding = binding.unwrap();
    (binding.schema_version, binding.counter)
}

fn checkpoint_formats(disk: &Disk) -> Vec<u8> {
    disk.store
        .items()
        .into_iter()
        .filter(|(item, _)| matches!(item, DeviceItem::AnchorCheckpoint { part: 0, .. }))
        .map(|(_, value)| value[0])
        .collect()
}

#[tokio::test]
async fn a_schema_1_file_opens_fresh_in_this_schema_and_sealed_again() {
    let disk = schema_1_disk("service", &identity()).await;
    assert_eq!(checkpoint_formats(&disk), [1]);

    let state = disk.open().await;

    assert_eq!(state.opened(), &Opened::FRESH);
    // The open's own commit, two more, then the upgrade's.
    assert_eq!(binding_of(&state).await, (SCHEMA_VERSION, 4));
    match get(&state, RowKey::KeyPin(account())).await {
        Some(Row::KeyPin(pin)) => assert_eq!(pin.replaced, schema_1_replaced()),
        other => panic!("no pin: {other:?}"),
    }
    match get(&state, RowKey::Scope(ScopeName::Personal)).await {
        Some(Row::Scope(scope)) => {
            assert_eq!(scope.push_wait, None);
            assert_eq!(scope.cursor, Some(Cursor::Service("cursor-1".to_owned())));
        }
        other => panic!("no scope: {other:?}"),
    }
    let objects = table(&state, Table::KeyObjects).await;
    assert_eq!(objects.len(), 2);
    assert!(
        objects
            .iter()
            .all(|row| matches!(row, Row::KeyObject(object) if object.served.is_none()))
    );
    assert_eq!(table(&state, Table::Bases).await.len(), 1);
    assert_eq!(checkpoint_formats(&disk), [2]);
    drop(state);

    let state = disk.open().await;
    assert_eq!(state.opened(), &Opened::FRESH);
    assert_eq!(binding_of(&state).await, (SCHEMA_VERSION, 4));
}

#[tokio::test]
async fn a_changed_schema_1_file_is_refused() {
    let disk = Disk::new();
    let (mut rows, items) = fixture("service", &identity());
    let columns = rows
        .iter_mut()
        .filter(|(table, ..)| table == "scopes")
        .map(|(_, _, columns)| columns)
        .find(|columns| columns.windows(8).any(|bytes| bytes == b"cursor-1"))
        .unwrap();
    let at = columns.windows(8).position(|bytes| bytes == b"cursor-1").unwrap();
    columns[at + 7] = b'2';
    write_file(&disk, &identity(), &rows).await;
    disk.store.set_items(items);

    assert_eq!(disk.files.open(identity()).await.err(), Some(StateError::Integrity));
}

#[tokio::test]
async fn a_schema_1_anchor_without_its_file_rebuilds_on_its_format_1_checkpoint() {
    let disk = Disk::new();
    let (_, items) = fixture("service", &identity());
    disk.store.set_items(items);

    let state = disk.open().await;

    let KeyTrust::Rebuild { checkpoint } = &state.opened().key_tables else {
        panic!("not a rebuild: {:?}", state.opened());
    };
    let pin = checkpoint.pins.iter().find(|pin| pin.account == account()).unwrap();
    assert_eq!(pin.replaced, schema_1_replaced());
    assert_eq!(checkpoint.pins.len(), 2);
    assert_eq!(checkpoint.versions.len(), 1);
    assert_eq!(checkpoint.envelopes.len(), 1);
    match get(&state, RowKey::KeyPin(account())).await {
        Some(Row::KeyPin(installed)) => assert_eq!(installed.replaced, schema_1_replaced()),
        other => panic!("no pin: {other:?}"),
    }
}

#[tokio::test]
async fn a_schema_1_copy_restored_after_the_upgrade_opens_stale_in_this_schema() {
    let disk = schema_1_disk("service", &identity()).await;
    let copy = std::fs::read(disk.path(&identity())).unwrap();
    let state = disk.open().await;
    put(
        &state,
        vec![Row::Store(StoreRow {
            store: "connections.json".to_owned(),
            generation: Uuid::from_u128(9),
            sequence: 5,
        })],
    )
    .await;
    drop(state);

    disk.restore(&identity(), &copy).await;
    let state = disk.open().await;

    assert_eq!(state.opened().sync_tables, SyncTrust::Refill);
    assert!(matches!(state.opened().key_tables, KeyTrust::Rebuild { .. }));
    assert_eq!(binding_of(&state).await.0, SCHEMA_VERSION);
    match get(&state, RowKey::KeyPin(account())).await {
        Some(Row::KeyPin(pin)) => assert_eq!(pin.replaced, schema_1_replaced()),
        other => panic!("no pin: {other:?}"),
    }
}

// The upgrade writes nothing while the anchor cannot be read, and runs once it can.
#[tokio::test]
async fn a_schema_1_file_waits_for_its_device_store_before_it_upgrades() {
    let disk = schema_1_disk("service", &identity()).await;
    disk.store.set_unavailable(true);

    assert_eq!(
        disk.files.open(identity()).await.err(),
        Some(StateError::AnchorUnsettled)
    );
    assert_eq!(checkpoint_formats(&disk), [1]);

    disk.store.set_unavailable(false);
    let state = disk.open().await;
    assert_eq!(state.opened(), &Opened::FRESH);
    assert_eq!(binding_of(&state).await, (SCHEMA_VERSION, 4));
}

// The iCloud file's rows that only the engine can judge, its `stores` row per kind, stay for the engine's next fetch.
#[tokio::test]
async fn a_schema_1_icloud_file_opens_fresh_with_its_kind_rows_kept() {
    let disk = schema_1_disk("icloud", &icloud()).await;

    let state = disk.open_as(&icloud()).await;

    assert_eq!(state.opened(), &Opened::FRESH);
    assert_eq!(binding_of(&state).await.0, SCHEMA_VERSION);
    let stores: Vec<String> = table(&state, Table::Stores)
        .await
        .into_iter()
        .filter_map(|row| match row {
            Row::Store(row) => Some(row.store),
            _ => None,
        })
        .collect();
    assert_eq!(stores, ["connections.json/connection", "connections.json/ssh_profile"]);
    match get(&state, RowKey::Scope(ScopeName::Personal)).await {
        Some(Row::Scope(ScopeRow { cursor, push_wait, .. })) => {
            assert_eq!(cursor, Some(Cursor::CloudKit(vec![0xc1, 0xc2])));
            assert_eq!(push_wait, None);
        }
        other => panic!("no scope: {other:?}"),
    }
}

// A newer build's file is refused, and stays as it was rather than starting over.
#[tokio::test]
async fn a_file_of_a_newer_schema_is_refused_and_kept() {
    let disk = Disk::new();
    drop(disk.open().await);
    let columns = disk.raw(&identity(), Table::Binding, &RowKey::Binding).await;
    let schema = [&[1, 0, 0, 0, 8][..], &u64::from(SCHEMA_VERSION).to_be_bytes()].concat();
    let at = columns.windows(schema.len()).position(|bytes| bytes == schema).unwrap();
    let mut newer = columns.clone();
    newer[at + schema.len() - 1] += 1;
    disk.tamper(
        &identity(),
        "UPDATE binding SET columns = ? WHERE key = ?",
        vec![newer.clone(), RowKey::Binding.encoded()],
    )
    .await;

    for _ in 0..2 {
        assert_eq!(disk.files.open(identity()).await.err(), Some(StateError::Integrity));
    }
    assert_eq!(disk.raw(&identity(), Table::Binding, &RowKey::Binding).await, newer);
}
