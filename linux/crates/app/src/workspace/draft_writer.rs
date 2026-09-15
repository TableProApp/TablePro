use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use gtk4::glib;
use gtk4::prelude::*;
use tablepro_session::runtime::{LatestWinsWriter, Tasks};
use tablepro_storage::{DraftId, DraftScope, DraftStore};

use super::PersistDebouncer;

/// How long after the last keystroke the editor text is written.
///
/// Long enough that typing costs nothing, short enough that a crash
/// loses at most half a second of work.
const WRITE_DELAY: Duration = Duration::from_millis(500);

/// Keeps every open editor tab's text on disk, behind the user.
///
/// The buffer is read once per write rather than once per keystroke,
/// so a 5 MiB script costs nothing to type in, and the write itself
/// runs on a blocking thread.
pub struct DraftWriter {
    store: DraftStore,
    tasks: Tasks,
    slots: RefCell<HashMap<DraftId, Rc<Slot>>>,
    failures: Arc<Mutex<Vec<String>>>,
}

struct Slot {
    buffer: glib::WeakRef<gtk4::TextBuffer>,
    debouncer: PersistDebouncer,
    writer: LatestWinsWriter<String>,
}

impl DraftWriter {
    pub fn new(store: DraftStore, tasks: Tasks) -> Rc<Self> {
        Rc::new(Self {
            store,
            tasks,
            slots: RefCell::new(HashMap::new()),
            failures: Arc::new(Mutex::new(Vec::new())),
        })
    }

    /// Note that this tab's text changed. The first call for an id also
    /// starts tracking the buffer.
    pub fn schedule(self: &Rc<Self>, scope: &DraftScope, id: DraftId, buffer: &gtk4::TextBuffer) {
        let slot = self.slot(scope, id, buffer);
        let writer = self.clone();
        slot.debouncer.request(move || writer.write_now(id));
    }

    /// Write every open tab's pending text and resolve once all of it
    /// is on disk, reporting what could not be written.
    pub fn flush_all(&self) -> impl Future<Output = Vec<String>> + Send + use<> {
        let ids: Vec<DraftId> = self.slots.borrow().keys().copied().collect();
        for id in &ids {
            self.write_now(*id);
        }
        let slots: Vec<Rc<Slot>> = {
            let open = self.slots.borrow();
            ids.iter().filter_map(|id| open.get(id).cloned()).collect()
        };
        let pending: Vec<_> = slots.iter().map(|slot| slot.writer.flush()).collect();
        let failures = self.failures.clone();
        async move {
            for write in pending {
                write.await;
            }
            std::mem::take(&mut *failures.lock().unwrap_or_else(PoisonError::into_inner))
        }
    }

    /// Stop tracking a tab and delete its draft, for a tab the user
    /// closed.
    pub fn discard(&self, scope: &DraftScope, id: DraftId) {
        self.slots.borrow_mut().remove(&id);
        let store = self.store.clone();
        let scope = scope.clone();
        let failures = self.failures.clone();
        self.tasks.spawn_blocking_task(move || {
            if let Err(error) = store.delete_blocking(&scope, id) {
                record(&failures, &error);
            }
        });
    }

    /// Delete every draft in the scope that no open tab references.
    pub fn retain(&self, scope: &DraftScope, keep: HashSet<DraftId>) {
        let store = self.store.clone();
        let scope = scope.clone();
        let failures = self.failures.clone();
        self.tasks
            .spawn_blocking_task(move || match store.retain_blocking(&scope, &keep) {
                Ok(0) => {}
                Ok(removed) => tracing::info!(removed, scope = %scope, "removed drafts no tab references"),
                Err(error) => record(&failures, &error),
            });
    }

    pub fn store(&self) -> &DraftStore {
        &self.store
    }

    fn slot(&self, scope: &DraftScope, id: DraftId, buffer: &gtk4::TextBuffer) -> Rc<Slot> {
        let mut slots = self.slots.borrow_mut();
        if let Some(slot) = slots.get(&id) {
            return slot.clone();
        }
        let store = self.store.clone();
        let scope_for_writes = scope.clone();
        let failures = self.failures.clone();
        let writer = LatestWinsWriter::spawn(&self.tasks, move |text: &String| {
            if let Err(error) = store.write_blocking(&scope_for_writes, id, text) {
                record(&failures, &error);
            }
        });
        let slot = Rc::new(Slot {
            buffer: {
                let weak = glib::WeakRef::new();
                weak.set(Some(buffer));
                weak
            },
            debouncer: PersistDebouncer::new(WRITE_DELAY),
            writer,
        });
        slots.insert(id, slot.clone());
        slot
    }

    /// Read the buffer once and hand the text to the writer. A buffer
    /// whose tab has gone leaves the draft as it was, so closing a tab
    /// does not blank what it last held.
    fn write_now(&self, id: DraftId) {
        let Some(slot) = self.slots.borrow().get(&id).cloned() else {
            return;
        };
        slot.debouncer.cancel();
        let Some(buffer) = slot.buffer.upgrade() else {
            return;
        };
        let text = buffer.text(&buffer.start_iter(), &buffer.end_iter(), true).to_string();
        slot.writer.put(text);
    }
}

fn record(failures: &Arc<Mutex<Vec<String>>>, error: &tablepro_storage::StorageError) {
    tracing::warn!(%error, "could not save the editor draft");
    failures
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push(error.to_string());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{test_runtime, wait_until};

    const WAIT: Duration = Duration::from_secs(5);

    struct Fixture {
        _runtime: crate::runtime::AppRuntime,
        _root: tempfile::TempDir,
        writer: Rc<DraftWriter>,
        scope: DraftScope,
    }

    impl Fixture {
        fn new() -> Self {
            let runtime = test_runtime();
            let root = tempfile::tempdir().expect("tempdir");
            let store = DraftStore::new(root.path().join("drafts"));
            let writer = DraftWriter::new(store, runtime.tasks());
            Self {
                _runtime: runtime,
                _root: root,
                writer,
                scope: DraftScope::new("workspace_state").expect("a scope"),
            }
        }

        fn read(&self, id: DraftId) -> Option<String> {
            self.writer
                .store()
                .read_blocking(&self.scope, id)
                .expect("read the draft")
        }

        /// Write everything pending and drive the GTK loop until it has
        /// landed.
        fn flush_all(&self) -> Vec<String> {
            let flushing = self.writer.flush_all();
            let failures = Rc::new(RefCell::new(None));
            let failures_for_task = failures.clone();
            glib::spawn_future_local(async move {
                *failures_for_task.borrow_mut() = Some(flushing.await);
            });
            wait_until(WAIT, || failures.borrow().is_some()).expect("flush never resolved");
            let taken = failures.borrow_mut().take();
            taken.unwrap_or_default()
        }

        /// Drive the GTK loop until the draft file says what the buffer
        /// does, or give up.
        fn wait_for(&self, id: DraftId, expected: &str) {
            wait_until(WAIT, || self.read(id).as_deref() == Some(expected))
                .unwrap_or_else(|_| panic!("the draft never became {expected:?}, it is {:?}", self.read(id)));
        }
    }

    #[gtk4::test]
    fn ten_inserts_one_write_with_final_text() {
        let fixture = Fixture::new();
        let id = DraftId::new();
        let buffer = gtk4::TextBuffer::new(None);

        for step in 0..10 {
            buffer.set_text(&format!("SELECT {step}"));
            fixture.writer.schedule(&fixture.scope, id, &buffer);
        }
        fixture.wait_for(id, "SELECT 9");
    }

    #[gtk4::test]
    fn flush_writes_pending_immediately() {
        let fixture = Fixture::new();
        let id = DraftId::new();
        let buffer = gtk4::TextBuffer::new(None);
        buffer.set_text("SELECT 1");
        fixture.writer.schedule(&fixture.scope, id, &buffer);
        assert_eq!(fixture.read(id), None, "the write happened before the delay");

        let failures = fixture.flush_all();

        assert!(failures.is_empty(), "{failures:?}");
        assert_eq!(fixture.read(id).as_deref(), Some("SELECT 1"));
    }

    #[gtk4::test]
    fn discard_deletes_file() {
        let fixture = Fixture::new();
        let id = DraftId::new();
        let buffer = gtk4::TextBuffer::new(None);
        buffer.set_text("SELECT 1");
        fixture.writer.schedule(&fixture.scope, id, &buffer);
        fixture.wait_for(id, "SELECT 1");

        fixture.writer.discard(&fixture.scope, id);

        wait_until(WAIT, || fixture.read(id).is_none()).expect("the draft file stayed");
    }

    #[gtk4::test]
    fn restore_300_kib_script_is_byte_identical() {
        let fixture = Fixture::new();
        let id = DraftId::new();
        // Past the 256 KiB the workspace file used to truncate at, with
        // multibyte characters across the old boundary.
        let script = "SELECT 'é☃𝄞', 1;\n".repeat(300 * 1024 / 20);
        assert!(script.len() > 256 * 1024);
        let buffer = gtk4::TextBuffer::new(None);
        buffer.set_text(&script);

        fixture.writer.schedule(&fixture.scope, id, &buffer);

        fixture.wait_for(id, &script);
    }

    #[gtk4::test]
    fn a_closed_buffer_leaves_the_draft_as_it_was() {
        let fixture = Fixture::new();
        let id = DraftId::new();
        {
            let buffer = gtk4::TextBuffer::new(None);
            buffer.set_text("SELECT 1");
            fixture.writer.schedule(&fixture.scope, id, &buffer);
            fixture.wait_for(id, "SELECT 1");
        }

        // The tab is gone, so there is nothing to read the text from.
        fixture.flush_all();

        assert_eq!(fixture.read(id).as_deref(), Some("SELECT 1"));
    }

    #[gtk4::test]
    fn retain_removes_the_drafts_no_tab_references() {
        let fixture = Fixture::new();
        let kept = DraftId::new();
        let dropped = DraftId::new();
        for id in [kept, dropped] {
            let buffer = gtk4::TextBuffer::new(None);
            buffer.set_text("SELECT 1");
            fixture.writer.schedule(&fixture.scope, id, &buffer);
            fixture.wait_for(id, "SELECT 1");
        }

        fixture.writer.retain(&fixture.scope, HashSet::from([kept]));

        wait_until(WAIT, || fixture.read(dropped).is_none()).expect("the unreferenced draft stayed");
        assert_eq!(fixture.read(kept).as_deref(), Some("SELECT 1"));
    }
}
