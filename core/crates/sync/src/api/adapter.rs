use async_trait::async_trait;
use serde_json::Value;
use tablepro_records::Kind;
use uuid::Uuid;

use super::error::AdapterError;
use super::ids::ScopeName;
use super::state::Standing;

// One kind's bridge to its core store (0054, Adapters). Dirty state is the diff of `records` against the bases, so a
// write the journal missed is found on the next pass.
#[async_trait]
pub trait RecordAdapter: Send + Sync {
    fn kind(&self) -> Kind;

    // The store whose identity puts this kind into refill when it changes (0054, Store identity).
    fn store(&self) -> &str;

    async fn identity(&self) -> Result<StoreStamp, AdapterError>;

    // Every record the store holds of this kind in `scope` as wire fields, the ids it holds but cannot read, and for a
    // create-once kind the tombstones it keeps until they are pushed. A team library kind has one set per team.
    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError>;

    // Writes what a pull of `scope` settled, in one store write, and answers the identity after it.
    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError>;

    // A create-once kind's tombstones the provider took, which the store drops.
    async fn tombstones_pushed(&self, scope: ScopeName, record_ids: Vec<String>) -> Result<(), AdapterError>;
}

// A store's generation id and write sequence. A new generation is a restored, replaced or copied file; a lower
// sequence went back in time. Either puts the store's kinds into refill.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct StoreStamp {
    pub generation: Uuid,
    pub sequence: u64,
}

impl StoreStamp {
    pub fn needs_refill(self, seen: Self) -> bool {
        self.generation != seen.generation || self.sequence < seen.sequence
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LocalRecords {
    pub records: Vec<LocalRecord>,
    pub unreadable: Vec<String>,
    pub tombstones: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalRecord {
    pub record_id: String,
    pub fields: Value,
    // Local only and sample connections never leave the device.
    pub standing: Standing,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LocalChange {
    Put { record_id: String, fields: Value },
    Delete { record_id: String },
}

// Each app's settings, which it keeps its own way (0054, Adapters): the categories of its platform's registry in
// `tablepro_records::settings`, each as one JSON document. The `<platform>_settings` adapter sits over it.
#[async_trait]
pub trait HostSettings: Send + Sync {
    fn kind(&self) -> Kind;

    // Every category the host holds a value for. One its platform's registry does not name, such as a newer build's,
    // comes back as it was applied, unchanged, so the diff never reads its absence as a deletion (0066, Rules).
    async fn categories(&self) -> Result<Vec<SettingsDocument>, AdapterError>;

    // None removes the category's synced document, as a deleted theme.
    async fn apply(&self, category: String, document: Option<Value>) -> Result<(), AdapterError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsDocument {
    pub category: String,
    pub document: Value,
}
