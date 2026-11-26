use std::collections::HashSet;
use std::time::{Duration, SystemTime};

use serde_json::json;
use tablepro_storage::StoragePaths;

use super::*;
use crate::api::state::Standing;

const SHOP: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";
const SCRATCH: &str = "E6C12C96-3CBD-4A0E-9F41-E36B47F35D84";

struct LocalOnly(HashSet<Uuid>);

impl ConnectionStanding for LocalOnly {
    fn standing(&self, connection: Uuid) -> Standing {
        if self.0.contains(&connection) {
            Standing::LocalOnly
        } else {
            Standing::Syncs
        }
    }
}

async fn adapter(dir: &std::path::Path) -> (QueryHistory, HistoryAdapter) {
    let history = QueryHistory::open(&StoragePaths::under(dir, "tablepro", "app.tablepro.TablePro"))
        .await
        .unwrap();
    let scratch = Uuid::parse_str(SCRATCH).unwrap();
    let adapter = HistoryAdapter::new(history.clone(), Arc::new(LocalOnly(HashSet::from([scratch]))));
    (history, adapter)
}

fn wire(query: &str, connection: &str, seconds: i64) -> Value {
    json!({
        "query": query,
        "connection_id": connection,
        "connection_name": "shop",
        "database_type": "PostgreSQL",
        "executed_at": seconds * 1000,
        "duration_ms": 12,
        "row_count": 3,
        "succeeded": false,
        "cancelled": false,
        "error": "syntax error",
    })
}

fn entry_id(n: u8) -> String {
    format!("07D0575D-F499-463A-AB54-2852D631B0{n:02X}")
}

fn put(record_id: &str, fields: Value) -> LocalChange {
    LocalChange::Put {
        record_id: record_id.to_owned(),
        fields,
    }
}

#[tokio::test]
async fn a_pulled_entry_reads_back_as_it_came_and_a_local_only_connection_s_runs_stay() {
    let dir = tempfile::tempdir().unwrap();
    let (_, adapter) = adapter(dir.path()).await;
    let shop = wire("SELECT 1", SHOP, 1_767_225_600);
    let scratch = wire("SELECT 2", SCRATCH, 1_767_225_601);

    adapter
        .apply(
            ScopeName::History,
            vec![put(&entry_id(1), shop.clone()), put(&entry_id(2), scratch.clone())],
        )
        .await
        .unwrap();

    let local = adapter.records(ScopeName::History).await.unwrap();
    let record = |id: &str| local.records.iter().find(|record| record.record_id == id).unwrap();
    assert_eq!(record(&entry_id(1)).fields, shop);
    assert_eq!(record(&entry_id(1)).standing, Standing::Syncs);
    assert_eq!(record(&entry_id(2)).fields, scratch);
    assert_eq!(record(&entry_id(2)).standing, Standing::LocalOnly);
    assert!(adapter.records(ScopeName::Personal).await.unwrap().records.is_empty());
}

#[tokio::test]
async fn an_outcome_reads_as_the_store_keeps_it() {
    let succeeded = json!({"query": "q", "connection_id": SHOP, "executed_at": 1_000, "succeeded": true});
    let cancelled = json!({"query": "q", "connection_id": SHOP, "executed_at": 1_000, "cancelled": true});
    let failed = json!({"query": "q", "connection_id": SHOP, "executed_at": 1_000});

    let outcome = |fields: &Value| entry_from(&entry_id(1), fields).unwrap().unwrap().outcome;

    assert_eq!(outcome(&succeeded), Outcome::Success);
    assert_eq!(outcome(&cancelled), Outcome::Cancelled);
    assert_eq!(outcome(&failed), Outcome::Error(String::new()));
}

#[tokio::test]
async fn a_pulled_entry_the_store_cannot_hold_is_left_out_and_the_rest_go_in() {
    let dir = tempfile::tempdir().unwrap();
    let (history, adapter) = adapter(dir.path()).await;
    let mut no_connection = wire("SELECT 1", SHOP, 1_000);
    no_connection["connection_id"] = json!(null);
    let mut too_long = wire("SELECT 1", SHOP, 1_000);
    too_long["query"] = json!("x".repeat(MAX_QUERY_BYTES + 1));
    let mut untyped = wire("SELECT 1", SHOP, 1_000);
    untyped["executed_at"] = json!("yesterday");
    let not_v4 = "07D0575D-F499-763A-AB54-2852D631B001";

    adapter
        .apply(
            ScopeName::History,
            vec![
                put(&entry_id(1), no_connection),
                put(&entry_id(2), too_long),
                put(&entry_id(3), untyped),
                put(not_v4, wire("SELECT 1", SHOP, 1_000)),
                put(&entry_id(5), wire("SELECT 5", SHOP, 1_000)),
            ],
        )
        .await
        .unwrap();

    let ids: Vec<String> = history
        .entries()
        .await
        .unwrap()
        .into_iter()
        .map(|entry| uuid_id(entry.record_id))
        .collect();
    assert_eq!(ids, vec![entry_id(5)]);
}

#[tokio::test]
async fn a_pulled_deletion_leaves_no_tombstone_and_the_person_s_goes_until_it_is_pushed() {
    let dir = tempfile::tempdir().unwrap();
    let (history, adapter) = adapter(dir.path()).await;
    adapter
        .apply(
            ScopeName::History,
            vec![
                put(&entry_id(1), wire("SELECT 1", SHOP, 1_000)),
                put(&entry_id(2), wire("SELECT 2", SHOP, 2_000)),
            ],
        )
        .await
        .unwrap();

    adapter
        .apply(ScopeName::History, vec![LocalChange::Delete { record_id: entry_id(1) }])
        .await
        .unwrap();
    history.clear_all().await.unwrap();
    let deleted = adapter.records(ScopeName::History).await.unwrap();
    adapter
        .tombstones_pushed(ScopeName::History, vec![entry_id(2)])
        .await
        .unwrap();

    assert!(deleted.records.is_empty());
    assert_eq!(deleted.tombstones, vec![entry_id(2)]);
    assert!(adapter.records(ScopeName::History).await.unwrap().tombstones.is_empty());
}

#[tokio::test]
async fn a_run_this_device_recorded_reads_as_its_wire_entry_in_whole_seconds() {
    let dir = tempfile::tempdir().unwrap();
    let (history, adapter) = adapter(dir.path()).await;
    let ran = NewEntry {
        record_id: Uuid::new_v4(),
        query: "SELECT now()".to_owned(),
        driver_id: "PostgreSQL".to_owned(),
        connection_id: Uuid::parse_str(SHOP).unwrap(),
        connection_name: "shop".to_owned(),
        executed_at: SystemTime::UNIX_EPOCH + Duration::from_millis(1_767_225_600_999),
        duration_ms: None,
        rows_affected: None,
        outcome: Outcome::Success,
    };
    history.record(ran.clone()).await.unwrap();

    let local = adapter.records(ScopeName::History).await.unwrap();

    assert_eq!(local.records.len(), 1);
    assert_eq!(local.records[0].record_id, uuid_id(ran.record_id));
    assert_eq!(
        local.records[0].fields,
        json!({
            "query": "SELECT now()",
            "connection_id": SHOP,
            "connection_name": "shop",
            "database_type": "PostgreSQL",
            "executed_at": 1_767_225_600_000_i64,
            "succeeded": true,
            "cancelled": false,
        })
    );
}

// One statement per engine that carries a secret, under the names the core's drivers and the Apple apps give engines.
const SECRETS: &[(&str, &str)] = &[
    ("postgres", "CREATE ROLE app LOGIN PASSWORD 'p'"),
    ("PostgreSQL", "SELECT dblink_connect('password=x')"),
    ("MySQL", "CREATE USER 'u'@'%' IDENTIFIED BY 'p'"),
    ("MariaDB", "SET PASSWORD FOR 'u'@'h' = 'x'"),
    ("SQLite", "PRAGMA key = 'x'"),
    ("SQL Server", "CREATE LOGIN l WITH PASSWORD = N'x'"),
    ("ClickHouse", "SELECT * FROM mysql('h','d','t','u','p')"),
    ("DuckDB", "CREATE SECRET s (TYPE s3, KEY_ID 'k', SECRET 'v')"),
    ("Cassandra", "CREATE USER u WITH PASSWORD 'secret'"),
    ("Redis", "AUTH s3cret"),
    ("MongoDB", "db.createUser({user: 'a', pwd: 'b', roles: []})"),
];

fn ran_on(engine: &str, query: &str) -> NewEntry {
    NewEntry {
        record_id: Uuid::new_v4(),
        query: query.to_owned(),
        driver_id: engine.to_owned(),
        connection_id: Uuid::parse_str(SHOP).unwrap(),
        connection_name: "shop".to_owned(),
        executed_at: SystemTime::UNIX_EPOCH + Duration::from_secs(1_767_225_600),
        duration_ms: None,
        rows_affected: None,
        outcome: Outcome::Success,
    }
}

#[tokio::test]
async fn a_run_the_rules_keep_out_of_history_stays_here_whichever_app_recorded_it() {
    let dir = tempfile::tempdir().unwrap();
    let (history, adapter) = adapter(dir.path()).await;
    let secrets: Vec<NewEntry> = SECRETS.iter().map(|(engine, query)| ran_on(engine, query)).collect();
    let plain = ran_on("PostgreSQL", "SELECT * FROM users");
    let unknown = ran_on("Oracle", "SELECT * FROM users");
    let mut all = secrets.clone();
    all.extend([plain.clone(), unknown.clone()]);
    // As an Apple app records, with no driver reading the statements.
    history.put(&all).await.unwrap();

    let first = adapter.records(ScopeName::History).await.unwrap();
    let again = adapter.records(ScopeName::History).await.unwrap();

    let standing = |id: Uuid| {
        first
            .records
            .iter()
            .find(|record| record.record_id == uuid_id(id))
            .unwrap()
            .standing
    };
    for (entry, (engine, query)) in secrets.iter().zip(SECRETS) {
        assert_eq!(standing(entry.record_id), Standing::LocalOnly, "{engine}: {query}");
    }
    assert_eq!(
        standing(unknown.record_id),
        Standing::LocalOnly,
        "an engine nothing reads"
    );
    assert_eq!(standing(plain.record_id), Standing::Syncs);
    assert_eq!(first, again, "a verdict kept between passes is the same");
}

#[tokio::test]
async fn a_pulled_run_the_rules_keep_out_of_history_is_not_stored() {
    let dir = tempfile::tempdir().unwrap();
    let (history, adapter) = adapter(dir.path()).await;
    let mut secret = wire("CREATE USER 'u'@'%' IDENTIFIED BY 'p'", SHOP, 1_000);
    secret["database_type"] = json!("MySQL");
    let mut unknown = wire("SELECT 1", SHOP, 1_000);
    unknown["database_type"] = json!("Oracle");

    adapter
        .apply(
            ScopeName::History,
            vec![
                put(&entry_id(1), secret),
                put(&entry_id(2), unknown),
                put(&entry_id(3), wire("SELECT 3", SHOP, 1_000)),
            ],
        )
        .await
        .unwrap();

    let ids: Vec<String> = history
        .entries()
        .await
        .unwrap()
        .into_iter()
        .map(|entry| uuid_id(entry.record_id))
        .collect();
    assert_eq!(ids, vec![entry_id(3)]);
}
