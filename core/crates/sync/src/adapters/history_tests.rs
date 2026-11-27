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
        "duration_us": 12,
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
        duration_us: None,
        rows_affected: None,
        outcome: Outcome::Success,
        details: RunDetails::default(),
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
        duration_us: None,
        rows_affected: None,
        outcome: Outcome::Success,
        details: RunDetails::default(),
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

#[tokio::test]
async fn a_run_put_back_under_a_judged_id_is_judged_again() {
    let dir = tempfile::tempdir().unwrap();
    let (history, adapter) = adapter(dir.path()).await;
    let plain = ran_on("PostgreSQL", "SELECT * FROM users");
    history.put(std::slice::from_ref(&plain)).await.unwrap();
    let before = adapter.records(ScopeName::History).await.unwrap().records[0].standing;
    for replacement in [
        ran_on("PostgreSQL", "CREATE ROLE app LOGIN PASSWORD 'p'"),
        ran_on("Oracle", "SELECT * FROM users"),
    ] {
        history.remove(&[plain.record_id]).await.unwrap();
        history
            .put(&[NewEntry {
                record_id: plain.record_id,
                ..replacement
            }])
            .await
            .unwrap();

        let after = adapter.records(ScopeName::History).await.unwrap().records[0].standing;

        assert_eq!(after, Standing::LocalOnly);
    }
    assert_eq!(before, Standing::Syncs);
}

struct Unknown;

impl ConnectionStanding for Unknown {
    fn standing(&self, _connection: Uuid) -> Standing {
        Standing::Unknown
    }
}

#[tokio::test]
async fn a_deletion_of_a_connection_that_does_not_sync_stays_here_and_one_not_known_yet_waits() {
    let dir = tempfile::tempdir().unwrap();
    let (history, adapter) = adapter(dir.path()).await;
    let shop = ran_on("PostgreSQL", "SELECT 1");
    let scratch = NewEntry {
        connection_id: Uuid::parse_str(SCRATCH).unwrap(),
        ..ran_on("PostgreSQL", "SELECT 2")
    };
    history.put(&[shop.clone(), scratch.clone()]).await.unwrap();
    history.clear_all().await.unwrap();
    let waiting = HistoryAdapter::new(history.clone(), Arc::new(Unknown))
        .records(ScopeName::History)
        .await
        .unwrap();

    let local = adapter.records(ScopeName::History).await.unwrap();

    assert!(waiting.tombstones.is_empty());
    assert_eq!(waiting.unreadable.len(), 2, "held while the standing is not known");
    assert_eq!(local.tombstones, vec![uuid_id(shop.record_id)]);
    assert!(local.unreadable.is_empty());
    let left: Vec<Uuid> = history
        .tombstones()
        .await
        .unwrap()
        .into_iter()
        .map(|tombstone| tombstone.record_id)
        .collect();
    assert_eq!(
        left,
        vec![shop.record_id],
        "the Local only connection's deletion never leaves the device"
    );
}

#[tokio::test]
async fn a_run_s_details_go_up_and_come_back_and_its_fingerprint_stays_here() {
    let dir = tempfile::tempdir().unwrap();
    let (history, adapter) = adapter(dir.path()).await;
    let mut ran = ran_on("PostgreSQL", "SELECT 1");
    ran.details = RunDetails {
        database: Some("shop".to_owned()),
        schema: Some("public".to_owned()),
        source: Some(RunSource::TableBrowse),
        statement_type: Some(StatementType::Select),
        first_row_us: Some(7),
        server_us: Some(5),
        fingerprint: Some(99),
    };
    history.record(ran.clone()).await.unwrap();

    let fields = adapter.records(ScopeName::History).await.unwrap().records[0]
        .fields
        .clone();

    for (member, value) in [
        ("database", json!("shop")),
        ("schema", json!("public")),
        ("source", json!("table_browse")),
        ("statement_type", json!("select")),
        ("first_row_us", json!(7)),
        ("server_us", json!(5)),
    ] {
        assert_eq!(fields[member], value, "{member}");
    }
    assert!(fields.get("fingerprint").is_none());
    let pulled = entry_from(&uuid_id(Uuid::new_v4()), &fields).unwrap().unwrap();
    assert_eq!(
        pulled.details,
        RunDetails {
            fingerprint: None,
            ..ran.details
        }
    );
}

#[tokio::test]
async fn a_run_under_a_millisecond_reaches_another_device_with_its_microseconds() {
    let here = tempfile::tempdir().unwrap();
    let there = tempfile::tempdir().unwrap();
    let (history, adapter) = adapter(here.path()).await;
    let (other_history, other) = adapter(there.path()).await;
    let mut ran = ran_on("PostgreSQL", "SELECT 1");
    ran.duration_us = Some(90);
    ran.details.first_row_us = Some(70);
    ran.details.server_us = Some(40);
    history.record(ran.clone()).await.unwrap();

    let sent = adapter.records(ScopeName::History).await.unwrap().records.remove(0);
    other
        .apply(ScopeName::History, vec![put(&sent.record_id, sent.fields.clone())])
        .await
        .unwrap();

    assert_eq!(
        (
            &sent.fields["duration_us"],
            &sent.fields["first_row_us"],
            &sent.fields["server_us"]
        ),
        (&json!(90), &json!(70), &json!(40))
    );
    // A pulled run comes without a fingerprint, so this reads every run the other device holds.
    let arrived = &other_history.without_fingerprint(10).await.unwrap()[0];
    assert_eq!(arrived.duration_us, Some(90));
    assert_eq!(
        (arrived.details.first_row_us, arrived.details.server_us),
        (Some(70), Some(40))
    );
}

#[test]
fn every_source_and_statement_type_is_a_wire_value() {
    let enum_values = |member: &str| match tablepro_records::schema::HISTORY_ENTRY
        .iter()
        .find(|field| field.key == member)
        .map(|field| field.ty)
    {
        Some(tablepro_records::schema::Type::Enum(values)) => values.to_vec(),
        other => panic!("{member} is {other:?}"),
    };
    let sources: Vec<&str> = RunSource::ALL.iter().map(|source| source.as_str()).collect();
    let kinds: Vec<&str> = StatementType::ALL.iter().map(|kind| kind.as_str()).collect();
    assert_eq!(sources, enum_values("source"));
    assert_eq!(kinds, enum_values("statement_type"));
}
