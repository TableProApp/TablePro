// The mirror over the adapters that exist: each kind plugs in through `RecordAdapter`. The settings adapter names a
// long category by its digest while the Swift engine marked the category itself, and the Team Library's kinds have
// no record type, so they never reach the Swift metadata.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::{Value, json};
use tablepro_records::Kind;
use tablepro_records::cloudkit::record_name;
use tablepro_records::record_id::{column_layout_category, shortened};
use tablepro_storage::{StoragePaths, TeamLibraryOwner, TeamLibraryStore};
use tablepro_sync::adapters::settings::SettingsAdapter;
use tablepro_sync::adapters::team_library::TeamLibraryAdapter;
use tablepro_sync::api::control::PassReason;
use tablepro_sync::api::legacy::LegacyMirror;
use tablepro_sync::api::state::StateFiles;
use tablepro_sync::api::{AdapterError, HostSettings, RecordAdapter, SettingsDocument};
use tablepro_sync::cloudkit::fetch::Categories;
use tablepro_sync::cloudkit::modify::{CloudKitParts, CloudKitSync};
use tablepro_sync::engine::{Clock, Journal, JournalEntry, StopSignal};
use tablepro_sync_testing::FakeLegacyMirror;
use uuid::Uuid;

use super::{dirty, marked, signed_in, transport};
use crate::support::{A, KINDS, Rig};

#[derive(Default)]
struct Host(Mutex<Vec<SettingsDocument>>);

#[async_trait]
impl HostSettings for Host {
    fn kind(&self) -> Kind {
        Kind::MacosSettings
    }

    async fn categories(&self) -> Result<Vec<SettingsDocument>, AdapterError> {
        Ok(self.0.lock().unwrap().clone())
    }

    async fn apply(&self, category: String, document: Option<Value>) -> Result<(), AdapterError> {
        let mut held = self.0.lock().unwrap();
        held.retain(|settings| settings.category != category);
        if let Some(document) = document {
            held.push(SettingsDocument { category, document });
        }
        Ok(())
    }
}

fn sync_over(rig: &Rig, adapters: Vec<Arc<dyn RecordAdapter>>, mirror: &Arc<FakeLegacyMirror>) -> CloudKitSync {
    CloudKitSync::new(CloudKitParts {
        transport: transport(rig),
        files: Arc::clone(&rig.files) as Arc<dyn StateFiles>,
        adapters,
        categories: Categories::new(KINDS),
        clock: Arc::clone(&rig.clock) as Arc<dyn Clock>,
        stop: StopSignal::new(),
        journal: Journal::default(),
        events: None,
        last_account: None,
    })
    .with_legacy_mirror(Arc::clone(mirror) as Arc<dyn LegacyMirror>)
}

#[tokio::test]
async fn a_long_column_layout_is_marked_by_its_category_as_the_swift_engine_marked_it() {
    let rig = Rig::new().await;
    let host = Arc::new(Host::default());
    let category = column_layout_category(Uuid::from_u128(4), Some("db"), Some("public"), &"t".repeat(250));
    host.apply(category.clone(), Some(json!({"hiddenColumns": ["a"]})))
        .await
        .unwrap();
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
    let adapter = Arc::new(SettingsAdapter::new(host.clone(), None)) as Arc<dyn RecordAdapter>;
    let sync = sync_over(&rig, vec![adapter], &mirror);
    sync.run_pass(PassReason::Launch).await.unwrap();
    let wire = record_name(Kind::MacosSettings, &shortened(Kind::MacosSettings, category.clone())).unwrap();
    let cached = mirror
        .metadata()
        .cache
        .iter()
        .map(|cached| cached.name.clone())
        .collect::<Vec<_>>();
    host.apply(category.clone(), Some(json!({"hiddenColumns": ["a", "b"]})))
        .await
        .unwrap();
    rig.cloud.fail_record(&wire, 15);
    let before = mirror.marks();
    sync.journal().changed(&[JournalEntry {
        kind: Kind::MacosSettings,
        written: vec![category.clone()],
        deleted: Vec::new(),
    }]);
    marked(&mirror, before + 1).await;
    let journaled = dirty(&mirror.metadata());

    sync.run_pass(PassReason::Poll).await.unwrap();

    assert!(category.len() > 255);
    assert_eq!(cached, [wire]);
    assert_eq!(journaled, [("AppSettings".to_owned(), category.clone())]);
    assert_eq!(dirty(&mirror.metadata()), [("AppSettings".to_owned(), category)]);
}

#[tokio::test]
async fn the_team_library_s_kinds_never_reach_the_swift_metadata() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "Work"}));
    let dir = tempfile::tempdir().unwrap();
    let paths = StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro");
    let library = TeamLibraryStore::new(
        &paths,
        TeamLibraryOwner {
            origin: "https://sync.example.com".to_owned(),
            account_id: "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8".to_owned(),
        },
    );
    let mut adapters = TeamLibraryAdapter::all(&library);
    adapters.push(Arc::clone(&rig.stores[&Kind::Group]) as Arc<dyn RecordAdapter>);
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
    let sync = sync_over(&rig, adapters, &mirror);
    sync.journal().changed(&[JournalEntry {
        kind: Kind::LibraryQuery,
        written: vec!["QueryId".to_owned()],
        deleted: Vec::new(),
    }]);

    sync.run_pass(PassReason::Launch).await.unwrap();
    let held = mirror.metadata();

    assert_eq!(held.cache.len(), 1);
    assert_eq!(held.readable_record_types, ["ConnectionGroup"]);
    assert_eq!(mirror.marks(), 0);
}
