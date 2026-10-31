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
    keys: RefCell<Vec<(SessionKey, Holder)>>,
    frozen: Cell<bool>,
}

/// Which window a key belongs to, so the record groups the keys the way
/// the windows held them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Holder {
    Window(u32),
    /// A recorded window's keys, by their place in the record, until the
    /// window that reopens them is known. Window ids restart with each
    /// launch, so no recorded one can stand in for it.
    Restoring(usize),
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
    /// and return them by window, for each group to reopen in a window of
    /// its own. Each restored window removes a key again if it cannot
    /// open it.
    pub fn restore(&self, record: OpenSessionsRecord) -> Vec<Vec<SessionKey>> {
        let restored = record.windows();
        let opened_since = {
            let mut keys = self.keys.borrow_mut();
            let opened_since: Vec<(SessionKey, Holder)> = keys
                .drain(..)
                .filter(|(key, _)| !restored.iter().flatten().any(|recorded| recorded == key))
                .collect();
            for (place, window) in restored.iter().enumerate() {
                keys.extend(window.iter().map(|key| (key.clone(), Holder::Restoring(place))));
            }
            keys.extend(opened_since.iter().cloned());
            opened_since
        };
        if !opened_since.is_empty() {
            self.write();
        }
        restored
    }

    /// Record that `window` holds `key`. A key already open moves to
    /// `window`, as a restored key does once its window opens.
    pub fn add(&self, key: SessionKey, window: u32) {
        {
            let mut keys = self.keys.borrow_mut();
            let holder = Holder::Window(window);
            match keys.iter().position(|(kept, _)| kept == &key) {
                Some(at) if keys[at].1 == holder => return,
                // A restored key keeps its place in the recorded window.
                Some(at) if matches!(keys[at].1, Holder::Restoring(_)) => keys[at].1 = holder,
                // A key another window gave up is adopted here now, after
                // the keys this window already holds.
                Some(at) => {
                    keys.remove(at);
                    keys.push((key, holder));
                }
                None => keys.push((key, holder)),
            }
        }
        self.write();
    }

    /// Give the window that reopens a recorded group the keys of that
    /// group it still holds. Unlike `add`, a key the window already
    /// removed, because it could not open it, stays removed.
    pub fn assign(&self, keys: &[SessionKey], window: u32) {
        let changed = {
            let mut held = self.keys.borrow_mut();
            let mut changed = false;
            for (key, holder) in held.iter_mut() {
                if keys.contains(key) && *holder != Holder::Window(window) {
                    *holder = Holder::Window(window);
                    changed = true;
                }
            }
            changed
        };
        if changed {
            self.write();
        }
    }

    /// Ignored while a quit runs: the windows it closes are the ones the
    /// next launch reopens. A connection's other databases go with it,
    /// since they reopen only beside it (0030).
    pub fn remove(&self, key: &SessionKey) {
        if self.frozen.get() {
            return;
        }
        {
            let mut keys = self.keys.borrow_mut();
            let before = keys.len();
            keys.retain(|(kept, _)| kept != key && !opens_beside(kept, key));
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
        self.keys.borrow_mut().retain(|(key, _)| live(key));
        self.frozen.set(false);
        self.write();
    }

    /// After an approved quit, go back to how a launch starts: nothing
    /// open and nothing frozen, so the next restore reads the record
    /// from disk.
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
        self.keys.borrow().iter().map(|(key, _)| key.clone()).collect()
    }

    /// Windows in the order their first key came, keys in the order each
    /// came.
    fn record(&self) -> OpenSessionsRecord {
        let keys = self.keys.borrow();
        let mut windows: Vec<(Holder, Vec<&SessionKey>)> = Vec::new();
        for (key, holder) in keys.iter() {
            match windows.iter_mut().find(|(kept, _)| kept == holder) {
                Some((_, window)) => window.push(key),
                None => windows.push((*holder, vec![key])),
            }
        }
        OpenSessionsRecord::from_windows(windows.into_iter().map(|(_, window)| window))
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

/// Whether `kept` is another database of the connection `key`.
fn opens_beside(kept: &SessionKey, key: &SessionKey) -> bool {
    matches!((kept, key), (SessionKey::SavedIn { id, .. }, SessionKey::Saved(of)) if id == of)
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
            self.windows_on_disk().into_iter().flatten().collect()
        }

        /// The keys on disk by window, once every write has landed.
        fn windows_on_disk(&self) -> Vec<Vec<SessionKey>> {
            wait_until(WAIT, || self.hold.live() == 0).expect("the writes to land");
            let path = self.path();
            let bytes = std::fs::read(&path).expect("the record was written");
            decode_document::<OpenSessionsRecord>(Path::new(&path), &bytes)
                .expect("a record")
                .windows()
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

        fixture.sessions.add(first.clone(), 1);
        fixture.sessions.add(second.clone(), 1);
        fixture.sessions.add(first.clone(), 1);

        assert_eq!(fixture.sessions.keys(), [first.clone(), second.clone()]);
        assert_eq!(fixture.on_disk(), [first, second]);
    }

    /// A connection's other databases reopen only beside it, so they go
    /// from the record with it.
    #[gtk4::test]
    fn removing_a_connection_removes_its_other_databases() {
        let fixture = Fixture::new();
        let connection = saved();
        let SessionKey::Saved(id) = connection else {
            panic!("a saved key");
        };
        let database = SessionKey::SavedIn {
            id,
            database: "analytics".to_owned(),
        };
        let other = SessionKey::SavedIn {
            id: Uuid::new_v4(),
            database: "analytics".to_owned(),
        };
        for key in [&connection, &database, &other] {
            fixture.sessions.add(key.clone(), 1);
        }

        fixture.sessions.remove(&connection);

        assert_eq!(fixture.sessions.keys(), std::slice::from_ref(&other));
        assert_eq!(fixture.on_disk(), [other]);
    }

    #[gtk4::test]
    fn a_write_holds_the_process_until_it_lands() {
        let fixture = Fixture::new();

        fixture.sessions.add(saved(), 1);

        assert!(fixture.hold.live() > 0, "the write started without holding the process");
        wait_until(WAIT, || fixture.hold.live() == 0).expect("the hold to end");
        assert!(fixture.path().exists(), "the hold ended before the write");
    }

    #[gtk4::test]
    fn quit_freeze_keeps_keys_window_close_removes() {
        let fixture = Fixture::new();
        let (closed, kept) = (saved(), saved());
        fixture.sessions.add(closed.clone(), 1);
        fixture.sessions.add(kept.clone(), 1);

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
        fixture.sessions.add(closed.clone(), 1);
        fixture.sessions.add(open.clone(), 1);
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
        fixture.sessions.add(opened_since.clone(), 1);

        let reopen = fixture
            .sessions
            .restore(OpenSessionsRecord::from_windows([[&recorded]]));

        assert_eq!(reopen, [vec![recorded.clone()]]);
        assert_eq!(fixture.sessions.keys(), [recorded.clone(), opened_since.clone()]);
        assert_eq!(fixture.on_disk(), [recorded, opened_since]);
    }

    #[gtk4::test]
    fn a_key_moved_to_another_window_is_written_there() {
        let fixture = Fixture::new();
        let (moved, stays) = (saved(), saved());
        fixture.sessions.add(moved.clone(), 1);
        fixture.sessions.add(stays.clone(), 1);
        wait_until(WAIT, || fixture.hold.live() == 0).expect("the adds to land");

        fixture.sessions.add(moved.clone(), 2);

        assert!(fixture.hold.live() > 0, "the move was not written");
        assert_eq!(fixture.windows_on_disk(), [vec![stays], vec![moved]]);
    }

    #[gtk4::test]
    fn the_record_groups_keys_by_window_in_first_seen_order() {
        let fixture = Fixture::new();
        let (first, second, third) = (saved(), saved(), saved());

        fixture.sessions.add(first.clone(), 7);
        fixture.sessions.add(second.clone(), 3);
        fixture.sessions.add(third.clone(), 7);

        assert_eq!(
            fixture.sessions.record().windows(),
            [vec![first.clone(), third.clone()], vec![second.clone()]]
        );
        assert_eq!(fixture.windows_on_disk(), [vec![first, third], vec![second]]);
    }

    #[gtk4::test]
    fn restore_keeps_the_recorded_windows_until_each_is_assigned() {
        let fixture = Fixture::new();
        let (first, second, alone, opened_since) = (saved(), saved(), saved(), saved());
        fixture.sessions.add(opened_since.clone(), 1);

        let reopen = fixture
            .sessions
            .restore(OpenSessionsRecord::from_windows([vec![&first, &second], vec![&alone]]));

        assert_eq!(reopen, [vec![first.clone(), second.clone()], vec![alone.clone()]]);
        assert_eq!(
            fixture.windows_on_disk(),
            [
                vec![first.clone(), second.clone()],
                vec![alone.clone()],
                vec![opened_since.clone()]
            ]
        );
        fixture.sessions.assign(&[first.clone(), second.clone()], 1);
        fixture.sessions.assign(std::slice::from_ref(&alone), 2);
        assert_eq!(
            fixture.windows_on_disk(),
            [vec![first, second, opened_since], vec![alone]],
            "a restored window kept a recorded place, or a key its window id"
        );
    }

    #[gtk4::test]
    fn assign_leaves_a_removed_key_removed() {
        let fixture = Fixture::new();
        let (failed, opened) = (saved(), saved());
        fixture
            .sessions
            .restore(OpenSessionsRecord::from_windows([[&failed, &opened]]));
        fixture.sessions.remove(&failed);

        fixture.sessions.assign(&[failed, opened.clone()], 4);

        assert_eq!(fixture.sessions.keys(), std::slice::from_ref(&opened));
        assert_eq!(fixture.windows_on_disk(), [vec![opened]]);
    }

    #[gtk4::test]
    fn flush_writes_the_keys_as_they_are() {
        let fixture = Fixture::new();
        let key = saved();
        fixture.sessions.add(key.clone(), 1);
        wait_until(WAIT, || fixture.hold.live() == 0).expect("the add to land");
        std::fs::remove_file(fixture.path()).expect("remove the record");

        crate::test_support::finish_on_main(WAIT, fixture.sessions.flush()).expect("the flush to finish");

        assert_eq!(fixture.on_disk(), [key]);
    }
}
