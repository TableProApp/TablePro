use std::sync::Arc;
use std::time::{Duration, SystemTime};

use tablepro_records::Kind;
use tablepro_storage::saved_queries::SavedQuery;
use tablepro_storage::{ChangeJournal, QueryHistory, SavedQueryDatabase, SavedQueryWrite, StoragePaths};
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
async fn the_query_stores_kinds_sync_their_writes_reach_the_engine_and_history_waits_for_the_standing() {
    let dir = tempfile::tempdir().unwrap();
    let paths = StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro");
    let history = QueryHistory::open(&paths).await.unwrap();
    let saved = SavedQueryDatabase::open(&paths).await.unwrap();
    let store_journal = StoreJournal::new();
    history.set_journal(Some(Arc::clone(&store_journal) as Arc<dyn ChangeJournal>));
    saved.set_journal(Some(Arc::clone(&store_journal) as Arc<dyn ChangeJournal>));
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
        publisher: None,
        history: Some(history.clone()),
        saved_queries: Some(saved.clone()),
        standing,
        store_journal: Arc::clone(&store_journal),
    };
    let journal = Journal::new(Wake::new());
    let id = Uuid::new_v4();

    let unknown = kinds(&hosts(None).adapters(Provider::TableproSync));
    let known = kinds(&hosts(Some(Arc::new(Syncs))).adapters(Provider::TableproSync));
    let _listening = hosts(None).listen(Arc::new(journal.clone()));
    saved
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
    let saved = SavedQueryDatabase::open(&paths).await.unwrap();
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
        publisher: None,
        history: Some(history),
        saved_queries: Some(saved),
        standing: Some(Arc::new(tablepro_sync::adapters::library::StoreStanding(store.clone()))),
        store_journal,
    };
    let journal = Journal::new(Wake::new());

    let found = kinds(&hosts.adapters(Provider::ICloud));
    let _listening = hosts.listen(Arc::new(journal.clone()));
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

// On iOS the history's file stays locked until the person unlocks the device, and saved queries still sync meanwhile.
#[tokio::test]
async fn saved_queries_sync_without_the_history() {
    let dir = tempfile::tempdir().unwrap();
    let paths = StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro");
    let saved = SavedQueryDatabase::open(&paths).await.unwrap();
    let device_store = Arc::new(FakeDeviceStore::new());
    let hosts = Hosts {
        files: Arc::new(SqliteStateFiles::at(
            dir.path().join("sync"),
            Arc::clone(&device_store) as Arc<dyn HostDeviceStore>,
        )) as Arc<dyn StateFiles>,
        device_store: Arc::clone(&device_store) as Arc<dyn HostDeviceStore>,
        settings: None,
        events: Arc::new(Signals::default()),
        library: None,
        names: tablepro_sync::adapters::library::DriverNames::Mac,
        publisher: None,
        history: None,
        saved_queries: Some(saved),
        standing: Some(Arc::new(Syncs)),
        store_journal: StoreJournal::new(),
    };

    let found = kinds(&hosts.adapters(Provider::ICloud));

    assert_eq!(found, [Kind::SavedQuery, Kind::SavedQueryFolder]);
    assert!(
        !paths.history_database().exists(),
        "the saved queries opened the history"
    );
}

// Each engine's journal hears the stores once and leaves with its engine, so an engine started again, or a provider
// switched, never leaves the old one listening.
#[tokio::test]
async fn an_engine_s_journal_hears_the_stores_once_and_leaves_with_its_engine() {
    let dir = tempfile::tempdir().unwrap();
    let paths = StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro");
    let history = QueryHistory::open(&paths).await.unwrap();
    let store_journal = StoreJournal::new();
    history.set_journal(Some(Arc::clone(&store_journal) as Arc<dyn ChangeJournal>));
    let device_store = Arc::new(FakeDeviceStore::new());
    let hosts = Hosts {
        files: Arc::new(SqliteStateFiles::at(
            dir.path().join("sync"),
            Arc::clone(&device_store) as Arc<dyn HostDeviceStore>,
        )) as Arc<dyn StateFiles>,
        device_store: Arc::clone(&device_store) as Arc<dyn HostDeviceStore>,
        settings: None,
        events: Arc::new(Signals::default()),
        library: None,
        names: tablepro_sync::adapters::library::DriverNames::Mac,
        publisher: None,
        history: Some(history),
        saved_queries: None,
        standing: Some(Arc::new(Syncs)),
        store_journal: Arc::clone(&store_journal),
    };
    let transport: Arc<dyn tablepro_sync::api::CloudKitTransport> =
        Arc::new(tablepro_sync_testing::FakeCloudKit::signed_in("_a"));
    let categories = tablepro_sync::api::control::SyncCategories::default();

    let first = super::IcloudEngine::start(&hosts, transport.clone(), &categories, None, None);
    let second = super::IcloudEngine::start(&hosts, transport, &categories, None, None);
    let both = store_journal.listeners();
    drop(first);
    let left = store_journal.listeners();
    drop(second);

    assert_eq!(both, 2);
    assert_eq!(left, 1);
    assert_eq!(store_journal.listeners(), 0);
}
