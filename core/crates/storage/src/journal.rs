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

/// What every store's write path tells once a write has landed (core ADR 0054, The engine).
///
/// It names the kinds the write changed and asks for a pass soon. The sync diff, not the journal,
/// decides what goes up, so a missed call delays a push and loses nothing. A store calls it after the
/// write, outside every lock it holds, from the thread that wrote; it must return at once.
pub trait ChangeJournal: Send + Sync {
    fn changed(&self, kinds: &[RecordKind]);
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

    pub(crate) fn notify(&self, kinds: &[RecordKind]) {
        if kinds.is_empty() {
            return;
        }
        let journal = match self.0.read() {
            Ok(slot) => slot.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        };
        if let Some(journal) = journal {
            journal.changed(kinds);
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

    pub(crate) fn changed(&self, kinds: &[RecordKind]) {
        self.changes
            .send_modify(|revision| *revision = revision.wrapping_add(1));
        self.journal.notify(kinds);
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

    use super::{ChangeJournal, RecordKind};

    #[derive(Default)]
    pub(crate) struct Recording(Mutex<Vec<Vec<RecordKind>>>);

    impl Recording {
        pub(crate) fn calls(&self) -> Vec<Vec<RecordKind>> {
            self.0.lock().map(|calls| calls.clone()).unwrap_or_default()
        }

        pub(crate) fn take(&self) -> Vec<Vec<RecordKind>> {
            self.0
                .lock()
                .map(|mut calls| std::mem::take(&mut *calls))
                .unwrap_or_default()
        }
    }

    impl ChangeJournal for Recording {
        fn changed(&self, kinds: &[RecordKind]) {
            if let Ok(mut calls) = self.0.lock() {
                calls.push(kinds.to_vec());
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

        shared.notify(&[RecordKind::Tag]);
        slot.set(Some(journal.clone()));
        shared.notify(&[RecordKind::Connection]);
        shared.notify(&[]);

        assert_eq!(journal.calls(), vec![vec![RecordKind::Connection]]);
    }
}
