use std::ops::{Deref, DerefMut};
use std::sync::MutexGuard;

use super::StoreState;
use crate::journal::{JournalEntry, JournalSlot};

// Holds the store's mutex and the lock file from the re-read to the rename. What a commit changed
// reaches the journal once both are released, in one call, so a journal that calls into another
// language never runs under them.
pub(super) struct WriteGuard<'a> {
    state: Option<MutexGuard<'a, StoreState>>,
    file: Option<std::fs::File>,
    journal: &'a JournalSlot,
    changed: Vec<JournalEntry>,
}

impl<'a> WriteGuard<'a> {
    pub(super) fn new(
        state: MutexGuard<'a, StoreState>,
        file: Option<std::fs::File>,
        journal: &'a JournalSlot,
    ) -> Self {
        Self {
            state: Some(state),
            file,
            journal,
            changed: Vec::new(),
        }
    }

    pub(super) fn changed(&mut self, entries: impl IntoIterator<Item = JournalEntry>) {
        for entry in entries {
            match self.changed.iter_mut().find(|held| held.kind == entry.kind) {
                Some(held) => {
                    *held = std::mem::replace(held, JournalEntry::new(entry.kind))
                        .wrote(entry.written)
                        .deleted(entry.deleted)
                }
                None => self.changed.push(entry),
            }
        }
    }
}

impl Deref for WriteGuard<'_> {
    type Target = StoreState;

    fn deref(&self) -> &StoreState {
        match &self.state {
            Some(state) => state,
            None => unreachable!("the state is held until the guard drops"),
        }
    }
}

impl DerefMut for WriteGuard<'_> {
    fn deref_mut(&mut self) -> &mut StoreState {
        match &mut self.state {
            Some(state) => state,
            None => unreachable!("the state is held until the guard drops"),
        }
    }
}

impl Drop for WriteGuard<'_> {
    fn drop(&mut self) {
        drop(self.state.take());
        drop(self.file.take());
        // A panic mid-write leaves nothing committed to tell about.
        if !std::thread::panicking() {
            self.changed.sort_by_key(|entry| entry.kind);
            self.journal.notify(&self.changed);
        }
    }
}
