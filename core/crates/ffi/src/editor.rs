use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{ByteLimit, CallOptions, EditorSession, EditorSessionState, RowLimit, RunOptions, UserSql};
use tablepro_session::runtime::{Tasks, catch_panic};

use crate::cancel_token::{CancelToken, token};
use crate::error::CoreError;
use crate::run::{QueryRun, RunListener, RunOutcome, RunSink, RunState, TransactionStateTag};
use crate::runtime::on_runtime;

/// An editor tab's own connection, which keeps its transaction and
/// session settings from one run to the next.
#[derive(uniffi::Object)]
pub struct QueryEditor {
    editor: Arc<dyn EditorSession>,
    tasks: Tasks,
}

/// What one run may do. `None` takes the editor's defaults: 10,000 rows,
/// 256,000,000 bytes of rows across the run, and no deadline beyond the
/// connection's.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct RunSettings {
    pub row_limit: Option<u64>,
    pub timeout_ms: Option<u64>,
    pub byte_limit: Option<u64>,
}

impl QueryEditor {
    pub(crate) fn new(editor: Arc<dyn EditorSession>, tasks: Tasks) -> Self {
        Self { editor, tasks }
    }
}

#[uniffi::export]
impl QueryEditor {
    /// Starts `sql` and returns at once. `listener` hears when events
    /// are waiting; the run ends with a `Finished` event.
    pub fn run(&self, sql: String, settings: RunSettings, listener: Box<dyn RunListener>) -> Arc<QueryRun> {
        let state = Arc::new(RunState::new(listener));
        let mut options =
            RunOptions::new(state.cancel.clone()).with_deadline(settings.timeout_ms.map(Duration::from_millis));
        if let Some(limit) = settings.row_limit.and_then(RowLimit::new) {
            options = options.with_row_limit(limit);
        }
        if let Some(limit) = settings.byte_limit.and_then(ByteLimit::new) {
            options = options.with_byte_limit(limit);
        }
        let editor = self.editor.clone();
        let sink = RunSink::new(state.clone(), options.byte_limit);
        let run = state.clone();
        drop(self.tasks.spawn_task(async move {
            let ran = catch_panic(editor.run(UserSql::new(sql), options, Box::new(sink))).await;
            let (outcome, transaction) = match ran {
                Ok(result) => RunOutcome::with_transaction(result),
                Err(panic) => (
                    CoreError::failed("ffi.panicked", format!("the run panicked: {panic}")).into(),
                    TransactionStateTag::Unknown,
                ),
            };
            run.finish(outcome, transaction);
        }));
        Arc::new(QueryRun::new(state, self.tasks.clone()))
    }

    /// The editor's connection is gone. It is never opened again by
    /// itself, since its transaction would not come back with it, so the
    /// tab opens a new editor.
    pub fn is_lost(&self) -> bool {
        self.editor.state() == EditorSessionState::Lost
    }

    // The database an unqualified name resolves to now, as the server last said, a typed USE included. None where
    // the engine does not follow it.
    pub fn database(&self) -> Option<String> {
        self.editor.database().filter(|name| !name.is_empty())
    }

    // Moves the editor's connection, keeping its transaction. An engine that binds the database at connect refuses.
    pub async fn use_database(&self, database: String, cancel: Option<Arc<CancelToken>>) -> Result<(), CoreError> {
        let editor = self.editor.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            Ok(editor.use_database(&database, CallOptions::new(None, cancel)).await?)
        })
        .await
    }

    /// Closes the editor's connection, ending its transaction.
    pub async fn close(&self) -> Result<(), CoreError> {
        let editor = self.editor.clone();
        on_runtime(&self.tasks, async move {
            editor.close().await;
            Ok(())
        })
        .await
    }
}

impl std::fmt::Debug for QueryEditor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QueryEditor")
            .field("id", &self.editor.id())
            .finish_non_exhaustive()
    }
}
