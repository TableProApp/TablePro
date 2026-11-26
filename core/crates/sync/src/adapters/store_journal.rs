// A core store's change journal (0060) told to each engine that syncs the store, its records named by the ids the
// adapters give them on the wire (0052), so a journal pass diffs exactly the records the write changed.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};

use tablepro_records::Kind;
use tablepro_records::record_id::{favourite_database, favourite_table, table_folder_item, uuid_id};
use tablepro_storage::{ChangeJournal, RecordRef};

use crate::engine::{Journal, JournalEntry, JournalObserver};

#[derive(Default)]
pub struct StoreJournal {
    listeners: Mutex<Vec<(u64, Arc<dyn JournalObserver>)>>,
    next: AtomicU64,
}

// A listener hears the stores' writes until this drops with the engine or the marks that hold it, so an engine started
// again never leaves the one it replaced listening.
#[must_use = "the listener stops hearing the stores once this drops"]
pub struct Listening {
    journals: Weak<StoreJournal>,
    id: u64,
}

impl Drop for Listening {
    fn drop(&mut self) {
        if let Some(journals) = self.journals.upgrade() {
            journals
                .listeners
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .retain(|(id, _)| *id != self.id);
        }
    }
}

impl JournalObserver for Journal {
    fn changed(&self, entries: &[JournalEntry]) {
        Journal::changed(self, entries);
    }
}

impl StoreJournal {
    pub fn new() -> Arc<Self> {
        Arc::default()
    }

    // An engine's journal, or the downgrade mirror's marks while no iCloud engine carries them (0054).
    pub fn listen(self: &Arc<Self>, listener: Arc<dyn JournalObserver>) -> Listening {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.listeners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((id, listener));
        Listening {
            journals: Arc::downgrade(self),
            id,
        }
    }

    pub fn listeners(&self) -> usize {
        self.listeners.lock().unwrap_or_else(PoisonError::into_inner).len()
    }
}

fn wire_id(kind: Kind, record: &RecordRef) -> Option<String> {
    match (kind, record) {
        (_, RecordRef::Id(id)) => Some(uuid_id(*id)),
        (_, RecordRef::TeamItem { id, .. }) => Some(id.clone()),
        (Kind::FavouriteTable, RecordRef::Table(table)) => Some(
            favourite_table(
                table.connection_id,
                Some(&table.database),
                Some(&table.schema),
                &table.name,
            )
            .id,
        ),
        (Kind::TableFolderItem, RecordRef::Table(table)) => Some(table_folder_item(
            table.connection_id,
            &table.database,
            Some(&table.schema),
            &table.name,
        )),
        (
            Kind::FavouriteDatabase,
            RecordRef::Database {
                connection_id,
                database,
            },
        ) => Some(favourite_database(*connection_id, database)),
        _ => None,
    }
}

fn entry(entry: &tablepro_storage::JournalEntry) -> Option<JournalEntry> {
    let kind = Kind::parse(entry.kind.as_str()).ok().flatten()?;
    let ids = |records: &[RecordRef]| records.iter().filter_map(|record| wire_id(kind, record)).collect();
    Some(JournalEntry {
        kind,
        written: ids(&entry.written),
        deleted: ids(&entry.deleted),
    })
}

impl ChangeJournal for StoreJournal {
    fn changed(&self, entries: &[tablepro_storage::JournalEntry]) {
        let entries: Vec<JournalEntry> = entries.iter().filter_map(entry).collect();
        if entries.is_empty() {
            return;
        }
        let listeners: Vec<Arc<dyn JournalObserver>> = self
            .listeners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|(_, listener)| Arc::clone(listener))
            .collect();
        for listener in listeners {
            listener.changed(&entries);
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_storage::{JournalEntry as StoreEntry, RecordKind, TableRef};
    use uuid::Uuid;

    use super::*;
    use crate::engine::Wake;

    #[test]
    fn each_engine_hears_a_write_by_the_ids_its_adapters_give_the_records() {
        let journals = StoreJournal::new();
        let (icloud, service) = (Journal::new(Wake::new()), Journal::new(Wake::new()));
        let _icloud = journals.listen(Arc::new(icloud.clone()));
        let _service = journals.listen(Arc::new(service.clone()));
        let query = Uuid::parse_str("e9bfe8be-525f-4f8a-9e9c-f795a5f09a01").unwrap();
        let connection = Uuid::parse_str("6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44").unwrap();
        let table = TableRef {
            connection_id: connection,
            database: "shop".to_owned(),
            schema: "public".to_owned(),
            name: "orders".to_owned(),
        };

        journals.changed(&[
            StoreEntry::new(RecordKind::SavedQuery).deleted([RecordRef::Id(query)]),
            StoreEntry::new(RecordKind::FavouriteTable).wrote([RecordRef::Table(table)]),
        ]);

        for journal in [icloud, service] {
            let named = journal.take();
            assert_eq!(
                named[&Kind::SavedQuery].iter().collect::<Vec<_>>(),
                ["E9BFE8BE-525F-4F8A-9E9C-F795A5F09A01"]
            );
            assert_eq!(
                named[&Kind::FavouriteTable].iter().collect::<Vec<_>>(),
                [&favourite_table(connection, Some("shop"), Some("public"), "orders").id]
            );
        }
    }

    #[test]
    fn a_listener_hears_each_write_once_and_none_after_its_handle_drops() {
        let journals = StoreJournal::new();
        let (kept, replaced) = (Journal::new(Wake::new()), Journal::new(Wake::new()));
        let _kept = journals.listen(Arc::new(kept.clone()));
        let gone = journals.listen(Arc::new(replaced.clone()));
        let id = Uuid::parse_str("e9bfe8be-525f-4f8a-9e9c-f795a5f09a01").unwrap();

        drop(gone);
        journals.changed(&[StoreEntry::new(RecordKind::SavedQuery).wrote([RecordRef::Id(id)])]);

        assert_eq!(journals.listeners(), 1);
        assert_eq!(kept.take()[&Kind::SavedQuery].len(), 1);
        assert!(replaced.take().is_empty());
    }
}
