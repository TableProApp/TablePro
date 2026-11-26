// The record rules the adapters' side of the pass applies (0044, Fields a pull applies only with approval; 0051,
// Conflict rules, Tombstones, Pull; 0054, Rules for both providers; 0061, 2): the approval queue, team conflicts,
// members a store has no place for, categories turned off, the host's journal, and the history window.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tablepro_keys::encoding::TeamId;
use tablepro_records::Kind;
use tablepro_sync::api::adapter::{LocalChange, LocalRecords, RecordAdapter, StoreStamp};
use tablepro_sync::api::control::{ConflictChoice, PassReason, SyncCategories, SyncControl};
use tablepro_sync::api::error::{AdapterError, SyncError};
use tablepro_sync::api::ids::{KindName, RecordKey, ScopeName};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::{HeldReason, Row, RowKey, RowRange, Table};
use tablepro_sync::api::transport::DeletedReason;
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::service::{Policies, ScopeOwner};
use uuid::Uuid;

use super::harness::{ACCOUNT, Device, DeviceBuilder, MemoryAdapter, StoreFile, account, id, personal, write};

fn stored(server: &FakeServer, kind: &str, record: &str) -> Option<Value> {
    server.stored(personal(), kind, record).and_then(|record| record.fields)
}

fn key(record: &str) -> RecordKey {
    RecordKey::new(ScopeName::Personal, Kind::Connection, record)
}

#[tokio::test]
async fn a_connection_new_to_a_device_waits_whole_until_its_destination_is_approved() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    let prod = json!({"name": "Prod", "host": "db.example.com", "safe_mode_level": "readOnly"});
    mac.connections.put(&id(1), prod.clone());
    mac.sync().await;

    mini.sync().await;
    let held = mini.connections.get(&id(1));
    let waiting = mini.sync.approvals().await.unwrap();
    let status = mini.sync.status();
    mini.sync
        .decide_approval(key(&id(1)), "/host".to_owned(), true)
        .await
        .unwrap();
    mini.sync().await;

    assert_eq!(held, None);
    assert_eq!(waiting.len(), 1);
    assert_eq!(waiting[0].field, "/host");
    assert_eq!(waiting[0].pulled, json!("db.example.com"));
    assert_eq!(waiting[0].current, None);
    assert_eq!(status.waiting_approvals, 1);
    assert_eq!(mini.connections.get(&id(1)), Some(prod.clone()));
    assert!(mini.rows(RowRange::Table(Table::Held)).await.is_empty());
    assert_eq!(mini.sync.status().waiting_approvals, 0);
    assert_eq!(stored(&server, "connection", &id(1)), Some(prod));
}

#[tokio::test]
async fn a_pulled_host_change_waits_and_the_device_never_pushes_its_own_back_over_it() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mini.connections
        .put(&id(1), json!({"name": "Prod", "host": "db.internal"}));
    mini.sync().await;
    mac.sync().await;
    mac.sync
        .decide_approval(key(&id(1)), "/host".to_owned(), true)
        .await
        .unwrap();

    mac.connections
        .put(&id(1), json!({"name": "Prod 2", "host": "elsewhere.example.com"}));
    mac.sync().await;
    mini.sync().await;
    let waited = mini.connections.get(&id(1));
    mini.connections
        .put(&id(1), json!({"name": "Prod 3", "host": "db.internal"}));
    mini.sync().await;

    assert_eq!(waited, Some(json!({"name": "Prod 2", "host": "db.internal"})));
    assert_eq!(
        stored(&server, "connection", &id(1)),
        Some(json!({"name": "Prod 3", "host": "elsewhere.example.com"}))
    );
    let waiting = mini.sync.approvals().await.unwrap();
    assert_eq!(waiting.len(), 1);
    assert_eq!(waiting[0].current, Some(json!("db.internal")));
}

#[tokio::test]
async fn a_rejection_keeps_the_device_s_value_and_a_newer_pulled_value_asks_again() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mini.connections
        .put(&id(1), json!({"name": "Prod", "startup_commands": "SET a = 1"}));
    mini.sync().await;
    mac.sync().await;
    mac.sync
        .decide_approval(key(&id(1)), "/startup_commands".to_owned(), true)
        .await
        .unwrap();
    mac.connections
        .put(&id(1), json!({"name": "Prod", "startup_commands": "DROP TABLE users"}));
    mac.sync().await;
    mini.sync().await;

    mini.sync
        .decide_approval(key(&id(1)), "/startup_commands".to_owned(), false)
        .await
        .unwrap();
    mini.sync().await;
    let kept = mini.connections.get(&id(1));
    let asked_after_rejecting = mini.sync.approvals().await.unwrap().len();
    mac.connections
        .put(&id(1), json!({"name": "Prod", "startup_commands": "SET b = 2"}));
    mac.sync().await;
    mini.sync().await;

    assert_eq!(kept, Some(json!({"name": "Prod", "startup_commands": "SET a = 1"})));
    assert_eq!(asked_after_rejecting, 0);
    assert_eq!(
        stored(&server, "connection", &id(1)),
        Some(json!({"name": "Prod", "startup_commands": "SET b = 2"}))
    );
    let waiting = mini.sync.approvals().await.unwrap();
    assert_eq!(waiting.len(), 1);
    assert_eq!(waiting[0].pulled, json!("SET b = 2"));
}

// The device's copy turns unreadable while a pulled value waits: no decision lands, and the row waits for the person.
#[tokio::test]
async fn a_decision_on_a_record_the_store_cannot_read_keeps_the_approval_waiting() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mini.connections
        .put(&id(1), json!({"name": "Prod", "startup_commands": "SET a = 1"}));
    mini.sync().await;
    mac.sync().await;
    mac.sync
        .decide_approval(key(&id(1)), "/startup_commands".to_owned(), true)
        .await
        .unwrap();
    mac.connections
        .put(&id(1), json!({"name": "Prod", "startup_commands": "DROP TABLE users"}));
    mac.sync().await;
    mini.sync().await;
    mini.connections.make_unreadable(&id(1));

    let rejected = mini
        .sync
        .decide_approval(key(&id(1)), "/startup_commands".to_owned(), false)
        .await;
    let approved = mini
        .sync
        .decide_approval(key(&id(1)), "/startup_commands".to_owned(), true)
        .await;

    assert_eq!(rejected.unwrap_err().code(), "sync.adapter.unreadable");
    assert_eq!(approved.unwrap_err().code(), "sync.adapter.unreadable");
    assert_eq!(mini.sync.approvals().await.unwrap().len(), 1);
}

// A connection new to the device waits whole while a copy the store cannot read takes its id, as a restored file
// can: approving it writes nothing over that copy, and a decision a crash left unapplied is not replayed over it.
#[tokio::test]
async fn a_held_record_never_goes_in_over_a_copy_the_store_cannot_read() {
    use tablepro_sync::api::state::ApprovalDecision;
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mac.connections
        .put(&id(1), json!({"name": "Prod", "host": "db.example.com"}));
    mac.sync().await;
    mini.sync().await;
    mini.connections.make_unreadable(&id(1));

    let approved = mini.sync.decide_approval(key(&id(1)), "/host".to_owned(), true).await;
    let Some(Row::Approval(mut row)) = mini.row(RowKey::Approval(key(&id(1)), "/host".to_owned())).await else {
        panic!("the approval row went");
    };
    row.decision = ApprovalDecision::Approved;
    let mut txn = mini.state.begin().await.unwrap();
    txn.put(Row::Approval(row)).await.unwrap();
    txn.commit().await.unwrap();
    mini.sync().await;

    assert_eq!(approved.unwrap_err().code(), "sync.adapter.unreadable");
    assert_eq!(mini.connections.get(&id(1)), None);
    assert!(mini.row(RowKey::Held(key(&id(1)))).await.is_some());
    assert!(
        mini.row(RowKey::Approval(key(&id(1)), "/host".to_owned()))
            .await
            .is_some()
    );
}

// The store cannot keep one pulled value: that record is held by id with the server's copy, the pass goes on and says
// so on every pass it stays held, a later change of another record still lands, and the held one goes in once the
// store takes it, with no change on the server.
#[tokio::test]
async fn a_value_the_store_refuses_is_held_and_the_pass_goes_on() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mini.connections.refuse_value(&id(1), true);
    mac.connections.put(&id(1), json!({"name": "Prod"}));
    mac.connections.put(&id(2), json!({"name": "Stage"}));
    mac.sync().await;

    let report = mini.pass().await.unwrap();
    let problem = mini.sync.status().problem;
    let held = mini.row(RowKey::Held(key(&id(1)))).await;
    mac.connections.put(&id(2), json!({"name": "Stage 2"}));
    mac.sync().await;
    mini.sync().await;
    let later = mini.connections.get(&id(2));
    let still = mini.sync.status().problem;
    mini.connections.refuse_value(&id(1), false);
    mini.sync().await;

    assert_eq!(report.store_refused, vec![key(&id(1))]);
    assert_eq!(problem, Some("sync.adapter.unreadable"));
    let Some(Row::Held(held)) = held else {
        panic!("the refused record is not held");
    };
    assert_eq!(held.reason, HeldReason::Unreadable);
    assert_eq!(held.record.fields, Some(json!({"name": "Prod"})));
    assert_eq!(later, Some(json!({"name": "Stage 2"})));
    assert_eq!(still, Some("sync.adapter.unreadable"));
    assert_eq!(mini.connections.get(&id(1)), Some(json!({"name": "Prod"})));
    assert!(mini.row(RowKey::Held(key(&id(1)))).await.is_none());
    assert_eq!(mini.sync.status().problem, None);
}

// A saved query of a connection that stays on the device: its deletion waits while the connection is Local only, and
// goes up once the connection syncs again (0054, Rules for both providers).
#[tokio::test]
async fn a_saved_query_deletion_waits_while_its_connection_stays_on_the_device() {
    let server = FakeServer::new();
    let queries = MemoryAdapter::new(Kind::SavedQuery, "queries", StoreFile::new());
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .adapter(ScopeName::Personal, Arc::clone(&queries))
        .build()
        .await;
    let connection = id(9);
    mac.connections.put(&connection, json!({"name": "Prod"}));
    queries.put(
        &id(1),
        json!({"name": "Revenue", "query": "SELECT 1", "connection_id": connection}),
    );
    mac.sync().await;
    let pushed = stored(&server, Kind::SavedQuery.as_str(), &id(1)).is_some();
    mac.connections.put_local_only(&connection, json!({"name": "Prod"}));
    queries.remove(&id(1));
    mac.sync().await;
    let held = stored(&server, Kind::SavedQuery.as_str(), &id(1)).is_some();
    mac.connections.put(&connection, json!({"name": "Prod"}));
    mac.sync().await;

    assert!(pushed);
    assert!(held);
    assert!(stored(&server, Kind::SavedQuery.as_str(), &id(1)).is_none());
}

#[tokio::test]
async fn a_value_the_device_already_holds_asks_nothing_on_its_first_pass() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    let prod = json!({"name": "Prod", "host": "db.example.com", "startup_commands": "SET a = 1"});
    mac.connections.put(&id(1), prod.clone());
    mac.sync().await;
    mini.connections.put(&id(1), prod.clone());

    mini.sync().await;

    assert!(mini.sync.approvals().await.unwrap().is_empty());
    assert_eq!(mini.connections.get(&id(1)), Some(prod));
}

#[tokio::test]
async fn the_ai_options_0061_names_wait_and_the_inert_ones_apply() {
    let server = FakeServer::new();
    let settings = |row: &str| {
        (
            row.to_owned(),
            MemoryAdapter::new(Kind::MacosSettings, "settings", StoreFile::new()),
        )
    };
    let (mac_row, mac_settings) = settings("dev_mac");
    let (mini_row, mini_settings) = settings("dev_mini");
    let mac = DeviceBuilder::new(&server, &mac_row)
        .adapter(ScopeName::Personal, Arc::clone(&mac_settings))
        .build()
        .await;
    let mini = DeviceBuilder::new(&server, &mini_row)
        .adapter(ScopeName::Personal, Arc::clone(&mini_settings))
        .build()
        .await;
    let ai = |options: Value| json!({"category": "ai", "options": options});
    let before = ai(json!({"chatMode": "ask", "maxToolRoundtrips": 5, "inlineSuggestionDebounceMs": 100}));
    mini_settings.put("ai", before.clone());
    mini.sync().await;
    mac_settings.put("ai", before);
    mac.sync().await;

    mac_settings.put(
        "ai",
        ai(json!({"chatMode": "agent", "maxToolRoundtrips": 50, "inlineSuggestionDebounceMs": 300})),
    );
    mac.sync().await;
    mini.sync().await;

    assert_eq!(
        mini_settings.get("ai"),
        Some(ai(
            json!({"chatMode": "ask", "maxToolRoundtrips": 5, "inlineSuggestionDebounceMs": 300})
        ))
    );
    let mut fields: Vec<String> = mini
        .sync
        .approvals()
        .await
        .unwrap()
        .into_iter()
        .map(|waiting| waiting.field)
        .collect();
    fields.sort();
    assert_eq!(fields, ["/options/chatMode", "/options/maxToolRoundtrips"]);
}

fn team() -> TeamId {
    TeamId(Uuid::from_u128(0x0191_0000_0000_7000_8000_0000_0000_00AA))
}

async fn team_devices(server: &std::sync::Arc<FakeServer>) -> (Device, Arc<MemoryAdapter>, Device, Arc<MemoryAdapter>) {
    server.add_team(team(), &[(account(), Role::Owner)]);
    let scope = ScopeName::Team(team());
    let mac_queries = MemoryAdapter::new(Kind::LibraryQuery, "team_library", StoreFile::new());
    let mini_queries = MemoryAdapter::new(Kind::LibraryQuery, "team_library", StoreFile::new());
    let mac = DeviceBuilder::new(server, "dev_mac")
        .adapter(scope, Arc::clone(&mac_queries))
        .build()
        .await;
    let mini = DeviceBuilder::new(server, "dev_mini")
        .adapter(scope, Arc::clone(&mini_queries))
        .build()
        .await;
    (mac, mac_queries, mini, mini_queries)
}

fn query(name: &str, sql: &str) -> Value {
    json!({"name": name, "query": sql, "sort_order": 1})
}

#[tokio::test]
async fn a_team_member_both_sides_changed_waits_for_keep_mine_and_decide_later_keeps_both() {
    let server = FakeServer::new();
    let (mac, mac_queries, mini, mini_queries) = team_devices(&server).await;
    mac_queries.put("q1", query("Report", "select 1"));
    mac.sync().await;
    mini.sync().await;

    mac_queries.put("q1", query("Report mac", "select 1"));
    mini_queries.put("q1", query("Report mini", "select 2"));
    mac.sync().await;
    mini.sync().await;
    let open = mini.sync.conflicts().await.unwrap();
    let held = mini_queries.get("q1");
    // Decide Later: another pull of the record keeps the conflict and the device's side.
    mac_queries.put("q1", query("Report mac 2", "select 1"));
    mac.sync().await;
    mini.sync().await;
    let later = mini.sync.conflicts().await.unwrap();
    let team_owner = ScopeOwner::Team(team());
    let before = server.stored(team_owner, "library_query", "q1").unwrap().fields;
    mini.sync
        .resolve_conflict(later[0].key.clone(), ConflictChoice::KeepMine)
        .await
        .unwrap();
    mini.sync().await;
    mac.sync().await;

    assert_eq!(open.len(), 1);
    assert_eq!(open[0].fields, ["name"]);
    assert_eq!(held, Some(query("Report mac", "select 2")));
    assert_eq!(later.len(), 1);
    assert_eq!(later[0].theirs, Some(query("Report mac 2", "select 1")));
    assert_eq!(
        later[0].mine.as_ref().and_then(|mine| mine.get("name")),
        Some(&json!("Report mini"))
    );
    assert_eq!(before, Some(query("Report mac 2", "select 1")));
    assert_eq!(
        server.stored(team_owner, "library_query", "q1").unwrap().fields,
        Some(query("Report mini", "select 2"))
    );
    assert_eq!(mac_queries.get("q1"), Some(query("Report mini", "select 2")));
    assert!(mini.sync.conflicts().await.unwrap().is_empty());
}

#[tokio::test]
async fn keep_theirs_takes_the_server_s_copy_and_sends_nothing() {
    let server = FakeServer::new();
    let (mac, mac_queries, mini, mini_queries) = team_devices(&server).await;
    mac_queries.put("q1", query("Report", "select 1"));
    mac.sync().await;
    mini.sync().await;
    mac_queries.put("q1", query("Theirs", "select 1"));
    mini_queries.put("q1", query("Mine", "select 1"));
    mac.sync().await;
    mini.sync().await;
    let key = RecordKey::new(ScopeName::Team(team()), Kind::LibraryQuery, "q1");

    mini.sync
        .resolve_conflict(key, ConflictChoice::KeepTheirs)
        .await
        .unwrap();
    let report = mini.sync().await;

    assert_eq!(report.pushed, 0);
    assert_eq!(mini_queries.get("q1"), Some(query("Theirs", "select 1")));
    assert!(mini.sync.conflicts().await.unwrap().is_empty());
}

// A store with no place for members the group model does not name, as the core's group store.
struct GroupStore(Arc<MemoryAdapter>);

#[async_trait]
impl RecordAdapter for GroupStore {
    fn kind(&self) -> Kind {
        Kind::Group
    }

    fn store(&self) -> &str {
        self.0.store()
    }

    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        self.0.identity().await
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        self.0.records(scope).await
    }

    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        let kept = changes
            .into_iter()
            .map(|change| match change {
                LocalChange::Put { record_id, fields } => LocalChange::Put {
                    record_id,
                    fields: json!({"name": fields["name"], "sort_order": fields["sort_order"]}),
                },
                delete => delete,
            })
            .collect();
        self.0.apply(scope, kept).await
    }

    async fn tombstones_pushed(&self, scope: ScopeName, record_ids: Vec<String>) -> Result<(), AdapterError> {
        self.0.tombstones_pushed(scope, record_ids).await
    }
}

#[tokio::test]
async fn a_member_the_store_has_no_place_for_is_kept_on_the_server_through_an_edit() {
    let server = FakeServer::new();
    let groups = MemoryAdapter::new(Kind::Group, "connections", StoreFile::new());
    groups.register(ScopeName::Personal);
    let store = Arc::new(GroupStore(Arc::clone(&groups)));
    let mac = Device::new(&server, "dev_mac").await;
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .extra_adapter(store)
        .build()
        .await;
    mac.push_raw(
        ScopeName::Personal,
        vec![write(
            "group",
            &id(1),
            None,
            json!({"name": "Prod", "sort_order": 1, "schema_version": 3, "future": {"x": 1}}),
        )],
    )
    .await;

    mini.sync().await;
    groups.put(&id(1), json!({"name": "Prod 2", "sort_order": 1}));
    let report = mini.sync().await;

    assert_eq!(report.pushed, 1);
    assert_eq!(
        stored(&server, "group", &id(1)),
        Some(json!({"name": "Prod 2", "sort_order": 1, "schema_version": 3, "future": {"x": 1}}))
    );
}

#[tokio::test]
async fn an_off_kind_sends_nothing_and_a_deletion_pulled_meanwhile_lands_once_it_is_on() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    let named = |name: &str| json!({"name": name, "sort_order": 1});
    mac.connections.put(&id(1), named("Kept"));
    mac.connections.put(&id(2), named("Deleted"));
    mac.sync().await;
    mini.sync().await;
    let off = SyncCategories {
        off: vec![KindName::of(Kind::Connection)],
        passwords: true,
    };

    mini.sync.set_categories(off).await.unwrap();
    mini.connections.put(&id(1), named("Edited while off"));
    mac.connections.remove(&id(2));
    mac.sync().await;
    let report = mini.sync().await;
    let during = (mini.connections.get(&id(2)), stored(&server, "connection", &id(1)));
    mini.sync
        .set_categories(SyncCategories {
            off: Vec::new(),
            passwords: true,
        })
        .await
        .unwrap();
    mini.sync().await;

    assert_eq!(report.pushed, 0);
    assert_eq!(during, (Some(named("Deleted")), Some(named("Kept"))));
    assert_eq!(mini.connections.get(&id(2)), None);
    assert_eq!(stored(&server, "connection", &id(1)), Some(named("Edited while off")));
}

#[tokio::test]
async fn the_host_s_journal_call_sends_what_it_names() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.sync().await;
    mac.connections.put(&id(1), json!({"name": "Named"}));
    mac.connections.put(&id(2), json!({"name": "Not named"}));

    mac.sync
        .host_changed(KindName::of(Kind::Connection), vec![id(1)], Vec::new())
        .await
        .unwrap();
    let journal = mac.sync.run_pass(PassReason::Journal).await.unwrap();
    let unknown = mac
        .sync
        .host_changed(KindName::parse("future_kind").unwrap(), vec![id(3)], Vec::new())
        .await;

    assert_eq!(journal.pushed, 1);
    assert_eq!(stored(&server, "connection", &id(1)), Some(json!({"name": "Named"})));
    assert_eq!(stored(&server, "connection", &id(2)), None);
    assert_eq!(unknown, Err(SyncError::Unknown { what: "kind" }));
}

fn entry(n: u8) -> String {
    Uuid::from_u128(0x6F1C_2A9E_0B4D_4C8E_9A51_3D7E_2B1F_0C00 + u128::from(n))
        .hyphenated()
        .to_string()
        .to_uppercase()
}

fn ran(n: u8) -> Value {
    json!({"query": format!("select {n}"), "executed_at": i64::from(n), "succeeded": true})
}

async fn history_device(server: &Arc<FakeServer>, row: &str) -> (Device, Arc<MemoryAdapter>) {
    let entries = MemoryAdapter::new(Kind::HistoryEntry, "history.db", StoreFile::new());
    let device = DeviceBuilder::new(server, row)
        .adapter(ScopeName::History, Arc::clone(&entries))
        .build()
        .await;
    let version = format!("{ACCOUNT}/history/1");
    device
        .push_raw(
            ScopeName::Personal,
            vec![write("key.version", &version, None, json!({"suite": "tp1"}))],
        )
        .await;
    (device, entries)
}

#[tokio::test]
async fn a_history_entry_goes_up_sealed_and_comes_down_as_its_plaintext() {
    let server = FakeServer::new();
    let (mac, mac_entries) = history_device(&server, "dev_mac").await;
    let (mini, mini_entries) = history_device(&server, "dev_mini").await;
    mac_entries.put(&entry(1), ran(1));

    mac.sync().await;
    mini.sync().await;

    let sealed = server
        .stored(ScopeOwner::History(account()), "history_entry", &entry(1))
        .unwrap()
        .fields
        .unwrap();
    assert_eq!(sealed["kv"], json!(1));
    assert!(sealed.get("query").is_none());
    assert_eq!(mini_entries.get(&entry(1)), Some(ran(1)));
}

#[tokio::test]
async fn a_history_snapshot_takes_the_window_newest_first_and_pages_back_on_demand() {
    let server = FakeServer::new();
    let (mac, mac_entries) = history_device(&server, "dev_mac").await;
    for n in 1..=5 {
        mac_entries.put(&entry(n), ran(n));
        mac.sync().await;
    }
    let mini_entries = MemoryAdapter::new(Kind::HistoryEntry, "history.db", StoreFile::new());
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .adapter(ScopeName::History, Arc::clone(&mini_entries))
        .build()
        .await;
    mini.sync.set_history_window(Some(1));

    mini.sync().await;
    let window: Vec<bool> = (1..=5).map(|n| mini_entries.get(&entry(n)).is_some()).collect();
    let mut pages = Vec::new();
    loop {
        let more = mini.sync.load_older_history().await.unwrap();
        pages.push(more);
        if !more {
            break;
        }
    }

    assert_eq!(window, [false, false, false, false, true]);
    assert!((1..=5).all(|n| mini_entries.get(&entry(n)).is_some()));
    assert_eq!(pages.last(), Some(&false));
    assert!(!mini.sync.load_older_history().await.unwrap());
}

#[tokio::test]
async fn history_kept_through_a_policy_goes_up_again_and_a_deleted_entry_stays_deleted() {
    let server = FakeServer::new();
    let (mac, entries) = history_device(&server, "dev_mac").await;
    entries.put(&entry(1), ran(1));
    entries.put(&entry(2), ran(2));
    mac.sync().await;
    entries.delete_entry(&entry(2));
    mac.sync().await;

    server.set_policies(Policies {
        history_sync: false,
        ..Policies::default()
    });
    mac.sync().await;
    let kept = entries.get(&entry(1));
    server.set_policies(Policies::default());
    mac.sync().await;

    let history = |n: u8| server.stored(ScopeOwner::History(account()), "history_entry", &entry(n));
    assert_eq!(kept, Some(ran(1)));
    assert_eq!(history(1).unwrap().deleted, None);
    assert_eq!(history(2).unwrap().deleted, Some(DeletedReason::User));
    assert!(
        mac.row(RowKey::DeletedHistory(entry(2))).await.is_some(),
        "the deleted id is kept"
    );
}

#[tokio::test]
async fn a_held_record_awaiting_approval_is_not_deleted_by_the_diff() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mac.connections
        .put(&id(1), json!({"name": "Prod", "host": "db.example.com"}));
    mac.sync().await;

    mini.sync().await;
    mini.sync().await;

    let held = mini.rows(RowRange::Table(Table::Held)).await;
    assert!(matches!(&held[..], [Row::Held(row)] if row.reason == HeldReason::AwaitingApproval));
    assert_eq!(server.stored(personal(), "connection", &id(1)).unwrap().deleted, None);
}

// The hook a pull that settles inside one state transaction calls, as the CloudKit fetch does, before it plans the
// store's copy.
#[tokio::test]
async fn the_approval_gate_holds_a_new_record_and_splits_a_known_one_in_the_caller_s_transaction() {
    use tablepro_records::merge::Merged;
    use tablepro_sync::adapters::approval::{Gated, gate};
    use tablepro_sync::api::state::StateFiles;

    let state = tablepro_sync_testing::MemoryStateFiles::new()
        .open(super::harness::identity("dev_mac"))
        .await
        .unwrap();
    let mut txn = state.begin().await.unwrap();
    let merged = json!({"name": "Prod 2", "host": "elsewhere"});

    let new = gate(
        txn.as_mut(),
        &key(&id(1)),
        Kind::Connection,
        None,
        Merged::Record(merged.clone()),
    )
    .await
    .unwrap();
    let known = gate(
        txn.as_mut(),
        &key(&id(2)),
        Kind::Connection,
        Some(&json!({"name": "Prod", "host": "db"})),
        Merged::Record(merged.clone()),
    )
    .await
    .unwrap();
    let deleted = gate(txn.as_mut(), &key(&id(2)), Kind::Connection, None, Merged::Deleted)
        .await
        .unwrap();
    let rows = txn.scan(&RowRange::Table(Table::Approvals)).await.unwrap();

    assert_eq!(new, Gated::Hold);
    assert_eq!(
        known,
        Gated::Apply(Merged::Record(json!({"name": "Prod 2", "host": "db"})))
    );
    assert_eq!(deleted, Gated::Apply(Merged::Deleted));
    assert!(matches!(&rows[..], [Row::Approval(row)] if row.key == key(&id(1))));
}

#[tokio::test]
async fn a_record_the_person_deletes_here_leaves_nothing_to_approve() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mini.connections.put(&id(1), json!({"name": "Prod", "host": "a"}));
    mini.sync().await;
    mac.sync().await;
    mac.sync
        .decide_approval(key(&id(1)), "/host".to_owned(), true)
        .await
        .unwrap();
    mac.connections.put(&id(1), json!({"name": "Prod", "host": "b"}));
    mac.sync().await;
    mini.sync().await;
    let waiting = mini.sync.approvals().await.unwrap().len();

    mini.connections.remove(&id(1));
    mini.sync().await;

    assert_eq!(waiting, 1);
    assert!(mini.rows(RowRange::Table(Table::Approvals)).await.is_empty());
    assert_eq!(
        server.stored(personal(), "connection", &id(1)).unwrap().deleted,
        Some(DeletedReason::User)
    );
}

#[tokio::test]
async fn a_snapshot_that_serves_a_waiting_record_again_keeps_it_waiting() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mac.connections
        .put(&id(1), json!({"name": "Prod", "host": "db.example.com"}));
    mac.sync().await;
    mini.sync().await;

    mini.wire.expire_next_cursor();
    mini.sync().await;
    mini.sync().await;

    let held = mini.rows(RowRange::Table(Table::Held)).await;
    assert!(matches!(&held[..], [Row::Held(row)] if row.reason == HeldReason::AwaitingApproval));
    assert_eq!(server.stored(personal(), "connection", &id(1)).unwrap().deleted, None);
}

#[tokio::test]
async fn a_record_waiting_whole_stays_held_through_a_placement_edit_and_a_refusal() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mac.connections
        .put(&id(1), json!({"name": "Prod", "host": "db", "sort_order": 1}));
    mac.sync().await;
    mini.sync().await;

    mac.connections
        .put(&id(1), json!({"name": "Prod", "host": "db", "sort_order": 7}));
    mac.sync().await;
    mini.sync().await;
    mini.sync
        .decide_approval(key(&id(1)), "/host".to_owned(), false)
        .await
        .unwrap();
    mini.sync().await;

    let stored = server.stored(personal(), "connection", &id(1)).unwrap();
    assert_eq!(stored.deleted, None);
    assert_eq!(
        stored.fields,
        Some(json!({"name": "Prod", "host": "db", "sort_order": 7}))
    );
    assert_eq!(mini.connections.get(&id(1)), None);
    let held = mini.rows(RowRange::Table(Table::Held)).await;
    assert!(matches!(&held[..], [Row::Held(row)] if row.reason == HeldReason::AwaitingApproval));
}

#[tokio::test]
async fn a_restored_store_whose_kind_was_off_lets_the_pull_win_once_the_kind_is_on() {
    let server = FakeServer::new();
    let file = StoreFile::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .connections(
            MemoryAdapter::new(Kind::Connection, "connections", Arc::clone(&file)),
            Arc::clone(&file),
        )
        .build()
        .await;
    let named = |name: &str| json!({"name": name, "sort_order": 1});
    mac.connections.put(&id(1), named("Old"));
    mac.sync().await;
    mini.sync().await;
    mac.connections.put(&id(1), named("New"));
    mac.sync().await;
    mini.sync().await;
    let off = |off: bool| SyncCategories {
        off: if off {
            vec![KindName::of(Kind::Connection)]
        } else {
            Vec::new()
        },
        passwords: true,
    };

    mini.sync.set_categories(off(true)).await.unwrap();
    // A backup from before the rename comes back while connections are off.
    mini.connections.put(&id(1), named("Old"));
    file.restored();
    mini.sync().await;
    mini.sync.set_categories(off(false)).await.unwrap();
    mini.sync().await;

    assert_eq!(mini.connections.get(&id(1)), Some(named("New")));
    assert_eq!(stored(&server, "connection", &id(1)), Some(named("New")));
}

#[tokio::test]
async fn a_conflict_a_teammate_settles_to_the_device_s_values_leaves_them_in_the_store() {
    let server = FakeServer::new();
    let (mac, mac_queries, mini, mini_queries) = team_devices(&server).await;
    mac_queries.put("q1", query("Report", "select 1"));
    mac.sync().await;
    mini.sync().await;
    mac_queries.put("q1", query("Theirs", "select 1"));
    mini_queries.put("q1", query("Mine", "select 1"));
    mac.sync().await;
    mini.sync().await;

    mac_queries.put("q1", query("Mine", "select 1"));
    mac.sync().await;
    mini.sync().await;
    mac.sync().await;

    assert!(mini.sync.conflicts().await.unwrap().is_empty());
    assert_eq!(mini_queries.get("q1"), Some(query("Mine", "select 1")));
    assert_eq!(
        server
            .stored(ScopeOwner::Team(team()), "library_query", "q1")
            .unwrap()
            .fields,
        Some(query("Mine", "select 1"))
    );
}

#[tokio::test]
async fn keep_mine_against_a_deletion_sends_the_device_s_own_host_never_the_one_waiting() {
    let server = FakeServer::new();
    server.add_team(team(), &[(account(), Role::Owner)]);
    let scope = ScopeName::Team(team());
    let library = |row: &str| {
        (
            row.to_owned(),
            MemoryAdapter::new(Kind::LibraryConnection, "team_library", StoreFile::new()),
        )
    };
    let (mac_row, mac_items) = library("dev_mac");
    let (mini_row, mini_items) = library("dev_mini");
    let mac = DeviceBuilder::new(&server, &mac_row)
        .adapter(scope, Arc::clone(&mac_items))
        .build()
        .await;
    let mini = DeviceBuilder::new(&server, &mini_row)
        .adapter(scope, Arc::clone(&mini_items))
        .build()
        .await;
    let item = |name: &str, host: &str| json!({"name": name, "host": host});
    let lib_key = RecordKey::new(scope, Kind::LibraryConnection, "c1");
    mac_items.put("c1", item("Prod", "a"));
    mac.sync().await;
    mini.sync().await;
    mini.sync
        .decide_approval(lib_key.clone(), "/host".to_owned(), true)
        .await
        .unwrap();
    mac_items.put("c1", item("Prod", "evil"));
    mac.sync().await;
    mini.sync().await;

    mini_items.put("c1", item("Prod renamed", "a"));
    mac_items.remove("c1");
    mac.sync().await;
    mini.sync().await;
    let open = mini.sync.conflicts().await.unwrap();
    mini.sync
        .resolve_conflict(lib_key, ConflictChoice::KeepMine)
        .await
        .unwrap();
    mini.sync().await;

    assert_eq!(open.len(), 1);
    assert_eq!(open[0].mine, Some(item("Prod renamed", "a")));
    assert_eq!(mini_items.get("c1"), Some(item("Prod renamed", "a")));
    let revived = server
        .stored(ScopeOwner::Team(team()), "library_connection", "c1")
        .unwrap();
    assert_eq!(revived.deleted, None);
    assert_eq!(revived.fields, Some(item("Prod renamed", "a")));
}

#[tokio::test]
async fn a_policy_revival_sends_the_device_s_own_value_of_a_member_still_waiting() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mini.connections.put(&id(1), json!({"name": "Prod", "host": "a"}));
    mini.sync().await;
    mac.sync().await;
    mac.sync
        .decide_approval(key(&id(1)), "/host".to_owned(), true)
        .await
        .unwrap();
    mac.connections.put(&id(1), json!({"name": "Prod", "host": "b"}));
    mac.sync().await;
    mini.sync().await;

    server.set_policies(Policies {
        personal_sync: false,
        ..Policies::default()
    });
    mini.sync().await;
    server.set_policies(Policies::default());
    mini.sync().await;

    assert_eq!(
        stored(&server, "connection", &id(1)),
        Some(json!({"name": "Prod", "host": "a"}))
    );
}

#[tokio::test]
async fn an_edit_made_after_a_restore_while_the_kind_was_off_goes_up_and_the_rest_takes_the_server_s_copy() {
    let server = FakeServer::new();
    let file = StoreFile::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .connections(
            MemoryAdapter::new(Kind::Connection, "connections", Arc::clone(&file)),
            Arc::clone(&file),
        )
        .build()
        .await;
    let named = |name: &str| json!({"name": name, "sort_order": 1});
    mac.connections.put(&id(1), named("Old 1"));
    mac.connections.put(&id(2), named("Old 2"));
    mac.sync().await;
    mini.sync().await;
    mac.connections.put(&id(1), named("New 1"));
    mac.connections.put(&id(2), named("New 2"));
    mac.sync().await;
    mini.sync().await;
    let off = |off: bool| SyncCategories {
        off: if off {
            vec![KindName::of(Kind::Connection)]
        } else {
            Vec::new()
        },
        passwords: true,
    };

    mini.sync.set_categories(off(true)).await.unwrap();
    mini.connections.put(&id(1), named("Old 1"));
    mini.connections.put(&id(2), named("Old 2"));
    file.restored();
    mini.sync().await;
    mini.connections.put(&id(2), named("Edited after the restore"));
    mini.sync().await;
    mini.sync.set_categories(off(false)).await.unwrap();
    mini.sync().await;

    assert_eq!(mini.connections.get(&id(1)), Some(named("New 1")));
    assert_eq!(stored(&server, "connection", &id(1)), Some(named("New 1")));
    assert_eq!(
        stored(&server, "connection", &id(2)),
        Some(named("Edited after the restore"))
    );
}

#[tokio::test]
async fn keep_mine_never_sends_a_value_the_device_refused_as_its_own() {
    let server = FakeServer::new();
    server.add_team(team(), &[(account(), Role::Owner)]);
    let scope = ScopeName::Team(team());
    let items = |row: &str| {
        (
            row.to_owned(),
            MemoryAdapter::new(Kind::LibraryConnection, "team_library", StoreFile::new()),
        )
    };
    let (mac_row, mac_items) = items("dev_mac");
    let (mini_row, mini_items) = items("dev_mini");
    let mac = DeviceBuilder::new(&server, &mac_row)
        .adapter(scope, Arc::clone(&mac_items))
        .build()
        .await;
    let mini = DeviceBuilder::new(&server, &mini_row)
        .adapter(scope, Arc::clone(&mini_items))
        .build()
        .await;
    let item = |name: &str, host: &str| json!({"name": name, "host": host});
    let lib_key = RecordKey::new(scope, Kind::LibraryConnection, "c1");
    mac_items.put("c1", item("P", "a"));
    mac.sync().await;
    mini.sync().await;
    mini.sync
        .decide_approval(lib_key.clone(), "/host".to_owned(), true)
        .await
        .unwrap();
    mac_items.put("c1", item("P", "b"));
    mac.sync().await;
    mini.sync().await;
    mini.sync
        .decide_approval(lib_key.clone(), "/host".to_owned(), false)
        .await
        .unwrap();

    mini_items.put("c1", item("P mini", "a"));
    mac_items.put("c1", item("P mac", "c"));
    mac.sync().await;
    mini.sync().await;
    let open = mini.sync.conflicts().await.unwrap();
    mini.sync
        .resolve_conflict(lib_key, ConflictChoice::KeepMine)
        .await
        .unwrap();
    mini.sync().await;

    assert_eq!(open[0].fields, ["name"]);
    let team_copy = server
        .stored(ScopeOwner::Team(team()), "library_connection", "c1")
        .unwrap();
    assert_eq!(team_copy.fields, Some(item("P mini", "c")));
}
