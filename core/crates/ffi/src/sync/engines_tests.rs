use std::sync::Arc;
use std::time::{Duration, SystemTime};

use tablepro_records::Kind;
use tablepro_storage::saved_queries::SavedQuery;
use tablepro_storage::{ChangeJournal, QueryHistory, SavedQueryWrite, StoragePaths};
use tablepro_sync::adapters::library::Provider;
use tablepro_sync::adapters::settings::ConnectionStanding;
use tablepro_sync::adapters::store_journal::StoreJournal;
use tablepro_sync::api::state::Standing;
use tablepro_sync::api::{HostDeviceStore, RecordAdapter, StateFiles};
use tablepro_sync::engine::{Journal, Wake};
use tablepro_sync::state::SqliteStateFiles;
use tablepro_sync_testing::FakeDeviceStore;
use uuid::Uuid;

use super::Hosts;
use crate::sync::events::Signals;

struct Syncs;

impl ConnectionStanding for Syncs {
    fn standing(&self, _connection: Uuid) -> Standing {
        Standing::Syncs
    }
}

fn kinds(adapters: &[Arc<dyn RecordAdapter>]) -> Vec<Kind> {
    adapters.iter().map(|adapter| adapter.kind()).collect()
}

#[tokio::test]
async fn the_history_database_s_kinds_sync_its_writes_reach_the_engine_and_history_waits_for_the_standing() {
    let dir = tempfile::tempdir().unwrap();
    let history = QueryHistory::open(&StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro"))
        .await
        .unwrap();
    let store_journal = StoreJournal::new();
    history.set_journal(Some(Arc::clone(&store_journal) as Arc<dyn ChangeJournal>));
    let device_store = Arc::new(FakeDeviceStore::new());
    let hosts = |standing: Option<Arc<dyn ConnectionStanding>>| Hosts {
        files: Arc::new(SqliteStateFiles::at(
            dir.path().join("sync"),
            Arc::clone(&device_store) as Arc<dyn HostDeviceStore>,
        )) as Arc<dyn StateFiles>,
        device_store: Arc::clone(&device_store) as Arc<dyn HostDeviceStore>,
        settings: None,
        events: Arc::new(Signals::default()),
        library: None,
        names: tablepro_sync::adapters::library::DriverNames::Mac,
        history: Some(history.clone()),
        standing,
        store_journal: Arc::clone(&store_journal),
    };
    let journal = Journal::new(Wake::new());
    let id = Uuid::new_v4();

    let unknown = kinds(&hosts(None).adapters(&journal, Provider::TableproSync));
    let known = kinds(&hosts(Some(Arc::new(Syncs))).adapters(&journal, Provider::TableproSync));
    history
        .saved_queries()
        .write(&SavedQueryWrite {
            queries: vec![SavedQuery {
                id,
                name: "Daily".to_owned(),
                query: "SELECT 1".to_owned(),
                connection_id: None,
                connection_name: String::new(),
                keyword: None,
                folder_id: None,
                order: 0,
                created_at: SystemTime::UNIX_EPOCH + Duration::from_secs(1),
                updated_at: SystemTime::UNIX_EPOCH + Duration::from_secs(1),
            }],
            ..SavedQueryWrite::default()
        })
        .await
        .unwrap();

    assert_eq!(unknown, [Kind::SavedQuery, Kind::SavedQueryFolder]);
    assert_eq!(known, [Kind::SavedQuery, Kind::SavedQueryFolder, Kind::HistoryEntry]);
    let named = journal.take();
    assert!(named[&Kind::SavedQuery].contains(&id.hyphenated().to_string().to_uppercase()));
}

#[tokio::test]
async fn the_library_s_kinds_sync_with_its_standing_and_its_writes_reach_the_engine() {
    let dir = tempfile::tempdir().unwrap();
    let paths = StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro");
    let history = QueryHistory::open(&paths).await.unwrap();
    let store = tablepro_storage::ConnectionStore::new(&paths);
    let store_journal = StoreJournal::new();
    store.set_journal(Some(Arc::clone(&store_journal) as Arc<dyn ChangeJournal>));
    let device_store = Arc::new(FakeDeviceStore::new());
    let hosts = Hosts {
        files: Arc::new(SqliteStateFiles::at(
            dir.path().join("sync"),
            Arc::clone(&device_store) as Arc<dyn HostDeviceStore>,
        )) as Arc<dyn StateFiles>,
        device_store: Arc::clone(&device_store) as Arc<dyn HostDeviceStore>,
        settings: None,
        events: Arc::new(Signals::default()),
        library: Some(store.clone()),
        names: tablepro_sync::adapters::library::DriverNames::Core,
        history: Some(history),
        standing: Some(Arc::new(tablepro_sync::adapters::library::StoreStanding(store.clone()))),
        store_journal,
    };
    let journal = Journal::new(Wake::new());

    let found = kinds(&hosts.adapters(&journal, Provider::ICloud));
    let tag = store
        .create_tag_blocking(
            tablepro_storage::ConnectionTagName::new("prod").unwrap(),
            tablepro_storage::ConnectionColor::Red,
        )
        .unwrap();

    for kind in [
        Kind::Connection,
        Kind::Group,
        Kind::Tag,
        Kind::SshProfile,
        Kind::CredentialProfile,
        Kind::TableFolder,
        Kind::TableFolderItem,
        Kind::FavouriteTable,
        Kind::FavouriteDatabase,
        Kind::SavedQuery,
        Kind::HistoryEntry,
    ] {
        assert!(found.contains(&kind), "{kind:?} in {found:?}");
    }
    let named = journal.take();
    assert!(named[&Kind::Tag].contains(&tag.id.hyphenated().to_string().to_uppercase()));
}
