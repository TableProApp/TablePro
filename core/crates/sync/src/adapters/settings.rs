// The `<platform>_settings` adapter (0044, Settings; 0054, Adapters): one record per category of the app's settings,
// its id the category or, when too long, the category's digest (0052, Long ids), with the category in its fields. A
// map keyed by data, such as column widths by column, goes as a list of entries on the wire, as the CloudKit
// projection writes it. Column layouts of a connection that does not sync stay on the device.
//
// The host returns, and keeps, a category its platform's registry does not name, such as one a newer build wrote, as
// the document it was given: the store holds what the engine applied, so the diff never reads its absence as a
// deletion.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Map, Value, json};
use tablepro_records::Kind;
use tablepro_records::record_id::shortened;
use tablepro_records::schema::Type;
use tablepro_records::settings::{Document, owner, registry};
use uuid::Uuid;

use crate::api::adapter::{HostSettings, LocalChange, LocalRecord, LocalRecords, RecordAdapter, StoreStamp};
use crate::api::error::AdapterError;
use crate::api::ids::ScopeName;
use crate::api::state::Standing;

// Whether a connection's records sync, from the store that holds connections.
pub trait ConnectionStanding: Send + Sync {
    fn standing(&self, connection: Uuid) -> Standing;
}

pub struct SettingsAdapter {
    host: Arc<dyn HostSettings>,
    connections: Option<Arc<dyn ConnectionStanding>>,
    identity: StoreStamp,
    store: String,
}

impl SettingsAdapter {
    // The host keeps no generation of its own, so the adapter's identity is fixed for the process: a host that restores
    // its settings calls `sync_now` after it, and the merge settles them as edits.
    pub fn new(host: Arc<dyn HostSettings>, connections: Option<Arc<dyn ConnectionStanding>>) -> Self {
        let store = format!("{}.host", host.kind().as_str());
        Self {
            host,
            connections,
            identity: StoreStamp {
                generation: Uuid::nil(),
                sequence: 0,
            },
            store,
        }
    }

    fn standing(&self, category: &str) -> Standing {
        match (owner(category), &self.connections) {
            (Some(connection), Some(connections)) => connections.standing(connection),
            _ => Standing::Syncs,
        }
    }
}

fn host_error(error: AdapterError) -> AdapterError {
    match error {
        AdapterError::Host { .. } => error,
        other => AdapterError::Host {
            detail: other.to_string(),
        },
    }
}

#[derive(Clone, Copy)]
enum Direction {
    ToWire,
    ToHost,
}

// The options a category's registry types as entries, between the host's map and the wire's list.
fn converted(kind: Kind, category: &str, document: Value, direction: Direction) -> Value {
    let Some(Document::Object(fields)) = registry(kind)
        .and_then(|registry| registry.category(category))
        .map(|known| known.document)
    else {
        return document;
    };
    let Value::Object(mut members) = document else {
        return document;
    };
    for field in fields {
        if !matches!(field.ty, Type::Entries(_)) {
            continue;
        }
        let Some(value) = members.remove(field.key) else {
            continue;
        };
        let value = match (direction, value) {
            (Direction::ToWire, Value::Object(map)) => Value::Array(
                map.into_iter()
                    .map(|(id, value)| json!({"id": id, "value": value}))
                    .collect(),
            ),
            (Direction::ToHost, Value::Array(items)) if items.iter().all(is_entry) => Value::Object(
                items
                    .into_iter()
                    .filter_map(|item| match item {
                        Value::Object(mut entry) => {
                            let id = entry.remove("id")?.as_str()?.to_owned();
                            Some((id, entry.remove("value")?))
                        }
                        _ => None,
                    })
                    .collect::<Map<String, Value>>(),
            ),
            (_, value) => value,
        };
        members.insert(field.key.to_owned(), value);
    }
    Value::Object(members)
}

fn is_entry(item: &Value) -> bool {
    item.get("id").is_some_and(Value::is_string) && item.get("value").is_some()
}

#[async_trait]
impl RecordAdapter for SettingsAdapter {
    fn kind(&self) -> Kind {
        self.host.kind()
    }

    fn store(&self) -> &str {
        &self.store
    }

    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        Ok(self.identity)
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        if scope != ScopeName::Personal {
            return Ok(LocalRecords::default());
        }
        let kind = self.kind();
        let categories = self.host.categories().await.map_err(host_error)?;
        let records = categories
            .into_iter()
            .map(|settings| LocalRecord {
                record_id: shortened(kind, settings.category.clone()),
                standing: self.standing(&settings.category),
                fields: json!({
                    "category": settings.category,
                    "options": converted(kind, &settings.category, settings.document, Direction::ToWire),
                }),
            })
            .collect();
        Ok(LocalRecords {
            records,
            unreadable: Vec::new(),
            tombstones: Vec::new(),
        })
    }

    // A record names its category in its fields; a deletion names the category through the record the host holds.
    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        if scope != ScopeName::Personal || changes.is_empty() {
            return Ok(self.identity);
        }
        let kind = self.kind();
        let mut held = None;
        for change in changes {
            match change {
                LocalChange::Put { record_id, fields } => {
                    // No build writes a category under another category's id; such a record is left out.
                    let Some(category) = fields
                        .get("category")
                        .and_then(Value::as_str)
                        .filter(|category| shortened(kind, (*category).to_owned()) == record_id)
                        .map(str::to_owned)
                    else {
                        tracing::debug!("a settings record whose category is not its id was left out");
                        continue;
                    };
                    let options = fields.get("options").cloned().unwrap_or(Value::Object(Map::new()));
                    let document = converted(kind, &category, options, Direction::ToHost);
                    self.host.apply(category, Some(document)).await.map_err(host_error)?;
                }
                LocalChange::Delete { record_id } => {
                    if held.is_none() {
                        held = Some(self.host.categories().await.map_err(host_error)?);
                    }
                    let category = held.iter().flatten().find_map(|settings| {
                        (shortened(kind, settings.category.clone()) == record_id).then(|| settings.category.clone())
                    });
                    if let Some(category) = category {
                        self.host.apply(category, None).await.map_err(host_error)?;
                    }
                }
            }
        }
        Ok(self.identity)
    }

    async fn tombstones_pushed(&self, _scope: ScopeName, _record_ids: Vec<String>) -> Result<(), AdapterError> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::api::adapter::SettingsDocument;

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
    async fn a_category_goes_up_with_its_maps_as_entries_and_comes_back_whole() {
        let host = Arc::new(Host::default());
        let connection = Uuid::from_u128(9);
        let layout =
            tablepro_records::record_id::column_layout_category(connection, Some("db"), Some("public"), "users");
        let document = json!({"columnWidths": {"id": 40, "email": 220}, "hiddenColumns": ["x"]});
        host.apply("general".to_owned(), Some(json!({"language": "en"})))
            .await
            .unwrap();
        host.apply(layout.clone(), Some(document.clone())).await.unwrap();
        let adapter = SettingsAdapter::new(host.clone(), Some(Arc::new(LocalOnly(connection))));

        let records = adapter.records(ScopeName::Personal).await.unwrap().records;
        let wire = records
            .iter()
            .find(|record| record.fields["category"] == json!(layout))
            .unwrap();
        adapter
            .apply(
                ScopeName::Personal,
                vec![LocalChange::Put {
                    record_id: wire.record_id.clone(),
                    fields: wire.fields.clone(),
                }],
            )
            .await
            .unwrap();
        let back = host.categories().await.unwrap();

        assert_eq!(
            wire.fields["options"]["columnWidths"],
            json!([{"id": "email", "value": 220}, {"id": "id", "value": 40}])
        );
        assert_eq!(wire.standing, Standing::LocalOnly);
        assert!(records.iter().any(|record| record.record_id == "general"));
        assert_eq!(
            back.iter()
                .find(|settings| settings.category == layout)
                .map(|settings| &settings.document),
            Some(&document)
        );
    }

    #[tokio::test]
    async fn a_deleted_theme_goes_and_a_record_whose_category_is_not_its_id_is_left_out() {
        let host = Arc::new(Host::default());
        host.apply("theme.ocean".to_owned(), Some(json!({"name": "Ocean"})))
            .await
            .unwrap();
        let adapter = SettingsAdapter::new(host.clone(), None);

        adapter
            .apply(
                ScopeName::Personal,
                vec![LocalChange::Delete {
                    record_id: "theme.ocean".to_owned(),
                }],
            )
            .await
            .unwrap();
        adapter
            .apply(
                ScopeName::Personal,
                vec![LocalChange::Put {
                    record_id: "general".to_owned(),
                    fields: json!({"category": "editor", "options": {}}),
                }],
            )
            .await
            .unwrap();

        assert!(host.categories().await.unwrap().is_empty());
    }
}
