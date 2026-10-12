use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::Duration;

use tablepro_core::{EditorSession, EditorSessionOptions, EditorSessionState};
use tablepro_session::{OperationError, Session};
use tokio_util::sync::CancellationToken;

/// The editor tab's own connection, shared with the run on the runtime.
///
/// The run opens it and the tab closes it, possibly while a run is
/// still opening one, so the slot remembers it was closed and a session
/// opened after that is handed back to be closed rather than kept.
#[derive(Default)]
pub struct EditorSessionSlot {
    state: Mutex<SlotState>,
}

#[derive(Default)]
struct SlotState {
    open: Option<OpenEditor>,
    closed: bool,
}

struct OpenEditor {
    /// The window session it was opened from. A tab outliving a switch
    /// to another database must not run on the old one.
    owner: Weak<Session>,
    editor: Arc<dyn EditorSession>,
}

enum Lookup {
    Ready(Arc<dyn EditorSession>),
    /// None usable; `stale` is one to close before opening another.
    Missing {
        stale: Option<Arc<dyn EditorSession>>,
    },
    Closed,
}

/// Why a run got no editor session.
#[derive(Debug)]
pub enum AcquireError {
    /// The tab closed or the run was stopped while it opened.
    Cancelled,
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
            Lookup::Ready(editor) => return Ok(editor),
            Lookup::Closed => return Err(AcquireError::Cancelled),
            Lookup::Missing { stale } => stale,
        };
        if let Some(stale) = stale {
            close_quietly(stale, close_timeout).await;
        }
        let options = EditorSessionOptions { statement_timeout };
        match session.open_editor_session(options, cancel).await {
            Ok(editor) => match self.adopt(session, editor.clone()) {
                Ok(()) => Ok(editor),
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

    fn lookup(&self, owner: &Arc<Session>) -> Lookup {
        let mut state = lock(&self.state);
        if state.closed {
            return Lookup::Closed;
        }
        match state.open.take() {
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
        });
        Ok(())
    }

    /// Let go of a session whose connection is gone, so the next run
    /// opens a new one. Returns whether this slot held it.
    pub fn forget(&self, editor: &Arc<dyn EditorSession>) -> bool {
        let mut state = lock(&self.state);
        let held = state.open.as_ref().is_some_and(|open| open.editor.id() == editor.id());
        if held {
            state.open = None;
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
