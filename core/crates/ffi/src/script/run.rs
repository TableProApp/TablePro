use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use tablepro_core::column::ResultColumn;
use tablepro_core::script_run::{
    BatchReporter, RUN_ROW_LIMIT, ReportFlow, RunBatch, ScriptBatchReport, ScriptResultStore,
    ScriptRun as CoreScriptRun, run_batches,
};
use tablepro_core::value::Value;
use tablepro_core::{ByteLimit, EditorSession, EditorSessionState, RowLimit};
use tablepro_session::runtime::{Tasks, catch_panic};

use super::events::{BatchErrorPolicyTag, ScriptBatch, ScriptRunEvent, ScriptRunSummary, transaction_tag};
use super::state::ScriptState;
use crate::editor::RunSettings;
use crate::error::CoreError;
use crate::results::{ResultSet, ResultStore};
use crate::run::{RunListener, TransactionStateTag};
use crate::runtime::on_runtime;

/// The app's handle on a running script. Dropping it stops the run.
#[derive(uniffi::Object)]
pub struct ScriptRun {
    state: Arc<ScriptState>,
    tasks: Tasks,
}

impl ScriptRun {
    fn new(state: Arc<ScriptState>, tasks: Tasks) -> Self {
        Self { state, tasks }
    }
}

#[uniffi::export]
impl ScriptRun {
    /// Every event since the last drain, which also acknowledges the wake.
    pub fn drain_events(&self) -> Vec<ScriptRunEvent> {
        self.state.drain()
    }

    /// The result set a `ResultSet` entry points at, readable while its
    /// rows still arrive.
    pub fn result_set(&self, set_index: u32) -> Option<Arc<ResultSet>> {
        self.state
            .set(set_index)
            .map(|store| Arc::new(ResultSet::new(set_index, store)))
    }

    /// The app shows this set no more, so the run lets go of its rows;
    /// they go once no `ResultSet` holds them.
    pub fn release_set(&self, set_index: u32) {
        self.state.release_set(set_index);
    }

    pub fn cancel(&self) {
        self.state.cancel.cancel();
    }

    /// Waits for the run to end. Dropping the wait leaves the run going.
    pub async fn outcome(&self) -> Result<ScriptRunSummary, CoreError> {
        let mut outcome = self.state.outcome();
        on_runtime(&self.tasks, async move {
            let ended = outcome
                .wait_for(Option::is_some)
                .await
                .map_err(|_| CoreError::failed("ffi.run_lost", "the run ended without an outcome"))?;
            (*ended).ok_or_else(|| CoreError::failed("ffi.run_lost", "the run ended without an outcome"))
        })
        .await
    }
}

impl Drop for ScriptRun {
    fn drop(&mut self) {
        self.state.cancel.cancel();
    }
}

impl std::fmt::Debug for ScriptRun {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScriptRun").finish_non_exhaustive()
    }
}

// Sends each batch's structured report to the app as a `ScriptRunEvent`.
struct ScriptReporter {
    state: Arc<ScriptState>,
}

impl BatchReporter for ScriptReporter {
    fn report<'a>(&'a mut self, report: ScriptBatchReport) -> Pin<Box<dyn Future<Output = ReportFlow> + Send + 'a>> {
        self.state.post(ScriptRunEvent::batch(report));
        // The app drains on its own thread; a dropped `ScriptRun` cancels
        // the run, so the loop never waits on the reader here.
        Box::pin(std::future::ready(ReportFlow::Continue))
    }
}

// Keeps each result set's rows in the core's store, the one Windows reads
// through a cursor.
struct ScriptStore {
    state: Arc<ScriptState>,
}

impl ScriptResultStore for ScriptStore {
    fn start_set(&self, columns: Arc<[ResultColumn]>) -> usize {
        let store = Arc::new(ResultStore::new(columns));
        self.state.add_set(store) as usize
    }

    fn resolve_columns(&self, set_index: usize, columns: Arc<[ResultColumn]>) {
        if let Some(store) = self.state.set(set_index as u32) {
            store.resolve_columns(columns);
        }
    }

    fn append(&self, set_index: usize, rows: Vec<Vec<Value>>) {
        if let Some(store) = self.state.set(set_index as u32) {
            store.append(&rows);
        }
    }

    fn finish_set(&self, set_index: usize, total_rows: Option<u64>, cut: bool) {
        if let Some(store) = self.state.set(set_index as u32) {
            store.finish_cut(total_rows, cut);
        }
    }
}

fn build_run(batches: Vec<ScriptBatch>, policy: BatchErrorPolicyTag, settings: &RunSettings) -> CoreScriptRun {
    CoreScriptRun {
        batches: batches
            .into_iter()
            .map(|batch| RunBatch {
                text: batch.text,
                repeat: batch.repeat,
                error_base: usize::try_from(batch.error_base).unwrap_or(0),
                refused: batch.refused,
            })
            .collect(),
        policy: policy.into(),
        statement_timeout: settings.timeout_ms.map(Duration::from_millis),
        row_limit: settings
            .row_limit
            .and_then(RowLimit::new)
            .unwrap_or(RowLimit::EDITOR_DEFAULT),
        run_row_limit: RUN_ROW_LIMIT,
        byte_limit: settings
            .byte_limit
            .and_then(ByteLimit::new)
            .unwrap_or(ByteLimit::EDITOR_DEFAULT),
    }
}

pub(crate) fn run_script(
    editor: Arc<dyn EditorSession>,
    tasks: Tasks,
    batches: Vec<ScriptBatch>,
    policy: BatchErrorPolicyTag,
    settings: RunSettings,
    listener: Box<dyn RunListener>,
) -> Arc<ScriptRun> {
    let state = Arc::new(ScriptState::new(listener));
    let run = build_run(batches, policy, &settings);
    let task_state = state.clone();
    drop(tasks.spawn_task(async move {
        let store: Arc<dyn ScriptResultStore> = Arc::new(ScriptStore {
            state: task_state.clone(),
        });
        let mut reporter = ScriptReporter {
            state: task_state.clone(),
        };
        let ran = catch_panic(run_batches(
            &editor,
            &run,
            &task_state.cancel,
            &store,
            &mut reporter,
            None,
        ))
        .await;
        let (summary, finished) = match ran {
            Ok(after) => {
                let lost = editor.state() == EditorSessionState::Lost;
                let transaction = transaction_tag(after.transaction);
                (
                    ScriptRunSummary {
                        transaction,
                        lost,
                        rolled_back: after.rollback_told,
                    },
                    ScriptRunEvent::Finished {
                        transaction,
                        lost,
                        rolled_back: after.rollback_told,
                    },
                )
            }
            Err(panic) => {
                tracing::warn!("the script run panicked: {panic}");
                (
                    ScriptRunSummary {
                        transaction: TransactionStateTag::Unknown,
                        lost: false,
                        rolled_back: false,
                    },
                    ScriptRunEvent::Finished {
                        transaction: TransactionStateTag::Unknown,
                        lost: false,
                        rolled_back: false,
                    },
                )
            }
        };
        task_state.finish(summary, finished);
    }));
    Arc::new(ScriptRun::new(state, tasks))
}
