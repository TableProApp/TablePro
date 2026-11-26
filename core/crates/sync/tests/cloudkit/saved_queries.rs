// Saved queries on iCloud through their adapter over the core's store: a fetch that brings a second holder of a
// keyword settles it on the query created first, and the push sends the release, as the Swift engines'
// `SavedQueryKeywordResolver` did (0052, Collisions).

use std::sync::Arc;
use std::time::{Duration, SystemTime};

use serde_json::{Value, json};
use tablepro_records::Kind;
use tablepro_storage::saved_queries::SavedQuery;
use tablepro_storage::{QueryHistory, SavedQueryWrite, StoragePaths};
use tablepro_sync::adapters::saved_queries::SavedQueryAdapter;
use tablepro_sync::adapters::settings::ConnectionStanding;
use tablepro_sync::api::cloudkit::CloudKitTransport;
use tablepro_sync::api::control::PassReason;
use tablepro_sync::api::state::{Standing, StateFiles};
use tablepro_sync::cloudkit::fetch::Categories;
use tablepro_sync::cloudkit::modify::{CloudKitParts, CloudKitSync};
use tablepro_sync::engine::{Clock, Journal, StopSignal};
use uuid::Uuid;

use crate::support::{A, Rig};

const FIRST: &str = "E9BFE8BE-525F-4F8A-9E9C-F795A5F09A01";
const LATER: &str = "E9BFE8BE-525F-4F8A-9E9C-F795A5F09A02";
const OURS: &str = "E9BFE8BE-525F-4F8A-9E9C-F795A5F09A03";
const NEWER: &str = "E9BFE8BE-525F-4F8A-9E9C-F795A5F09A04";

fn mine(id: &str, name: &str, keyword: &str, created_ms: u64) -> SavedQuery {
    let at = SystemTime::UNIX_EPOCH + Duration::from_millis(created_ms);
    SavedQuery {
        id: Uuid::parse_str(id).unwrap(),
        name: name.to_owned(),
        query: format!("SELECT '{name}'"),
        connection_id: Some(Uuid::parse_str(A).unwrap()),
        connection_name: "shop".to_owned(),
        keyword: Some(keyword.to_owned()),
        folder_id: None,
        order: 0,
        created_at: at,
        updated_at: at,
    }
}

fn theirs(name: &str, keyword: &str, created_ms: i64) -> Value {
    json!({
        "name": name,
        "query": format!("SELECT '{name}'"),
        "keyword": keyword,
        "connection_id": A,
        "sort_order": 0,
        "created_at": created_ms,
        "updated_at": created_ms,
    })
}

struct Syncs;

impl ConnectionStanding for Syncs {
    fn standing(&self, _connection: Uuid) -> Standing {
        Standing::Syncs
    }
}

fn icloud(rig: &Rig, history: &QueryHistory) -> CloudKitSync {
    CloudKitSync::new(CloudKitParts {
        transport: Arc::clone(&rig.cloud) as Arc<dyn CloudKitTransport>,
        files: Arc::clone(&rig.files) as Arc<dyn StateFiles>,
        adapters: SavedQueryAdapter::all(history, Some(Arc::new(Syncs))),
        categories: Categories::new([Kind::SavedQuery, Kind::SavedQueryFolder]),
        clock: Arc::clone(&rig.clock) as Arc<dyn Clock>,
        stop: StopSignal::new(),
        journal: Journal::default(),
        events: None,
        last_account: None,
    })
}

async fn keyword(history: &QueryHistory, id: &str) -> Option<String> {
    let id = Uuid::parse_str(id).unwrap();
    history
        .saved_queries()
        .contents()
        .await
        .unwrap()
        .queries
        .into_iter()
        .find(|query| query.id == id)
        .and_then(|query| query.keyword)
}

#[tokio::test]
async fn a_fetched_holder_of_a_keyword_settles_it_on_the_query_created_first_and_the_push_sends_the_release() {
    let rig = Rig::new().await;
    let dir = tempfile::tempdir().unwrap();
    let history = QueryHistory::open(&StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro"))
        .await
        .unwrap();
    history
        .saved_queries()
        .write(&SavedQueryWrite {
            queries: vec![mine(LATER, "Revenue", "rev", 2_000), mine(OURS, "Costs", "cost", 1_000)],
            ..SavedQueryWrite::default()
        })
        .await
        .unwrap();
    let sync = icloud(&rig, &history);
    sync.run_pass(PassReason::Launch).await.unwrap();
    // Another device gives "rev" to a query created before this device's, and "cost" to one created after.
    rig.save_elsewhere(Kind::SavedQuery, FIRST, &theirs("Revenue report", "rev", 1_000));
    rig.save_elsewhere(Kind::SavedQuery, NEWER, &theirs("Costs report", "cost", 3_000));

    sync.run_pass(PassReason::CloudKitPush).await.unwrap();

    let zone = |id: &str| rig.zone_fields(Kind::SavedQuery, id).unwrap().get("keyword").cloned();
    assert_eq!(zone(FIRST), Some(json!("rev")));
    assert_eq!(zone(LATER), None, "this device let go of the keyword it held");
    assert_eq!(zone(OURS), Some(json!("cost")));
    assert_eq!(zone(NEWER), None, "the fetched query created later came in without it");
    assert_eq!(keyword(&history, FIRST).await.as_deref(), Some("rev"));
    assert_eq!(keyword(&history, LATER).await, None);
    assert_eq!(keyword(&history, OURS).await.as_deref(), Some("cost"));
    assert_eq!(keyword(&history, NEWER).await, None);
}
