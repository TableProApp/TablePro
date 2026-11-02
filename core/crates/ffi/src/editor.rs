use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{EditorSession, RowLimit, RunOptions, UserSql};
use tablepro_session::runtime::{Tasks, catch_panic};

use crate::error::CoreError;
use crate::run::{QueryRun, RunListener, RunOutcome, RunSink, RunState};
use crate::runtime::on_runtime;

/// An editor tab's own connection, which keeps its transaction and
/// session settings from one run to the next.
#[derive(uniffi::Object)]
pub struct QueryEditor {
    editor: Arc<dyn EditorSession>,
    tasks: Tasks,
}

/// What one run may do. `None` takes the editor's defaults: 10,000 rows
/// and no deadline beyond the connection's.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct RunSettings {
    pub row_limit: Option<u64>,
    pub timeout_ms: Option<u64>,
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
        let editor = self.editor.clone();
        let sink = RunSink::new(state.clone());
        let run = state.clone();
        drop(self.tasks.spawn_task(async move {
            let ran = catch_panic(editor.run(UserSql::new(sql), options, Box::new(sink))).await;
            run.finish(match ran {
                Ok(result) => RunOutcome::of(result),
                Err(panic) => CoreError::failed("ffi.panicked", format!("the run panicked: {panic}")).into(),
            });
        }));
        Arc::new(QueryRun::new(state, self.tasks.clone()))
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
