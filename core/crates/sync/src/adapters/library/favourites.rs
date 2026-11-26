// Favourite tables and databases (`SyncRecordMapper`, Table Favorite and Favorite Database), in the history database.
// Each is named by a digest of what it names (0052, Long ids). On iCloud a favourite table whose names hold `|` or `\`
// also goes by the alias Macs before 0.77 wrote, as the Mac keeps both; TablePro Sync carries the escaped id only. A table's database and schema go only when set, a database's
// environment always, and one a newer build named reads as unassigned, as the Mac reads it. A favourite of a connection
// that does not sync stays on the device.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::record_id::{favourite_database, favourite_table};
use tablepro_storage::favourites::FavouriteContents;
use tablepro_storage::{
    ConnectionStore, DatabaseEnvironment, FavouriteDatabase, FavouriteTable, Favourites, QueryHistory, StorageError,
};
use uuid::Uuid;

use super::folders::connection_standing_map;
use super::values::{Object, text, uuid_at, uuid_value};
use super::{HISTORY_STORE, Provider, Seen, changed_since, lock, record_of, seen, stale};
use crate::api::adapter::{LocalChange, LocalRecord, LocalRecords, RecordAdapter, StoreStamp};
use crate::api::error::AdapterError;
use crate::api::ids::ScopeName;
use crate::api::state::Standing;

pub struct FavouriteAdapter {
    history: QueryHistory,
    favourites: Favourites,
    connections: ConnectionStore,
    kind: Kind,
    provider: Provider,
    seen: Mutex<Option<HashMap<String, Seen>>>,
}

impl FavouriteAdapter {
    pub fn all(
        history: &QueryHistory,
        connections: &ConnectionStore,
        provider: Provider,
    ) -> Vec<Arc<dyn RecordAdapter>> {
        [Kind::FavouriteTable, Kind::FavouriteDatabase]
            .into_iter()
            .map(|kind| {
                Arc::new(Self {
                    history: history.clone(),
                    favourites: history.favourites(),
                    connections: connections.clone(),
                    kind,
                    provider,
                    seen: Mutex::new(None),
                }) as Arc<dyn RecordAdapter>
            })
            .collect()
    }
}

fn store_error(error: StorageError) -> AdapterError {
    AdapterError::Store {
        store: HISTORY_STORE.to_owned(),
        detail: error.to_string(),
    }
}

pub(super) fn table_id(table: &FavouriteTable) -> String {
    favourite_table(
        table.connection_id,
        table.database.as_deref(),
        table.schema.as_deref(),
        &table.name,
    )
    .id
}

fn alias_of(table: &FavouriteTable) -> Option<String> {
    favourite_table(
        table.connection_id,
        table.database.as_deref(),
        table.schema.as_deref(),
        &table.name,
    )
    .alias
}

// The alias of each table that alone claims its alias. On iCloud the Mac writes and deletes such a table under both
// ids, and two tables whose names join alike share no alias (0052, Long ids).
fn sole_aliases(tables: &[FavouriteTable]) -> HashMap<String, &FavouriteTable> {
    let mut claimed: HashMap<String, Vec<&FavouriteTable>> = HashMap::new();
    for table in tables {
        if let Some(alias) = alias_of(table) {
            claimed.entry(alias).or_default().push(table);
        }
    }
    claimed
        .into_iter()
        .filter_map(|(alias, claimants)| match claimants.as_slice() {
            [table] => Some((alias, *table)),
            _ => None,
        })
        .collect()
}

pub(super) fn database_id(database: &FavouriteDatabase) -> String {
    favourite_database(database.connection_id, &database.database)
}

pub(super) fn table_to_wire(table: &FavouriteTable) -> Value {
    Object::default()
        .put("connection_id", uuid_value(table.connection_id))
        .put("name", table.name.as_str())
        .put_some("database", table.database.as_deref())
        .put_some("schema", table.schema.as_deref())
        .done()
}

pub(super) fn table_from_wire(fields: &Value) -> Option<FavouriteTable> {
    Some(FavouriteTable {
        connection_id: uuid_at(fields, "connection_id")?,
        database: text(fields, "database")
            .filter(|text| !text.is_empty())
            .map(str::to_owned),
        schema: text(fields, "schema")
            .filter(|text| !text.is_empty())
            .map(str::to_owned),
        name: text(fields, "name").filter(|name| !name.is_empty())?.to_owned(),
    })
}

pub(super) fn database_to_wire(database: &FavouriteDatabase) -> Value {
    Object::default()
        .put("connection_id", uuid_value(database.connection_id))
        .put("database", database.database.as_str())
        .put("environment", database.environment.as_str())
        .done()
}

pub(super) fn database_from_wire(fields: &Value) -> Option<FavouriteDatabase> {
    Some(FavouriteDatabase {
        connection_id: uuid_at(fields, "connection_id")?,
        database: text(fields, "database")
            .filter(|database| !database.is_empty())?
            .to_owned(),
        environment: text(fields, "environment")
            .and_then(DatabaseEnvironment::parse)
            .unwrap_or(DatabaseEnvironment::Unassigned),
    })
}

impl FavouriteAdapter {
    fn read(&self, contents: &FavouriteContents, standing: &HashMap<Uuid, Standing>) -> LocalRecords {
        let standing = |connection: Uuid| standing.get(&connection).copied().unwrap_or(Standing::Unknown);
        let records = match self.kind {
            Kind::FavouriteTable => {
                let mut records: Vec<LocalRecord> = contents
                    .tables
                    .iter()
                    .map(|table| LocalRecord {
                        record_id: table_id(table),
                        fields: table_to_wire(table),
                        standing: standing(table.connection_id),
                    })
                    .collect();
                if self.provider == Provider::ICloud {
                    records.extend(
                        sole_aliases(&contents.tables)
                            .into_iter()
                            .map(|(alias, table)| LocalRecord {
                                record_id: alias,
                                fields: table_to_wire(table),
                                standing: standing(table.connection_id),
                            }),
                    );
                }
                records
            }
            _ => contents
                .databases
                .iter()
                .map(|database| LocalRecord {
                    record_id: database_id(database),
                    fields: database_to_wire(database),
                    standing: standing(database.connection_id),
                })
                .collect(),
        };
        LocalRecords {
            records,
            unreadable: Vec::new(),
            tombstones: Vec::new(),
        }
    }

    // What the store holds once the changes land. A copy the store cannot hold is held by id before it reaches here
    // (`tablepro_records::schema::readable`).
    async fn write(&self, contents: &FavouriteContents, changes: &[LocalChange]) -> Result<(), AdapterError> {
        let gone = |record_id: &str| {
            changes
                .iter()
                .any(|change| matches!(change, LocalChange::Delete { .. }) && record_of(change) == record_id)
        };
        let outcome = match self.kind {
            Kind::FavouriteTable => {
                let puts: Vec<FavouriteTable> = changes
                    .iter()
                    .filter_map(|change| match change {
                        LocalChange::Put { fields, .. } => table_from_wire(fields),
                        LocalChange::Delete { .. } => None,
                    })
                    .collect();
                // A deletion under an alias removes the table only when it alone claims the alias.
                let aliases = sole_aliases(&contents.tables);
                let deleted = |table: &FavouriteTable| {
                    gone(&table_id(table))
                        || aliases
                            .iter()
                            .any(|(alias, claimant)| *claimant == table && gone(alias))
                };
                let mut tables: Vec<FavouriteTable> = contents
                    .tables
                    .iter()
                    .filter(|table| !deleted(table) && !puts.contains(table))
                    .cloned()
                    .collect();
                tables.extend(puts);
                self.favourites
                    .replace_tables(Some(contents.digests.tables.as_str()), &tables)
                    .await
            }
            _ => {
                let puts: Vec<FavouriteDatabase> = changes
                    .iter()
                    .filter_map(|change| match change {
                        LocalChange::Put { fields, .. } => database_from_wire(fields),
                        LocalChange::Delete { .. } => None,
                    })
                    .collect();
                let mut databases: Vec<FavouriteDatabase> = contents
                    .databases
                    .iter()
                    .filter(|held| {
                        let id = database_id(held);
                        !gone(&id) && !puts.iter().any(|put| database_id(put) == id)
                    })
                    .cloned()
                    .collect();
                databases.extend(puts);
                self.favourites
                    .replace_databases(Some(contents.digests.databases.as_str()), &databases)
                    .await
            }
        };
        match outcome {
            Ok(_) => Ok(()),
            Err(StorageError::ImportOutdated) => Err(stale(HISTORY_STORE)),
            Err(error) => Err(store_error(error)),
        }
    }
}

#[async_trait]
impl RecordAdapter for FavouriteAdapter {
    fn kind(&self) -> Kind {
        self.kind
    }

    fn store(&self) -> &str {
        HISTORY_STORE
    }

    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        let identity = self.history.identity().await.map_err(store_error)?;
        Ok(StoreStamp {
            generation: identity.generation,
            sequence: identity.sequence,
        })
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        if scope != ScopeName::Personal {
            return Ok(LocalRecords::default());
        }
        let contents = self.favourites.contents().await.map_err(store_error)?;
        let records = self.read(&contents, &connection_standing_map(&self.connections).await?);
        *lock(&self.seen) = Some(seen(&records));
        Ok(records)
    }

    // One write the store refuses when what it holds changed since it was read.
    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        if scope != ScopeName::Personal || changes.is_empty() {
            return self.identity().await;
        }
        let expected = lock(&self.seen).take();
        let contents = self.favourites.contents().await.map_err(store_error)?;
        if let Some(expected) = expected {
            let now = seen(&self.read(&contents, &connection_standing_map(&self.connections).await?));
            if changed_since(&expected, &now, &changes) {
                return Err(stale(HISTORY_STORE));
            }
        }
        self.write(&contents, &changes).await?;
        self.identity().await
    }

    async fn tombstones_pushed(&self, _scope: ScopeName, _record_ids: Vec<String>) -> Result<(), AdapterError> {
        Ok(())
    }
}
