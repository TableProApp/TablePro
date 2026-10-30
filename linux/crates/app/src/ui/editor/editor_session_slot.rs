use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::Duration;

use tablepro_core::{CallOptions, EditorSession, EditorSessionOptions, EditorSessionState, TransactionState};
use tablepro_session::{OperationError, Session};
use tokio_util::sync::CancellationToken;

/// The editor tab's own connection, shared with the run on the runtime.
///
/// The run opens it and the tab closes it, possibly while a run is
/// still opening one, so the slot remembers it was closed and a session
/// opened after that is handed back to be closed rather than kept.
///
/// A session whose connection went with a transaction open is never
/// replaced on the same run: the next statement would commit on its
/// own, outside the transaction the user thinks is still open. Unless
/// the run that lost it already said so, that run is refused with the
/// reason, and only the one after it opens a new session.
#[derive(Default)]
pub struct EditorSessionSlot {
    state: Mutex<SlotState>,
}

#[derive(Default)]
struct SlotState {
    open: Option<OpenEditor>,
    /// A session was lost with a transaction open, and no run has been
    /// told yet.
    rolled_back: bool,
    closed: bool,
    /// The database the tab works in once it left the connection's: picked
    /// from the editor bar, restored, or where a `USE` left its session.
    database: Option<String>,
}

struct OpenEditor {
    /// The window session it was opened from. A tab outliving a switch
    /// to another database must not run on the old one.
    owner: Weak<Session>,
    editor: Arc<dyn EditorSession>,
    /// Where the transaction stood after the last run that reported it.
    transaction: Option<TransactionState>,
}

enum Lookup {
    Ready(Arc<dyn EditorSession>),
    /// None usable; `stale` is one to close before opening another.
    Missing {
        stale: Option<Arc<dyn EditorSession>>,
    },
    /// The session went with a transaction open; `stale` is it, when it
    /// is still to be closed.
    RolledBack {
        stale: Option<Arc<dyn EditorSession>>,
    },
    Closed,
}

/// Why a run got no editor session.
#[derive(Debug)]
pub enum AcquireError {
    /// The tab closed or the run was stopped while it opened.
    Cancelled,
    /// The session's connection was lost with a transaction open, which
    /// the server rolled back. Nothing was opened in its place.
    TransactionRolledBack,
    /// The tab could not get to its database, so it stays where its
    /// session is.
    Moved {
        database: String,
        reason: String,
    },
    Failed(String),
}

impl EditorSessionSlot {
    pub fn new() -> Self {
        Self::default()
    }

    /// The tab's editor session, opening one first when the tab has
    /// none, or only one that was lost or belongs to a session the
    /// window has since replaced.
    pub async fn acquire(
        &self,
        session: &Arc<Session>,
        statement_timeout: Option<Duration>,
        close_timeout: Duration,
        cancel: &CancellationToken,
    ) -> Result<Arc<dyn EditorSession>, AcquireError> {
        let stale = match self.lookup(session) {
            Lookup::Ready(editor) => {
                return self
                    .reach_database(session, editor, (statement_timeout, close_timeout), cancel)
                    .await;
            }
            Lookup::Closed => return Err(AcquireError::Cancelled),
            Lookup::RolledBack { stale } => {
                if let Some(stale) = stale {
                    close_quietly(stale, close_timeout).await;
                }
                return Err(AcquireError::TransactionRolledBack);
            }
            Lookup::Missing { stale } => stale,
        };
        if let Some(stale) = stale {
            close_quietly(stale, close_timeout).await;
        }
        let options = EditorSessionOptions {
            statement_timeout,
            database: self.database(),
        };
        match session.open_editor_session(options, cancel).await {
            Ok(editor) => match self.adopt(session, editor.clone()) {
                Ok(()) => {
                    self.reach_database(session, editor, (statement_timeout, close_timeout), cancel)
                        .await
                }
                Err(orphan) => {
                    close_quietly(orphan, close_timeout).await;
                    Err(AcquireError::Cancelled)
                }
            },
            Err(OperationError::Cancelled) => Err(AcquireError::Cancelled),
            Err(error) => Err(AcquireError::Failed(crate::i18n::gettext_f(
                "Could not open a connection for this editor: {error}",
                &[("error", &crate::ui::error_text::operation_error_message(&error))],
            ))),
        }
    }

    /// Move the tab to `database` from its next run on.
    pub fn set_database(&self, database: String) {
        lock(&self.state).database = Some(database);
    }

    /// The tab's database, `None` while it is the connection's.
    pub fn database(&self) -> Option<String> {
        lock(&self.state).database.clone()
    }

    /// Take where a run left `editor`, which a `USE` in it may have moved.
    pub fn follow(&self, editor: &Arc<dyn EditorSession>) {
        let mut state = lock(&self.state);
        let held = state.open.as_ref().is_some_and(|open| open.editor.id() == editor.id());
        if let Some(database) = editor.database().filter(|_| held) {
            state.database = Some(database);
        }
    }

    /// Put `editor` in the tab's database unless it is there. A session
    /// that cannot get there leaves the tab where the session is.
    async fn reach_database(
        &self,
        session: &Arc<Session>,
        editor: Arc<dyn EditorSession>,
        (statement_timeout, close_timeout): (Option<Duration>, Duration),
        cancel: &CancellationToken,
    ) -> Result<Arc<dyn EditorSession>, AcquireError> {
        let deadline = statement_timeout.map(|timeout| tokio::time::Instant::now() + timeout);
        let Some(wanted) = self.database() else {
            return Ok(editor);
        };
        let here = editor.database().or_else(|| session.database().map(str::to_owned));
        if here.as_deref() == Some(wanted.as_str()) {
            return Ok(editor);
        }
        match editor
            .use_database(&wanted, CallOptions::new(deadline, cancel.clone()))
            .await
        {
            Ok(()) => Ok(editor),
            Err(tablepro_core::DriverError::Cancelled) => Err(AcquireError::Cancelled),
            // The engine binds a session's database when it connects.
            Err(tablepro_core::DriverError::Unsupported { .. }) => {
                self.reopen_in(
                    session,
                    editor,
                    (wanted, here),
                    (statement_timeout, close_timeout),
                    cancel,
                )
                .await
            }
            Err(error) => {
                lock(&self.state).database = here;
                Err(AcquireError::Moved {
                    database: wanted,
                    reason: crate::ui::error_text::driver_message(&error),
                })
            }
        }
    }

    /// Give up `editor` for a session opened in `wanted`. One holding a
    /// transaction stays: closing it would roll the transaction back.
    async fn reopen_in(
        &self,
        session: &Arc<Session>,
        editor: Arc<dyn EditorSession>,
        (wanted, here): (String, Option<String>),
        (statement_timeout, close_timeout): (Option<Duration>, Duration),
        cancel: &CancellationToken,
    ) -> Result<Arc<dyn EditorSession>, AcquireError> {
        let holds_transaction = {
            let mut state = lock(&self.state);
            let held = state
                .open
                .as_ref()
                .is_some_and(|open| open.editor.id() == editor.id() && open.held_transaction());
            if !held {
                state.open = None;
            }
            held
        };
        if holds_transaction {
            lock(&self.state).database = here;
            return Err(AcquireError::Moved {
                database: wanted,
                reason: crate::i18n::gettext("Commit or roll back the transaction first."),
            });
        }
        close_quietly(editor, close_timeout).await;
        let options = EditorSessionOptions {
            statement_timeout,
            database: Some(wanted.clone()),
        };
        match session.open_editor_session(options, cancel).await {
            Ok(opened) => match self.adopt(session, opened.clone()) {
                Ok(()) => Ok(opened),
                Err(orphan) => {
                    close_quietly(orphan, close_timeout).await;
                    Err(AcquireError::Cancelled)
                }
            },
            Err(OperationError::Cancelled) => Err(AcquireError::Cancelled),
            Err(error) => {
                lock(&self.state).database = here;
                Err(AcquireError::Moved {
                    database: wanted,
                    reason: crate::ui::error_text::operation_error_message(&error),
                })
            }
        }
    }

    fn lookup(&self, owner: &Arc<Session>) -> Lookup {
        let mut state = lock(&self.state);
        if state.closed {
            return Lookup::Closed;
        }
        if std::mem::take(&mut state.rolled_back) {
            return Lookup::RolledBack {
                stale: state.open.take().map(|open| open.editor),
            };
        }
        match state.open.take() {
            Some(open) if open.editor.state() == EditorSessionState::Lost && open.held_transaction() => {
                Lookup::RolledBack {
                    stale: Some(open.editor),
                }
            }
            Some(open)
                if open.owner.ptr_eq(&Arc::downgrade(owner)) && open.editor.state() != EditorSessionState::Lost =>
            {
                let editor = open.editor.clone();
                state.open = Some(open);
                Lookup::Ready(editor)
            }
            stale => Lookup::Missing {
                stale: stale.map(|open| open.editor),
            },
        }
    }

    /// Where the transaction of `editor` stood after its last run.
    pub fn transaction(&self, editor: &Arc<dyn EditorSession>) -> Option<TransactionState> {
        let state = lock(&self.state);
        state
            .open
            .as_ref()
            .filter(|open| open.editor.id() == editor.id())
            .and_then(|open| open.transaction)
    }

    /// Record where a run left the transaction of `editor`.
    pub fn note_transaction(&self, editor: &Arc<dyn EditorSession>, transaction: Option<TransactionState>) {
        let mut state = lock(&self.state);
        if let Some(open) = state.open.as_mut().filter(|open| open.editor.id() == editor.id()) {
            open.transaction = transaction;
        }
    }

    /// Keep a newly opened session, or hand it back when the tab closed
    /// while it was opening.
    fn adopt(&self, owner: &Arc<Session>, editor: Arc<dyn EditorSession>) -> Result<(), Arc<dyn EditorSession>> {
        let mut state = lock(&self.state);
        if state.closed {
            return Err(editor);
        }
        state.open = Some(OpenEditor {
            owner: Arc::downgrade(owner),
            editor,
            transaction: None,
        });
        Ok(())
    }

    /// Let go of a session whose connection went during a run. The next
    /// run opens a new session, or with `refuse_next`, when a transaction
    /// went with the connection unannounced, is refused first. Returns
    /// whether this slot held it.
    pub fn forget(&self, editor: &Arc<dyn EditorSession>, refuse_next: bool) -> bool {
        let mut state = lock(&self.state);
        let held = state.open.as_ref().is_some_and(|open| open.editor.id() == editor.id());
        if held {
            state.open = None;
            state.rolled_back |= refuse_next;
        }
        held
    }

    /// Mark the tab gone and take its session to close. Every later
    /// open is closed straight away.
    pub fn close(&self) -> Option<Arc<dyn EditorSession>> {
        let mut state = lock(&self.state);
        state.closed = true;
        state.open.take().map(|open| open.editor)
    }
}

impl std::fmt::Debug for EditorSessionSlot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = lock(&self.state);
        f.debug_struct("EditorSessionSlot")
            .field("open", &state.open.is_some())
            .field("closed", &state.closed)
            .finish()
    }
}

impl OpenEditor {
    fn held_transaction(&self) -> bool {
        transaction_open(self.transaction)
    }
}

/// A transaction the server rolls back when the connection goes.
pub fn transaction_open(transaction: Option<TransactionState>) -> bool {
    matches!(
        transaction,
        Some(TransactionState::InTransaction | TransactionState::Failed)
    )
}

pub async fn close_quietly(editor: Arc<dyn EditorSession>, close_timeout: Duration) {
    if tokio::time::timeout(close_timeout, editor.close()).await.is_err() {
        tracing::warn!("an editor session did not close in time");
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
pub(super) mod tests {
    use tablepro_test_support::{FakeEditorSession, FakeRun, Replies};

    use super::*;

    pub(crate) fn session_opening(
        editors: Vec<Arc<dyn EditorSession>>,
    ) -> (Arc<Session>, Arc<tablepro_test_support::FakeConnection>) {
        use tablepro_session::fakes::{FakeConnector, FakeCredentialSource};
        use tablepro_session::operation::DefaultDeadlines;
        use tablepro_test_support::{ConnectionScript, FakeReply};

        let mut script = ConnectionScript::default();
        for editor in editors {
            script.open_editor_session.once(FakeReply::ok(editor));
        }
        let (pending, connection) = FakeConnector::pending_session(FakeConnector::request().unwrap(), script);
        let session = Session::start(
            pending,
            tablepro_session::SessionDeps {
                connector: Arc::new(FakeConnector::new([])),
                credentials: Arc::new(FakeCredentialSource::new()),
                deadlines: Arc::new(DefaultDeadlines::new(tablepro_core::LivenessPolicy::DESKTOP)),
                tasks: crate::test_support::paused_tasks(),
                prompter: None,
            },
        );
        (session, connection)
    }

    fn answering() -> Arc<FakeEditorSession> {
        let mut runs = Replies::default();
        runs.always(FakeRun::completed(Vec::new()));
        Arc::new(FakeEditorSession::new(runs))
    }

    const CLOSE: Duration = Duration::from_secs(10);

    /// A session in `database` that cannot move while it lives, as on
    /// PostgreSQL.
    fn bound_to(database: &str) -> Arc<FakeEditorSession> {
        let editor = answering();
        editor.set_database(Some(database));
        editor.refuse_moves(tablepro_core::DriverError::Unsupported {
            feature: tablepro_core::UnsupportedFeature::DatabaseSwitching,
        });
        editor
    }

    /// Where a live session cannot move, the tab gets a session opened in
    /// its database, unless the one it has holds a transaction.
    #[tokio::test]
    async fn a_session_that_cannot_move_gives_way_unless_it_holds_a_transaction() {
        let (shop, analytics) = (bound_to("shop"), bound_to("analytics"));
        let (session, connection) = session_opening(vec![shop.clone(), analytics.clone()]);
        let slot = EditorSessionSlot::new();
        let first = slot
            .acquire(&session, None, CLOSE, &CancellationToken::new())
            .await
            .expect("a session in shop");
        slot.note_transaction(&first, Some(TransactionState::InTransaction));

        slot.set_database("analytics".to_owned());
        let refused = slot.acquire(&session, None, CLOSE, &CancellationToken::new()).await;
        assert!(
            matches!(refused, Err(AcquireError::Moved { .. })),
            "{:?}",
            refused.err()
        );
        assert_eq!(slot.database().as_deref(), Some("shop"), "the tab left its transaction");
        assert_eq!(shop.close_count(), 0);

        slot.note_transaction(&first, Some(TransactionState::Idle));
        slot.set_database("analytics".to_owned());
        let moved = slot
            .acquire(&session, None, CLOSE, &CancellationToken::new())
            .await
            .expect("a session in analytics");
        assert_eq!(moved.database().as_deref(), Some("analytics"));
        assert_eq!(shop.close_count(), 1, "the session in shop stayed open");
        assert_eq!(
            tablepro_test_support::CallCounters::get(&connection.counters().open_editor_session),
            2
        );
    }

    #[tokio::test]
    async fn a_tab_opens_its_editor_session_once_and_reuses_it() {
        let editor = answering();
        let (session, connection) = session_opening(vec![editor.clone()]);
        let slot = EditorSessionSlot::new();

        let first = slot
            .acquire(&session, None, CLOSE, &CancellationToken::new())
            .await
            .expect("an editor session");
        let second = slot
            .acquire(&session, None, CLOSE, &CancellationToken::new())
            .await
            .expect("the same editor session");

        assert_eq!(first.id(), second.id());
        assert_eq!(
            tablepro_test_support::CallCounters::get(&connection.counters().open_editor_session),
            1
        );
    }

    #[tokio::test]
    async fn a_new_window_session_replaces_the_old_editor_session() {
        let old_editor = answering();
        let new_editor = answering();
        let (old_session, _) = session_opening(vec![old_editor.clone()]);
        let (new_session, _) = session_opening(vec![new_editor.clone()]);
        let slot = EditorSessionSlot::new();

        for session in [old_session, new_session] {
            slot.acquire(&session, None, CLOSE, &CancellationToken::new())
                .await
                .expect("an editor session");
        }

        assert_eq!(old_editor.close_count(), 1, "the old session was left open");
        assert_eq!(new_editor.close_count(), 0);
    }

    #[tokio::test]
    async fn a_session_opened_after_the_tab_closed_is_handed_back() {
        let editor: Arc<dyn EditorSession> = answering();
        let (session, _) = session_opening(Vec::new());
        let slot = EditorSessionSlot::new();

        assert!(slot.close().is_none());

        assert!(slot.adopt(&session, editor).is_err());
        assert!(matches!(
            slot.acquire(&session, None, CLOSE, &CancellationToken::new()).await,
            Err(AcquireError::Cancelled)
        ));
    }
}
