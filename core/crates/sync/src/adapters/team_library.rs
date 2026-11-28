// The team library kinds (0051, Kinds; 0044, The library moves in): `library_connection`, `library_folder` and
// `library_query` over the account's Team Library store, one set per team scope. An item's fields are the bundle's
// object, which the store keeps as it came, so every member a newer build writes survives; its id is the client id
// the team stores, byte for byte (0052, Team scope).

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;
use tablepro_records::Kind;
use tablepro_storage::{
    StorageError, TeamLibraryEnvelope, TeamLibraryItem, TeamLibraryKind, TeamLibraryStore, TeamLibraryWriter,
};
use uuid::Uuid;

use super::blocking;
use crate::api::adapter::{LocalChange, LocalRecord, LocalRecords, PulledWriter, RecordAdapter, StoreStamp};
use crate::api::error::AdapterError;
use crate::api::ids::ScopeName;
use crate::api::state::Standing;

const STORE: &str = "team_library.json";

pub struct TeamLibraryAdapter {
    store: TeamLibraryStore,
    kind: Kind,
    library: TeamLibraryKind,
}

impl TeamLibraryAdapter {
    // One adapter per kind over the one store.
    pub fn all(store: &TeamLibraryStore) -> Vec<Arc<dyn RecordAdapter>> {
        [
            (Kind::LibraryConnection, TeamLibraryKind::Connection),
            (Kind::LibraryFolder, TeamLibraryKind::Folder),
            (Kind::LibraryQuery, TeamLibraryKind::Query),
        ]
        .into_iter()
        .map(|(kind, library)| {
            Arc::new(Self {
                store: store.clone(),
                kind,
                library,
            }) as Arc<dyn RecordAdapter>
        })
        .collect()
    }
}

fn store_error(error: StorageError) -> AdapterError {
    AdapterError::Store {
        store: STORE.to_owned(),
        detail: error.to_string(),
    }
}

fn stamp(identity: Option<tablepro_storage::StoreIdentity>) -> StoreStamp {
    identity.map_or(
        StoreStamp {
            generation: Uuid::nil(),
            sequence: 0,
        },
        |identity| StoreStamp {
            generation: identity.generation,
            sequence: identity.sequence,
        },
    )
}

#[async_trait]
impl RecordAdapter for TeamLibraryAdapter {
    fn kind(&self) -> Kind {
        self.kind
    }

    fn store(&self) -> &str {
        STORE
    }

    // A store never written yet starts its generation now, so its first write is not read as a restore.
    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        let store = self.store.clone();
        let identity = blocking(move || match store.identity_blocking()? {
            Some(identity) => Ok(identity),
            None => store.start_new_generation_blocking(),
        })
        .await?
        .map_err(store_error)?;
        Ok(stamp(Some(identity)))
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        let ScopeName::Team(_) = scope else {
            return Ok(LocalRecords::default());
        };
        let store = self.store.clone();
        let team = scope.wire();
        let held = blocking(move || store.team_blocking(&team))
            .await?
            .map_err(store_error)?;
        let records = held
            .into_iter()
            .flat_map(|team| team.items)
            .filter(|item| item.kind == self.library)
            .map(|item| LocalRecord {
                record_id: item.id,
                fields: item.fields,
                standing: Standing::Syncs,
            })
            .collect();
        Ok(LocalRecords {
            records,
            unreadable: Vec::new(),
            tombstones: Vec::new(),
        })
    }

    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        let ScopeName::Team(_) = scope else {
            return self.identity().await;
        };
        let mut puts = Vec::new();
        let mut gone = Vec::new();
        for change in changes {
            match change {
                LocalChange::Put { record_id, fields } if matches!(fields, Value::Object(_)) => {
                    puts.push(TeamLibraryItem {
                        kind: self.library,
                        id: record_id,
                        fields,
                    });
                }
                LocalChange::Put { .. } => {
                    return Err(AdapterError::Unreadable {
                        detail: "a team library item whose fields are not an object".to_owned(),
                    });
                }
                LocalChange::Delete { record_id } => gone.push((self.library, record_id)),
            }
        }
        let store = self.store.clone();
        let team = scope.wire();
        let identity = blocking(move || {
            if !puts.is_empty() {
                store.put_items_blocking(&team, puts)?;
            }
            if !gone.is_empty() {
                store.remove_items_blocking(&team, &gone)?;
            }
            store.identity_blocking()
        })
        .await?
        .map_err(store_error)?;
        Ok(stamp(identity))
    }

    async fn tombstones_pushed(&self, _scope: ScopeName, _record_ids: Vec<String>) -> Result<(), AdapterError> {
        Ok(())
    }

    // The team list and the conflict sheet name who last changed each item.
    async fn pulled_writers(&self, scope: ScopeName, writers: Vec<PulledWriter>) -> Result<(), AdapterError> {
        let ScopeName::Team(_) = scope else {
            return Ok(());
        };
        let kind = self.library;
        let writers: Vec<TeamLibraryWriter> = writers
            .into_iter()
            .map(|writer| TeamLibraryWriter {
                kind,
                id: writer.record_id,
                name: writer.name,
                at_ms: writer.at_ms,
            })
            .collect();
        let store = self.store.clone();
        let team = scope.wire();
        blocking(move || store.record_writers_blocking(&team, writers))
            .await?
            .map_err(store_error)
    }
}

// A team's `secret_envelope` records (0056, Envelopes and history) over the same store: the sealed copies of the team's
// connection secrets, ciphertext only. A pull lands the copies the keys already judged, and a publish writes the copies
// it sealed, which the engine sends as it sends any change. The personal envelopes have a store of their own.
pub struct TeamEnvelopeAdapter {
    store: TeamLibraryStore,
}

impl TeamEnvelopeAdapter {
    pub fn new(store: &TeamLibraryStore) -> Self {
        Self { store: store.clone() }
    }
}

#[async_trait]
impl RecordAdapter for TeamEnvelopeAdapter {
    fn kind(&self) -> Kind {
        Kind::SecretEnvelope
    }

    fn store(&self) -> &str {
        STORE
    }

    fn serves(&self, scope: ScopeName) -> bool {
        matches!(scope, ScopeName::Team(_))
    }

    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        let store = self.store.clone();
        let identity = blocking(move || match store.identity_blocking()? {
            Some(identity) => Ok(identity),
            None => store.start_new_generation_blocking(),
        })
        .await?
        .map_err(store_error)?;
        Ok(stamp(Some(identity)))
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        let ScopeName::Team(_) = scope else {
            return Ok(LocalRecords::default());
        };
        let store = self.store.clone();
        let team = scope.wire();
        let held = blocking(move || store.team_blocking(&team))
            .await?
            .map_err(store_error)?;
        let records = held
            .into_iter()
            .flat_map(|team| team.envelopes)
            .map(|envelope| LocalRecord {
                record_id: envelope.id,
                fields: envelope.fields,
                standing: Standing::Syncs,
            })
            .collect();
        Ok(LocalRecords {
            records,
            unreadable: Vec::new(),
            tombstones: Vec::new(),
        })
    }

    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        let ScopeName::Team(_) = scope else {
            return self.identity().await;
        };
        let mut puts = Vec::new();
        let mut gone = Vec::new();
        for change in changes {
            match change {
                LocalChange::Put { record_id, fields } if matches!(fields, Value::Object(_)) => {
                    puts.push(TeamLibraryEnvelope { id: record_id, fields });
                }
                LocalChange::Put { .. } => {
                    return Err(AdapterError::Unreadable {
                        detail: "a team envelope whose fields are not an object".to_owned(),
                    });
                }
                LocalChange::Delete { record_id } => gone.push(record_id),
            }
        }
        let store = self.store.clone();
        let team = scope.wire();
        let identity = blocking(move || {
            if !puts.is_empty() {
                store.put_envelopes_blocking(&team, puts)?;
            }
            if !gone.is_empty() {
                store.remove_envelopes_blocking(&team, &gone)?;
            }
            store.identity_blocking()
        })
        .await?
        .map_err(store_error)?;
        Ok(stamp(identity))
    }

    async fn tombstones_pushed(&self, _scope: ScopeName, _record_ids: Vec<String>) -> Result<(), AdapterError> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use tablepro_keys::encoding::TeamId;
    use tablepro_storage::{StoragePaths, TeamLibraryOwner};

    use super::*;

    fn store(dir: &std::path::Path) -> TeamLibraryStore {
        let paths = StoragePaths::under(dir, "tablepro", "app.tablepro.TablePro");
        TeamLibraryStore::new(
            &paths,
            TeamLibraryOwner {
                origin: "https://sync.example.com".to_owned(),
                account_id: "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8".to_owned(),
            },
        )
    }

    #[tokio::test]
    async fn each_kind_round_trips_through_its_team_and_keeps_members_it_does_not_read() {
        let dir = tempfile::tempdir().unwrap();
        let adapters = TeamLibraryAdapter::all(&store(dir.path()));
        let team = ScopeName::Team(TeamId(Uuid::from_u128(5)));
        let other = ScopeName::Team(TeamId(Uuid::from_u128(6)));
        let query = json!({"name": "Q", "query": "select 1", "folder_client_id": "f1", "futureMember": [1]});
        let queries = adapters
            .iter()
            .find(|adapter| adapter.kind() == Kind::LibraryQuery)
            .unwrap();
        let folders = adapters
            .iter()
            .find(|adapter| adapter.kind() == Kind::LibraryFolder)
            .unwrap();

        let before = queries.identity().await.unwrap();
        let after = queries
            .apply(
                team,
                vec![LocalChange::Put {
                    record_id: "QueryId-Kept-Case".to_owned(),
                    fields: query.clone(),
                }],
            )
            .await
            .unwrap();
        folders
            .apply(
                team,
                vec![LocalChange::Put {
                    record_id: "f1".to_owned(),
                    fields: json!({"name": "F"}),
                }],
            )
            .await
            .unwrap();
        let held = queries.records(team).await.unwrap().records;
        let elsewhere = queries.records(other).await.unwrap().records;
        queries
            .apply(
                team,
                vec![LocalChange::Delete {
                    record_id: "QueryId-Kept-Case".to_owned(),
                }],
            )
            .await
            .unwrap();

        assert!(!after.needs_refill(before));
        assert_eq!(held.len(), 1);
        assert_eq!(held[0].record_id, "QueryId-Kept-Case");
        assert_eq!(held[0].fields, query);
        assert!(elsewhere.is_empty());
        assert!(queries.records(team).await.unwrap().records.is_empty());
        assert_eq!(folders.records(team).await.unwrap().records.len(), 1);
    }

    #[tokio::test]
    async fn team_envelopes_round_trip_beside_the_items_and_serve_only_team_scopes() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let envelopes = TeamEnvelopeAdapter::new(&store);
        let connections = TeamLibraryAdapter::all(&store)
            .into_iter()
            .find(|adapter| adapter.kind() == Kind::LibraryConnection)
            .unwrap();
        let team = ScopeName::Team(TeamId(Uuid::from_u128(5)));
        let id = "library_connection/c1/password".to_owned();
        let sealed = json!({"suite": "tp1", "kv": 1, "nonce": "bm9uY2U", "ct": "Y3Q"});

        connections
            .apply(
                team,
                vec![LocalChange::Put {
                    record_id: "c1".to_owned(),
                    fields: json!({"name": "Shop"}),
                }],
            )
            .await
            .unwrap();
        envelopes
            .apply(
                team,
                vec![LocalChange::Put {
                    record_id: id.clone(),
                    fields: sealed.clone(),
                }],
            )
            .await
            .unwrap();
        let held = envelopes.records(team).await.unwrap().records;
        let refused = envelopes
            .apply(
                team,
                vec![LocalChange::Put {
                    record_id: id.clone(),
                    fields: json!("plaintext"),
                }],
            )
            .await;
        envelopes
            .apply(team, vec![LocalChange::Delete { record_id: id.clone() }])
            .await
            .unwrap();

        assert!(envelopes.serves(team));
        assert!(!envelopes.serves(ScopeName::Personal));
        assert_eq!(held.len(), 1);
        assert_eq!((held[0].record_id.as_str(), &held[0].fields), (id.as_str(), &sealed));
        assert!(matches!(refused, Err(AdapterError::Unreadable { .. })));
        assert!(envelopes.records(team).await.unwrap().records.is_empty());
        assert_eq!(connections.records(team).await.unwrap().records.len(), 1);
        assert!(envelopes.records(ScopeName::Personal).await.unwrap().records.is_empty());
    }
}
