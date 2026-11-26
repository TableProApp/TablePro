// A Mac with Team Library attached: its engine, its Team Library store on disk and the sign-in it was opened with.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::{Value, json};
use tablepro_keys::encoding::TeamId;
use tablepro_storage::TeamLibraryKind;
use tablepro_storage::{StoragePaths, TeamLibraryOwner, TeamLibraryStore};
use tablepro_sync::adapters::team_library::TeamLibraryAdapter;
use tablepro_sync::api::control::{ConflictChoice, SyncControl};
use tablepro_sync::api::ids::{RecordKey, ScopeName};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::StateStore;
use tablepro_sync::api::team_library::{SignInGuard, TeamFolder, TeamItemRef, TeamQuery};
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::service::ScopeOwner;
use uuid::Uuid;

use crate::harness::{ACCOUNT, Device, DeviceBuilder, account};

pub fn team() -> TeamId {
    TeamId(Uuid::from_u128(0x0191_0000_0000_7000_8000_0000_0000_00AA))
}

pub fn scope() -> ScopeName {
    ScopeName::Team(team())
}

pub fn owner() -> ScopeOwner {
    ScopeOwner::Team(team())
}

pub fn uuid(n: u128) -> Uuid {
    Uuid::from_u128(n)
}

pub fn lower(n: u128) -> String {
    uuid(n).hyphenated().to_string()
}

pub struct Toggle(AtomicBool);

impl SignInGuard for Toggle {
    fn holds(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

pub struct Mac {
    pub device: Device,
    pub store: TeamLibraryStore,
    pub sign_in: Arc<Toggle>,
    pub paths: StoragePaths,
}

pub fn team_server(role: Role) -> Arc<FakeServer> {
    let server = FakeServer::new();
    server.add_team(team(), &[(account(), role)]);
    server
}

fn store_at(paths: &StoragePaths) -> TeamLibraryStore {
    TeamLibraryStore::new(
        paths,
        TeamLibraryOwner {
            origin: "https://sync.example.com/v2".to_owned(),
            account_id: ACCOUNT.to_owned(),
        },
    )
}

impl Mac {
    pub async fn new(server: &Arc<FakeServer>, row: &str, dir: &std::path::Path) -> Self {
        Self::open(server, row, dir, None).await
    }

    // The same device after a quit: its state file and its store's file, a new engine over them.
    pub async fn reopen(self, server: &Arc<FakeServer>, row: &str, dir: &std::path::Path) -> Self {
        let state = Arc::clone(&self.device.state);
        drop(self);
        Self::open(server, row, dir, Some(state)).await
    }

    async fn open(
        server: &Arc<FakeServer>,
        row: &str,
        dir: &std::path::Path,
        state: Option<Arc<dyn StateStore>>,
    ) -> Self {
        let paths = StoragePaths::under(&dir.join(row), "tablepro", "app.tablepro.TablePro");
        let store = store_at(&paths);
        let mut builder = DeviceBuilder::new(server, row);
        for adapter in TeamLibraryAdapter::all(&store) {
            builder = builder.extra_adapter(adapter);
        }
        if let Some(state) = state {
            builder = builder.state(state);
        }
        let device = builder.build().await;
        let sign_in = Arc::new(Toggle(AtomicBool::new(true)));
        device
            .sync
            .attach_team_library(store.clone(), Arc::clone(&sign_in) as Arc<dyn SignInGuard>)
            .await
            .unwrap();
        Self {
            device,
            store,
            sign_in,
            paths,
        }
    }

    pub fn sign_out(&self) {
        self.sign_in.0.store(false, Ordering::SeqCst);
    }

    pub fn items(&self, kind: TeamLibraryKind) -> Vec<(String, Value)> {
        self.store
            .team_blocking(&scope().wire())
            .unwrap()
            .map(|team| {
                team.items
                    .into_iter()
                    .filter(|item| item.kind == kind)
                    .map(|item| (item.id, item.fields))
                    .collect()
            })
            .unwrap_or_default()
    }
}

pub fn folder(n: u128, name: &str, parent: Option<u128>) -> TeamFolder {
    TeamFolder {
        id: uuid(n),
        name: name.to_owned(),
        parent: parent.map(uuid),
        sort_order: 0,
    }
}

pub fn query(n: u128, name: &str, folder: Option<u128>) -> TeamQuery {
    TeamQuery {
        id: uuid(n),
        name: name.to_owned(),
        query: "select 1".to_owned(),
        keyword: None,
        folder: folder.map(uuid),
        connection: None,
        sort_order: 0,
    }
}

pub fn query_fields(name: &str, folder: Option<String>) -> Value {
    let mut fields = json!({"name": name, "query": "select 1", "sort_order": 0});
    if let (Some(folder), Value::Object(members)) = (folder, &mut fields) {
        members.insert("folder_client_id".to_owned(), Value::from(folder));
    }
    fields
}

pub fn item(kind: TeamLibraryKind, id: String) -> TeamItemRef {
    TeamItemRef { kind, id }
}

// Keep Mine or Keep Theirs on the conflict the sheet shows for `key`.
pub async fn resolve(mac: &Mac, key: RecordKey, keep: ConflictChoice) {
    let open = mac.device.sync.conflicts().await.unwrap();
    let shown = open.iter().find(|conflict| conflict.key == key).unwrap();
    mac.device.sync.resolve_conflict(key, shown.digest, keep).await.unwrap();
}

pub fn server_fields(server: &FakeServer, kind: &str, id: &str) -> Option<Value> {
    server.stored(owner(), kind, id).and_then(|record| record.fields)
}
