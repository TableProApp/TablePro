use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gtk4::glib;
use tablepro_session::SessionKey;
use tablepro_session::runtime::ProcessHold;

use super::{OpenSessionsLoad, OpenSessionsRecord, WorkspaceStore};

/// The sessions the windows show, kept on disk so the next launch opens
/// them again. GTK-thread only.
///
/// A quit freezes the list before it asks the first window, so a window
/// it closes stays on it; a cancelled quit thaws it to the windows still
/// open, and an approved one empties it once it is on disk.
pub struct OpenSessions {
    store: WorkspaceStore,
    /// Each write keeps the process up until it lands, since closing the
    /// last window would otherwise end it, and the writer with it.
    hold: Rc<dyn ProcessHold>,
    keys: RefCell<Vec<SessionKey>>,
    frozen: Cell<bool>,
}

impl OpenSessions {
    pub fn new(store: WorkspaceStore, hold: Rc<dyn ProcessHold>) -> Rc<Self> {
        Rc::new(Self {
            store,
            hold,
            keys: RefCell::new(Vec::new()),
            frozen: Cell::new(false),
        })
    }

    pub fn load(&self) -> impl Future<Output = OpenSessionsLoad> + use<> {
        self.store.load_open_sessions()
    }

    /// Take the recorded keys as open, ahead of any opened since launch,
    /// and return the ones to reopen. Each restored window removes its
    /// key again if it cannot open it.
    pub fn restore(&self, record: OpenSessionsRecord) -> Vec<SessionKey> {
        let restored = record.keys();
        let opened_since = {
            let mut keys = self.keys.borrow_mut();
            let opened_since: Vec<SessionKey> = keys.drain(..).filter(|key| !restored.contains(key)).collect();
            keys.extend(restored.iter().cloned());
            keys.extend(opened_since.iter().cloned());
            opened_since
        };
        if !opened_since.is_empty() {
            self.write();
        }
        restored
    }

    pub fn add(&self, key: SessionKey) {
        {
            let mut keys = self.keys.borrow_mut();
            if keys.contains(&key) {
                return;
            }
            keys.push(key);
        }
        self.write();
    }

    /// Ignored while a quit runs: the windows it closes are the ones the
    /// next launch reopens.
    pub fn remove(&self, key: &SessionKey) {
        if self.frozen.get() {
            return;
        }
        {
            let mut keys = self.keys.borrow_mut();
            let before = keys.len();
            keys.retain(|kept| kept != key);
            if keys.len() == before {
                return;
            }
        }
        self.write();
    }

    /// Stop removing keys until `thaw`, for the length of a quit or the
    /// application's shutdown.
    pub fn freeze_for_quit(&self) {
        self.frozen.set(true);
    }

    /// Keep the keys `live` still names, after a quit the user cancelled
    /// partway, and start removing keys again.
    pub fn thaw(&self, live: impl Fn(&SessionKey) -> bool) {
        self.keys.borrow_mut().retain(|key| live(key));
        self.frozen.set(false);
        self.write();
    }

    /// After an approved quit has written the record, go back to how a
    /// launch starts: nothing open and nothing frozen, so the next
    /// restore reads the record from disk.
    pub fn end_quit(&self) {
        self.keys.borrow_mut().clear();
        self.frozen.set(false);
    }

    /// Write the keys as they are now; resolves once they are on disk.
    pub fn flush(&self) -> impl Future<Output = ()> + use<> {
        let scheduled = self.store.schedule_open_sessions(self.record());
        let written = self.store.flush_open_sessions();
        async move {
            if let Err(error) = scheduled.and(written.await) {
                tracing::warn!(%error, "could not record which sessions are open");
            }
        }
    }

    /// Resolves once every write already scheduled is on disk.
    #[cfg(test)]
    pub(crate) fn settled(&self) -> impl Future<Output = ()> + use<> {
        let written = self.store.flush_open_sessions();
        async move {
            let _ = written.await;
        }
    }

    #[cfg(test)]
    pub(crate) fn keys(&self) -> Vec<SessionKey> {
        self.keys.borrow().clone()
    }

    fn record(&self) -> OpenSessionsRecord {
        OpenSessionsRecord::from_keys(self.keys.borrow().iter())
    }

    fn write(&self) {
        let token = self.hold.acquire();
        let flushing = self.flush();
        glib::spawn_future_local(async move {
            flushing.await;
            drop(token);
        });
    }
}

impl std::fmt::Debug for OpenSessions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenSessions")
            .field("keys", &self.keys.borrow())
            .field("frozen", &self.frozen.get())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use tablepro_session::runtime::CountingHold;
    use tablepro_storage::document::decode_document;
    use uuid::Uuid;

    use super::*;
    use crate::test_support::wait_until;

    const WAIT: Duration = Duration::from_secs(10);

    struct Fixture {
        runtime: Option<crate::runtime::AppRuntime>,
        dir: tempfile::TempDir,
        hold: Rc<CountingHold>,
        sessions: Rc<OpenSessions>,
    }

    impl Fixture {
        fn new() -> Self {
            let runtime = crate::test_support::test_runtime();
            let dir = tempfile::tempdir().expect("tempdir");
            let store = WorkspaceStore::start(
                dir.path().to_owned(),
                tablepro_storage::DraftStore::new(dir.path().join("drafts")),
                &runtime.tasks(),
            );
            let hold = Rc::new(CountingHold::new());
            let sessions = OpenSessions::new(store, hold.clone());
            Self {
                runtime: Some(runtime),
                dir,
                hold,
                sessions,
            }
        }

        fn path(&self) -> PathBuf {
            self.dir.path().join(OpenSessionsRecord::FILE_NAME)
        }

        /// The keys on disk once every write has landed.
        fn on_disk(&self) -> Vec<SessionKey> {
            wait_until(WAIT, || self.hold.live() == 0).expect("the writes to land");
            let path = self.path();
            let bytes = std::fs::read(&path).expect("the record was written");
            decode_document::<OpenSessionsRecord>(Path::new(&path), &bytes)
                .expect("a record")
                .keys()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            if let Some(runtime) = self.runtime.take() {
                runtime.shutdown();
            }
        }
    }

    fn saved() -> SessionKey {
        SessionKey::Saved(Uuid::new_v4())
    }

    #[gtk4::test]
    fn add_records_each_key_once_in_order() {
        let fixture = Fixture::new();
        let (first, second) = (saved(), SessionKey::File("file:///srv/app.db".to_owned()));

        fixture.sessions.add(first.clone());
        fixture.sessions.add(second.clone());
        fixture.sessions.add(first.clone());

        assert_eq!(fixture.sessions.keys(), [first.clone(), second.clone()]);
        assert_eq!(fixture.on_disk(), [first, second]);
    }

    #[gtk4::test]
    fn a_write_holds_the_process_until_it_lands() {
        let fixture = Fixture::new();

        fixture.sessions.add(saved());

        assert!(fixture.hold.live() > 0, "the write started without holding the process");
        wait_until(WAIT, || fixture.hold.live() == 0).expect("the hold to end");
        assert!(fixture.path().exists(), "the hold ended before the write");
    }

    #[gtk4::test]
    fn quit_freeze_keeps_keys_window_close_removes() {
        let fixture = Fixture::new();
        let (closed, kept) = (saved(), saved());
        fixture.sessions.add(closed.clone());
        fixture.sessions.add(kept.clone());

        fixture.sessions.remove(&closed);
        assert_eq!(
            fixture.sessions.keys(),
            std::slice::from_ref(&kept),
            "a window close kept its key"
        );
        fixture.sessions.freeze_for_quit();
        fixture.sessions.remove(&kept);

        assert_eq!(
            fixture.sessions.keys(),
            std::slice::from_ref(&kept),
            "the quit forgot a window it closed"
        );
        assert_eq!(fixture.on_disk(), [kept]);
    }

    #[gtk4::test]
    fn cancelled_quit_thaws_to_live_keys() {
        let fixture = Fixture::new();
        let (closed, open) = (saved(), saved());
        fixture.sessions.add(closed.clone());
        fixture.sessions.add(open.clone());
        fixture.sessions.freeze_for_quit();
        fixture.sessions.remove(&closed);

        fixture.sessions.thaw(|key| key == &open);

        assert_eq!(fixture.sessions.keys(), std::slice::from_ref(&open));
        assert_eq!(fixture.on_disk(), std::slice::from_ref(&open));
        fixture.sessions.remove(&open);
        assert!(
            fixture.sessions.keys().is_empty(),
            "a thawed list still ignores removals"
        );
    }

    #[gtk4::test]
    fn restore_puts_the_recorded_keys_first() {
        let fixture = Fixture::new();
        let (recorded, opened_since) = (saved(), saved());
        fixture.sessions.add(opened_since.clone());

        let reopen = fixture.sessions.restore(OpenSessionsRecord::from_keys([&recorded]));

        assert_eq!(reopen, std::slice::from_ref(&recorded));
        assert_eq!(fixture.sessions.keys(), [recorded.clone(), opened_since.clone()]);
        assert_eq!(fixture.on_disk(), [recorded, opened_since]);
    }

    #[gtk4::test]
    fn flush_writes_the_keys_as_they_are() {
        let fixture = Fixture::new();
        let key = saved();
        fixture.sessions.add(key.clone());
        wait_until(WAIT, || fixture.hold.live() == 0).expect("the add to land");
        std::fs::remove_file(fixture.path()).expect("remove the record");

        crate::test_support::finish_on_main(WAIT, fixture.sessions.flush()).expect("the flush to finish");

        assert_eq!(fixture.on_disk(), [key]);
    }
}
