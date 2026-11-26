// The generator of `schema_1.txt`, kept beside it and built by no target here: it compiles against tablepro-sync at
// c093f23382, the last schema 1 build. There it went in as `#[path = "fixtures/schema_1.rs"] mod schema_1_fixture;` in
// `tests/state_integrity/main.rs` and ran as
//
//   SCHEMA_1_FIXTURE=<out> cargo test -p tablepro-sync --test state_integrity schema_1_fixture -- --ignored
//
// It makes a service file and an iCloud file through that build's own state store and writes each stored row and
// device item as hex, one per line: `<file> row <table> <key> <columns>`, `<file> item mac_key <value>`,
// `<file> item root <value>` or `<file> item checkpoint <digest> <part> <value>`.

use tablepro_keys::encoding::{AccountId, KeyPurpose, Version};
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::trust::PinHow;
use tablepro_records::Kind;
use tablepro_sync::api::device_store::DeviceItem;
use tablepro_sync::api::ids::{ChangeTag, Cursor, EpochId, KindName, RecordKey, ScopeName};
use tablepro_sync::api::state::{
    BaseRow, KeyEnvelopeRow, KeyObjectRow, KeyPinRow, KeyVersionRow, KeyVersionState, Row, ScopeRow, StateIdentity,
    StoreRow, Table,
};
use uuid::Uuid;

use super::support::{Disk, account, icloud, identity, put};

fn v(value: u32) -> Version {
    Version::new(value).unwrap()
}

fn ik(byte: u8) -> Ed25519Public {
    Ed25519Public([byte; 32])
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn base(key: RecordKey, tag: ChangeTag) -> Row {
    Row::Base(BaseRow {
        key,
        tag,
        version: Some(2),
        revision: Some(2),
        epoch: None,
        deleted: None,
        fields: Some(serde_json::json!({"name": "Prod"})),
        created_ms: None,
    })
}

fn store(name: &str, generation: Uuid, sequence: u64) -> Row {
    Row::Store(StoreRow {
        store: name.to_owned(),
        generation,
        sequence,
    })
}

// Two commits after the open's own, so the anchor's current entry is the third and its checkpoint holds the pins.
fn service_commits() -> Vec<Vec<Row>> {
    let connection = RecordKey::new(ScopeName::Personal, Kind::Connection, "A");
    vec![
        vec![
            Row::Scope(ScopeRow {
                epoch: Some(EpochId(Uuid::from_u128(0xe1))),
                cursor: Some(Cursor::Service("cursor-1".to_owned())),
                key_version: Some(v(1)),
                horizon: Some(7),
                read_kinds: vec![KindName::of(Kind::Connection)],
                caught_up: true,
                ..ScopeRow::new(ScopeName::Personal)
            }),
            Row::Scope(ScopeRow {
                refill: true,
                ..ScopeRow::new(ScopeName::History)
            }),
            Row::KeyObject(KeyObjectRow {
                scope: ScopeName::Personal,
                kind: KindName::of(Kind::KeyAccount),
                record_id: format!("{}/3", account().to_wire()),
                fields: "{\"av\":3}".to_owned(),
                applied: true,
            }),
            Row::KeyObject(KeyObjectRow {
                scope: ScopeName::Personal,
                kind: KindName::of(Kind::KeyVersion),
                record_id: "personal/2".to_owned(),
                fields: "{}".to_owned(),
                applied: false,
            }),
            Row::KeyPin(KeyPinRow {
                account: account(),
                ik: ik(3),
                av: v(3),
                how: PinHow::Compared,
                alert: false,
                replaced: vec![ik(1), ik(2)],
            }),
            Row::KeyVersion(KeyVersionRow {
                scope: ScopeName::Personal,
                purpose: KeyPurpose::Personal,
                version: v(1),
                record: [0x11; 32],
                holders: Vec::new(),
                state: KeyVersionState::Ok,
                stopped_cause: None,
                epoch: None,
            }),
            Row::KeyEnvelope(KeyEnvelopeRow {
                scope: ScopeName::Personal,
                record_id: "connection/A/password".to_owned(),
                kv: v(1),
            }),
            base(connection, ChangeTag::Service("tag-2".to_owned())),
        ],
        vec![
            Row::KeyPin(KeyPinRow {
                account: AccountId(Uuid::from_u128(0xb)),
                ik: ik(0xb),
                av: v(1),
                how: PinHow::FirstUse,
                alert: false,
                replaced: Vec::new(),
            }),
            store("connections.json", Uuid::from_u128(9), 4),
        ],
    ]
}

// Each kind keeps its own `stores` row, and one whose category was off waits for its refill on the nil generation.
fn icloud_commits() -> Vec<Vec<Row>> {
    let connection = RecordKey::new(ScopeName::Personal, Kind::Connection, "A");
    vec![vec![
        Row::Scope(ScopeRow {
            cursor: Some(Cursor::CloudKit(vec![0xc1, 0xc2])),
            caught_up: true,
            ..ScopeRow::new(ScopeName::Personal)
        }),
        store("connections.json/connection", Uuid::from_u128(9), 4),
        store("connections.json/ssh_profile", Uuid::nil(), 0),
        base(connection, ChangeTag::CloudKit(vec![0x5f; 4])),
    ]]
}

async fn dump(name: &str, identity: &StateIdentity, commits: Vec<Vec<Row>>) -> Vec<String> {
    let disk = Disk::new();
    let state = disk.open_as(identity).await;
    for rows in commits {
        put(&state, rows).await;
    }
    drop(state);
    disk.files.release(identity).await.unwrap();
    let options = sqlx::sqlite::SqliteConnectOptions::new().filename(disk.path(identity));
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .unwrap();
    let mut lines = Vec::new();
    for table in Table::SYNC.into_iter().chain(Table::KEY) {
        let statement = format!("SELECT key, columns FROM {} ORDER BY key", table.name());
        let rows: Vec<(Vec<u8>, Vec<u8>)> = sqlx::query_as(sqlx::AssertSqlSafe(statement))
            .fetch_all(&pool)
            .await
            .unwrap();
        for (key, columns) in rows {
            lines.push(format!("{name} row {} {} {}", table.name(), hex(&key), hex(&columns)));
        }
    }
    pool.close().await;
    let mut items: Vec<String> = disk
        .store
        .items()
        .into_iter()
        .map(|(item, value)| match item {
            DeviceItem::StateMacKey { .. } => format!("{name} item mac_key {}", hex(&value)),
            DeviceItem::AnchorRoot { .. } => format!("{name} item root {}", hex(&value)),
            DeviceItem::AnchorCheckpoint { checkpoint, part, .. } => {
                format!("{name} item checkpoint {} {part} {}", hex(&checkpoint), hex(&value))
            }
            other => panic!("a state file wrote {other:?}"),
        })
        .collect();
    items.sort();
    lines.extend(items);
    lines
}

#[tokio::test]
#[ignore = "writes the schema 1 fixture from the schema 1 build"]
async fn schema_1_fixture() {
    let mut lines = vec!["# Written by tablepro-sync at c093f23382 through fixtures/schema_1.rs.".to_owned()];
    lines.extend(dump("service", &identity(), service_commits()).await);
    lines.extend(dump("icloud", &icloud(), icloud_commits()).await);
    let out = std::env::var("SCHEMA_1_FIXTURE").unwrap();
    std::fs::write(out, lines.join("\n") + "\n").unwrap();
}
