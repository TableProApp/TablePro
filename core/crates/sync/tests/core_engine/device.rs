// One device as the app wires it: its state file, device store, the key flows and the engine over one set of hooks.

use std::sync::Arc;

use secrecy::SecretString;

use tablepro_keys::encoding::AccountId;
use tablepro_sync::api::control::PassReason;
use tablepro_sync::api::ids::{DeviceRowId, ScopeName};
use tablepro_sync::api::key_flows::{AccountFlows, KeyFlows, KeyHooks, KeyState};
use tablepro_sync::api::state::{Row, RowKey, ScopeRow, StateFiles, StateIdentity, StateStore};
use tablepro_sync::api::transport::ServiceTransport;
use tablepro_sync::engine::{Adapters, EngineHooks, Journal, StopSignal, SystemClock, Wake};
use tablepro_sync::keys::{Clock, KeyService, KeyServiceParts};
use tablepro_sync::service::{PassReport, ProofSource, ServiceParts, ServiceSync};
use tablepro_sync_testing::{FakeDeviceStore, FakeServer, MemoryStateFiles};

use super::harness::{origin, typed_back};

// The server's clock, which the fake moves on.
struct ServerClock(Arc<FakeServer>);

impl Clock for ServerClock {
    fn now_us(&self) -> i64 {
        self.0.now_us()
    }
}

pub struct Device {
    pub keys: Arc<KeyService>,
    pub sync: ServiceSync,
    pub state: Arc<dyn StateStore>,
    pub server: Arc<FakeServer>,
    pub row: DeviceRowId,
}

impl Device {
    pub async fn new(server: &Arc<FakeServer>, account: AccountId, row: &str) -> Self {
        let row = DeviceRowId(row.to_owned());
        let state = MemoryStateFiles::new()
            .open(StateIdentity::Service {
                origin: origin(),
                sign_in: "sign-in".to_owned(),
                account,
                device_row: row.clone(),
            })
            .await
            .unwrap();
        let transport = Arc::new(server.client(account, row.clone()));
        let wake = Wake::new();
        let hooks = Arc::new(EngineHooks::new(wake.clone(), None));
        let keys = Arc::new(KeyService::new(KeyServiceParts {
            origin: origin(),
            account,
            device_row: row.clone(),
            state: Arc::clone(&state),
            device_store: Arc::new(FakeDeviceStore::new()),
            transport: Arc::clone(&transport) as Arc<dyn ServiceTransport>,
            hooks: Arc::clone(&hooks) as Arc<dyn KeyHooks>,
            clock: Arc::new(ServerClock(Arc::clone(server))),
        }));
        let sync = ServiceSync::new(ServiceParts {
            transport,
            state: Arc::clone(&state),
            adapters: Adapters::default(),
            keys: Arc::clone(&keys) as Arc<dyn KeyFlows>,
            hooks: Arc::clone(&hooks),
            proofs: Arc::clone(&keys) as Arc<dyn ProofSource>,
            clock: Arc::new(SystemClock),
            stop: StopSignal::new(),
            journal: Journal::new(wake),
            events: None,
        });
        Self {
            keys,
            sync,
            state,
            server: Arc::clone(server),
            row,
        }
    }

    pub async fn pass(&self) -> PassReport {
        self.sync.run_pass(PassReason::Person).await.unwrap()
    }

    // Genesis as the person runs it after a first pass, then the approval the server records for the row. Returns R.
    pub async fn genesis(&self) -> SecretString {
        self.pass().await;
        let draft = self.keys.begin_genesis().await.unwrap();
        self.keys.finish_genesis(draft.draft, typed_back(&draft)).await.unwrap();
        self.approve().await;
        draft.text
    }

    // Replace Recovery Key, keeping no other device.
    pub async fn replace(&self, recovery_key: SecretString) -> SecretString {
        let draft = self.keys.begin_replace(recovery_key).await.unwrap();
        self.keys
            .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
            .await
            .unwrap();
        draft.recovery.text
    }

    pub async fn approve(&self) {
        let device = self.keys.device_keys().await.unwrap().current.unwrap();
        self.server.approve(&self.row, device.dsk.public().unwrap().0);
    }

    pub async fn key_state(&self) -> KeyState {
        self.keys.key_state().await.unwrap()
    }

    pub async fn scope(&self, scope: ScopeName) -> ScopeRow {
        match self
            .state
            .begin()
            .await
            .unwrap()
            .get(&RowKey::Scope(scope))
            .await
            .unwrap()
        {
            Some(Row::Scope(row)) => row,
            _ => panic!("no scope row for {scope}"),
        }
    }
}
