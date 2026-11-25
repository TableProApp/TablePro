use std::fmt;
use std::sync::{Arc, RwLock};

/// A kind of record a store holds, by its name on the wire (core ADR 0051, Kinds).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum RecordKind {
    Connection,
    Group,
    Tag,
    SshProfile,
    CredentialProfile,
    SavedQuery,
    SavedQueryFolder,
    FavouriteTable,
    FavouriteDatabase,
    TableFolder,
    TableFolderItem,
    HistoryEntry,
    LibraryConnection,
    LibraryFolder,
    LibraryQuery,
}

impl RecordKind {
    pub const ALL: [Self; 15] = [
        Self::Connection,
        Self::Group,
        Self::Tag,
        Self::SshProfile,
        Self::CredentialProfile,
        Self::SavedQuery,
        Self::SavedQueryFolder,
        Self::FavouriteTable,
        Self::FavouriteDatabase,
        Self::TableFolder,
        Self::TableFolderItem,
        Self::HistoryEntry,
        Self::LibraryConnection,
        Self::LibraryFolder,
        Self::LibraryQuery,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Connection => "connection",
            Self::Group => "group",
            Self::Tag => "tag",
            Self::SshProfile => "ssh_profile",
            Self::CredentialProfile => "credential_profile",
            Self::SavedQuery => "saved_query",
            Self::SavedQueryFolder => "saved_query_folder",
            Self::FavouriteTable => "favourite_table",
            Self::FavouriteDatabase => "favourite_database",
            Self::TableFolder => "table_folder",
            Self::TableFolderItem => "table_folder_item",
            Self::HistoryEntry => "history_entry",
            Self::LibraryConnection => "library_connection",
            Self::LibraryFolder => "library_folder",
            Self::LibraryQuery => "library_query",
        }
    }

    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.as_str() == name)
    }
}

impl fmt::Display for RecordKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

// Once per commit, outside the store's locks; the diff decides what goes up, so a missed call loses nothing (0060).
pub trait ChangeJournal: Send + Sync {
    fn changed(&self, entries: &[JournalEntry]);
}

// One kind a commit changed, by the store's own ids, each once, in the order the store lists them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JournalEntry {
    pub kind: RecordKind,
    pub written: Vec<RecordRef>,
    pub deleted: Vec<RecordRef>,
}

impl JournalEntry {
    pub fn new(kind: RecordKind) -> Self {
        Self {
            kind,
            written: Vec::new(),
            deleted: Vec::new(),
        }
    }

    pub fn wrote(mut self, records: impl IntoIterator<Item = RecordRef>) -> Self {
        push_unique(&mut self.written, records);
        self
    }

    pub fn deleted(mut self, records: impl IntoIterator<Item = RecordRef>) -> Self {
        push_unique(&mut self.deleted, records);
        self
    }

    pub fn is_empty(&self) -> bool {
        self.written.is_empty() && self.deleted.is_empty()
    }
}

// A set beside the list, since a write such as clearing the history can name many thousands.
fn push_unique(list: &mut Vec<RecordRef>, records: impl IntoIterator<Item = RecordRef>) {
    let mut seen: std::collections::HashSet<RecordRef> = list.iter().cloned().collect();
    for record in records {
        if seen.insert(record.clone()) {
            list.push(record);
        }
    }
}

// A record as its store names it. The record rules (tablepro-records) write the wire id from it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum RecordRef {
    // A connection, group, tag, SSH or credential profile, or table folder.
    Id(uuid::Uuid),
    // A team library item, by its team and the client id the team stores.
    TeamItem {
        team_id: String,
        id: String,
    },
    // A saved query, saved query folder or history entry, by its row until it carries a record id (0052).
    Row(i64),
    // A favourite table or a table folder item, by the table it names; an absent database or schema is empty.
    Table(crate::TableRef),
    // A favourite database.
    Database {
        connection_id: uuid::Uuid,
        database: String,
    },
}

// Shared by every handle of one store, so a journal set late reaches the handles made before it.
#[derive(Clone, Default)]
pub(crate) struct JournalSlot(Arc<RwLock<Option<Arc<dyn ChangeJournal>>>>);

impl JournalSlot {
    pub(crate) fn set(&self, journal: Option<Arc<dyn ChangeJournal>>) {
        let mut slot = match self.0.write() {
            Ok(slot) => slot,
            Err(poisoned) => poisoned.into_inner(),
        };
        *slot = journal;
    }

    pub(crate) fn notify(&self, entries: &[JournalEntry]) {
        if entries.is_empty() {
            return;
        }
        let journal = match self.0.read() {
            Ok(slot) => slot.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        };
        if let Some(journal) = journal {
            journal.changed(entries);
        }
    }
}

// What a write to one of the history database's tables tells: the views that follow the saved
// queries, then the journal.
#[derive(Debug, Clone)]
pub(crate) struct Signals {
    changes: Arc<tokio::sync::watch::Sender<u64>>,
    journal: JournalSlot,
}

impl Signals {
    pub(crate) fn new(changes: Arc<tokio::sync::watch::Sender<u64>>, journal: JournalSlot) -> Self {
        Self { changes, journal }
    }

    pub(crate) fn subscribe(&self) -> tokio::sync::watch::Receiver<u64> {
        self.changes.subscribe()
    }

    pub(crate) fn changed(&self, entries: &[JournalEntry]) {
        self.changes
            .send_modify(|revision| *revision = revision.wrapping_add(1));
        self.journal.notify(entries);
    }
}

impl fmt::Debug for JournalSlot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("JournalSlot")
    }
}

#[cfg(test)]
pub(crate) mod recording {
    use std::sync::Mutex;

    use super::{ChangeJournal, JournalEntry, RecordKind};

    #[derive(Default)]
    pub(crate) struct Recording(Mutex<Vec<Vec<JournalEntry>>>);

    impl Recording {
        pub(crate) fn calls(&self) -> Vec<Vec<RecordKind>> {
            self.0
                .lock()
                .map(|calls| calls.iter().map(|call| kinds(call)).collect())
                .unwrap_or_default()
        }

        pub(crate) fn take(&self) -> Vec<Vec<RecordKind>> {
            self.take_entries().iter().map(|call| kinds(call)).collect()
        }

        pub(crate) fn take_entries(&self) -> Vec<Vec<JournalEntry>> {
            self.0
                .lock()
                .map(|mut calls| std::mem::take(&mut *calls))
                .unwrap_or_default()
        }
    }

    fn kinds(call: &[JournalEntry]) -> Vec<RecordKind> {
        call.iter().map(|entry| entry.kind).collect()
    }

    impl ChangeJournal for Recording {
        fn changed(&self, entries: &[JournalEntry]) {
            if let Ok(mut calls) = self.0.lock() {
                calls.push(entries.to_vec());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_kind_reads_back_from_its_wire_name() {
        for kind in RecordKind::ALL {
            assert_eq!(RecordKind::parse(kind.as_str()), Some(kind));
        }
        assert_eq!(RecordKind::parse("key.account"), None);
    }

    #[test]
    fn a_slot_reaches_the_journal_set_after_it_was_shared() {
        let slot = JournalSlot::default();
        let shared = slot.clone();
        let journal = Arc::new(recording::Recording::default());

        shared.notify(&[JournalEntry::new(RecordKind::Tag)]);
        slot.set(Some(journal.clone()));
        shared.notify(&[JournalEntry::new(RecordKind::Connection)]);
        shared.notify(&[]);

        assert_eq!(journal.calls(), vec![vec![RecordKind::Connection]]);
    }
}
