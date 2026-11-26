use serde_json::json;
use tablepro_storage::StoragePaths;

use super::*;

const SHOP: &str = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";
const BLOG: &str = "E6C12C96-3CBD-4A0E-9F41-E36B47F35D84";
const REPORTS: &str = "380CB783-4B26-48F3-8F84-1468967A9FA3";

async fn history(dir: &std::path::Path) -> SavedQueryDatabase {
    SavedQueryDatabase::open(&StoragePaths::under(dir, "tablepro", "app.tablepro.TablePro"))
        .await
        .unwrap()
}

fn adapter(history: &SavedQueryDatabase, kind: Kind) -> Arc<dyn RecordAdapter> {
    SavedQueryAdapter::all(history, None)
        .into_iter()
        .find(|adapter| adapter.kind() == kind)
        .unwrap()
}

fn id(n: u8) -> String {
    format!("E9BFE8BE-525F-4F8A-9E9C-F795A5F09A{n:02X}")
}

fn pulled(name: &str, keyword: Option<&str>, connection: Option<&str>, created_at: i64) -> Value {
    let mut fields = json!({
        "name": name,
        "query": format!("SELECT '{name}'"),
        "sort_order": 3,
        "created_at": created_at,
        "updated_at": created_at + 500,
    });
    if let Some(keyword) = keyword {
        fields["keyword"] = json!(keyword);
    }
    if let Some(connection) = connection {
        fields["connection_id"] = json!(connection);
    }
    fields
}

fn put(record_id: &str, fields: Value) -> LocalChange {
    LocalChange::Put {
        record_id: record_id.to_owned(),
        fields,
    }
}

async fn fields_of(adapter: &Arc<dyn RecordAdapter>, record_id: &str) -> Option<Value> {
    adapter
        .records(ScopeName::Personal)
        .await
        .unwrap()
        .records
        .into_iter()
        .find(|record| record.record_id == record_id)
        .map(|record| record.fields)
}

#[tokio::test]
async fn a_pulled_query_and_folder_read_back_as_they_came() {
    let dir = tempfile::tempdir().unwrap();
    let history = history(dir.path()).await;
    let (queries, folders) = (
        adapter(&history, Kind::SavedQuery),
        adapter(&history, Kind::SavedQueryFolder),
    );
    let mut query = pulled("Daily", Some("daily"), Some(SHOP), 1_767_225_600_123);
    query["folder_id"] = json!(REPORTS);
    let folder = json!({
        "name": "Reports",
        "connection_id": SHOP,
        "parent_id": "0D3B6A1E-7C2F-4E9A-B5D8-1F4A6C8E2B90",
        "sort_order": 1,
        "created_at": 1_767_225_000_001_i64,
        "updated_at": 1_767_225_000_002_i64,
    });
    let everywhere = pulled("Everywhere", None, None, 1_000);

    let before = queries.identity().await.unwrap();
    // A query can arrive before its folder, and a folder before its parent.
    queries
        .apply(
            ScopeName::Personal,
            vec![put(&id(1), query.clone()), put(&id(2), everywhere.clone())],
        )
        .await
        .unwrap();
    let after = folders
        .apply(ScopeName::Personal, vec![put(REPORTS, folder.clone())])
        .await
        .unwrap();

    assert!(!after.needs_refill(before));
    assert_ne!(after, before);
    assert_eq!(fields_of(&queries, &id(1)).await, Some(query));
    assert_eq!(fields_of(&queries, &id(2)).await, Some(everywhere));
    assert_eq!(fields_of(&folders, REPORTS).await, Some(folder));
    assert!(queries.records(ScopeName::History).await.unwrap().records.is_empty());
    assert_eq!(queries.store(), folders.store());
}

#[tokio::test]
async fn a_pulled_change_keeps_the_connection_name_the_device_shows() {
    let dir = tempfile::tempdir().unwrap();
    let history = history(dir.path()).await;
    let queries = adapter(&history, Kind::SavedQuery);
    queries
        .apply(
            ScopeName::Personal,
            vec![put(&id(1), pulled("Daily", None, Some(SHOP), 1_000))],
        )
        .await
        .unwrap();
    show_connection_as(&history, "Shop on this Mac").await;

    queries
        .apply(
            ScopeName::Personal,
            vec![put(&id(1), pulled("Renamed", None, Some(SHOP), 1_000))],
        )
        .await
        .unwrap();

    let contents = history.saved_queries().contents().await.unwrap();
    assert_eq!(contents.queries[0].name, "Renamed");
    assert_eq!(contents.queries[0].connection_name, "Shop on this Mac");
}

// The name this device shows beside the query, which only its own writes set.
async fn show_connection_as(history: &SavedQueryDatabase, connection_name: &str) {
    let store = history.saved_queries();
    let mut query = store.contents().await.unwrap().queries.remove(0);
    query.connection_name = connection_name.to_owned();
    store
        .write(&SavedQueryWrite {
            queries: vec![query],
            ..SavedQueryWrite::default()
        })
        .await
        .unwrap();
}

#[tokio::test]
async fn a_pulled_holder_of_a_keyword_created_first_takes_it_and_the_local_one_lets_it_go() {
    let dir = tempfile::tempdir().unwrap();
    let history = history(dir.path()).await;
    let queries = adapter(&history, Kind::SavedQuery);
    queries
        .apply(
            ScopeName::Personal,
            vec![put(&id(1), pulled("Mine", Some("rev"), Some(SHOP), 2_000))],
        )
        .await
        .unwrap();

    queries
        .apply(
            ScopeName::Personal,
            vec![put(&id(2), pulled("Theirs", Some("rev"), Some(SHOP), 1_000))],
        )
        .await
        .unwrap();

    let mine = fields_of(&queries, &id(1)).await.unwrap();
    assert_eq!(mine.get("keyword"), None);
    assert!(
        mine["updated_at"].as_i64().unwrap() > 2_500,
        "the release is an edit of this device"
    );
    assert_eq!(fields_of(&queries, &id(2)).await.unwrap()["keyword"], json!("rev"));
}

#[tokio::test]
async fn a_pulled_query_created_later_comes_in_without_the_keyword_a_local_one_holds() {
    let dir = tempfile::tempdir().unwrap();
    let history = history(dir.path()).await;
    let queries = adapter(&history, Kind::SavedQuery);
    queries
        .apply(
            ScopeName::Personal,
            vec![put(&id(1), pulled("Mine", Some("rev"), Some(SHOP), 1_000))],
        )
        .await
        .unwrap();

    queries
        .apply(
            ScopeName::Personal,
            vec![put(&id(2), pulled("Theirs", Some("rev"), Some(SHOP), 2_000))],
        )
        .await
        .unwrap();

    assert_eq!(fields_of(&queries, &id(1)).await.unwrap()["keyword"], json!("rev"));
    assert_eq!(fields_of(&queries, &id(2)).await.unwrap().get("keyword"), None);
}

#[tokio::test]
async fn a_keyword_with_no_connection_meets_the_same_keyword_in_every_connection() {
    let dir = tempfile::tempdir().unwrap();
    let history = history(dir.path()).await;
    let queries = adapter(&history, Kind::SavedQuery);
    queries
        .apply(
            ScopeName::Personal,
            vec![
                put(&id(1), pulled("Shop", Some("rev"), Some(SHOP), 2_000)),
                put(&id(2), pulled("Blog", Some("rev"), Some(BLOG), 3_000)),
            ],
        )
        .await
        .unwrap();

    queries
        .apply(
            ScopeName::Personal,
            vec![put(&id(3), pulled("All", Some("rev"), None, 1_000))],
        )
        .await
        .unwrap();

    assert_eq!(fields_of(&queries, &id(3)).await.unwrap()["keyword"], json!("rev"));
    assert_eq!(fields_of(&queries, &id(1)).await.unwrap().get("keyword"), None);
    assert_eq!(fields_of(&queries, &id(2)).await.unwrap().get("keyword"), None);
}

#[tokio::test]
async fn a_pulled_deletion_removes_the_record_and_a_removed_folder_moves_no_query() {
    let dir = tempfile::tempdir().unwrap();
    let history = history(dir.path()).await;
    let (queries, folders) = (
        adapter(&history, Kind::SavedQuery),
        adapter(&history, Kind::SavedQueryFolder),
    );
    let mut filed = pulled("Filed", None, Some(SHOP), 1_000);
    filed["folder_id"] = json!(REPORTS);
    queries
        .apply(ScopeName::Personal, vec![put(&id(1), filed.clone())])
        .await
        .unwrap();
    folders
        .apply(
            ScopeName::Personal,
            vec![put(
                REPORTS,
                json!({"name": "Reports", "sort_order": 0, "created_at": 1, "updated_at": 1}),
            )],
        )
        .await
        .unwrap();

    folders
        .apply(
            ScopeName::Personal,
            vec![LocalChange::Delete {
                record_id: REPORTS.to_owned(),
            }],
        )
        .await
        .unwrap();

    assert_eq!(fields_of(&folders, REPORTS).await, None);
    assert_eq!(fields_of(&queries, &id(1)).await, Some(filed));
    queries
        .apply(ScopeName::Personal, vec![LocalChange::Delete { record_id: id(1) }])
        .await
        .unwrap();
    assert!(queries.records(ScopeName::Personal).await.unwrap().records.is_empty());
}

#[tokio::test]
async fn a_copy_the_store_cannot_hold_refuses_the_whole_write() {
    let dir = tempfile::tempdir().unwrap();
    let history = history(dir.path()).await;
    let queries = adapter(&history, Kind::SavedQuery);
    let good = put(&id(1), pulled("Good", None, None, 1_000));
    let mut lower_reference = pulled("Lower", None, None, 1_000);
    lower_reference["connection_id"] = json!(SHOP.to_lowercase());
    let mut nameless = pulled("Nameless", None, None, 1_000);
    nameless["name"] = json!("   ");
    let mut untyped = pulled("Untyped", None, None, 1_000);
    untyped["sort_order"] = json!("first");
    let refused = [
        put(&id(2).to_lowercase(), pulled("Lower id", None, None, 1_000)),
        put(&id(2), lower_reference),
        put(&id(2), json!({"query": "SELECT 1"})),
        put(&id(2), nameless),
        put(&id(2), untyped),
    ];

    for change in refused {
        let refusal = queries
            .apply(ScopeName::Personal, vec![good.clone(), change])
            .await
            .unwrap_err();
        assert_eq!(refusal.code(), "sync.adapter.unreadable", "{refusal}");
    }

    assert!(queries.records(ScopeName::Personal).await.unwrap().records.is_empty());
}

#[tokio::test]
async fn a_copy_with_no_times_takes_the_time_it_arrives() {
    let dir = tempfile::tempdir().unwrap();
    let history = history(dir.path()).await;
    let queries = adapter(&history, Kind::SavedQuery);
    let before = millis(SystemTime::now());

    queries
        .apply(
            ScopeName::Personal,
            vec![put(&id(1), json!({"name": "Old", "query": "SELECT 1"}))],
        )
        .await
        .unwrap();

    let fields = fields_of(&queries, &id(1)).await.unwrap();
    assert!(fields["created_at"].as_i64().unwrap() >= before);
    assert_eq!(fields["sort_order"], json!(0));
}

struct LocalOnly(Uuid);

impl ConnectionStanding for LocalOnly {
    fn standing(&self, connection: Uuid) -> Standing {
        if connection == self.0 {
            Standing::LocalOnly
        } else {
            Standing::Syncs
        }
    }
}

#[tokio::test]
async fn a_record_of_a_connection_that_does_not_sync_stays_and_one_of_no_connection_goes() {
    let dir = tempfile::tempdir().unwrap();
    let history = history(dir.path()).await;
    let blog = Uuid::parse_str(BLOG).unwrap();
    let standing = |connections: Option<Arc<dyn ConnectionStanding>>| {
        SavedQueryAdapter::all(&history, connections)
            .into_iter()
            .find(|adapter| adapter.kind() == Kind::SavedQuery)
            .unwrap()
    };
    let (known, unknown) = (standing(Some(Arc::new(LocalOnly(blog)))), standing(None));
    known
        .apply(
            ScopeName::Personal,
            vec![
                put(&id(1), pulled("Shop", None, Some(SHOP), 1_000)),
                put(&id(2), pulled("Blog", None, Some(BLOG), 1_000)),
                put(&id(3), pulled("Everywhere", None, None, 1_000)),
            ],
        )
        .await
        .unwrap();

    let read = |records: LocalRecords| {
        let mut out: Vec<(String, Standing)> = records
            .records
            .into_iter()
            .map(|record| (record.record_id, record.standing))
            .collect();
        out.sort_by(|left, right| left.0.cmp(&right.0));
        out
    };

    assert_eq!(
        read(known.records(ScopeName::Personal).await.unwrap()),
        [
            (id(1), Standing::Syncs),
            (id(2), Standing::LocalOnly),
            (id(3), Standing::Syncs)
        ]
    );
    assert_eq!(
        read(unknown.records(ScopeName::Personal).await.unwrap()),
        [
            (id(1), Standing::Unknown),
            (id(2), Standing::Unknown),
            (id(3), Standing::Syncs)
        ]
    );
}
