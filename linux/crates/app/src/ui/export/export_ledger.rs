use std::cell::RefCell;
use std::collections::BTreeMap;
use std::future::Future;
use std::pin::pin;
use std::rc::Rc;

use futures::channel::oneshot;
use futures::future::{Either, LocalBoxFuture, select};
use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_session::runtime::{HoldToken, ProcessHold, TaskFailure, TaskResult, Tasks};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use super::export_producer::{start_document_producer, start_rows_producer};
use super::{
    ExportFailure, ExportFormat, ExportJob, ExportJobId, ExportJobItem, ExportMessage, ExportOutcome, ExportReporter,
    ExportSinkParts, ExportSource, FinishError, ReplaceFileWriter,
};
use crate::i18n::{gettext, ngettext_f};
use crate::ui::count_text::plural_count;
use crate::workspace::{CloseBlockPrompt, CloseBlocker, InhibitReason, WindowInhibitor};

/// Chunks in flight between the encoder and the file. Few, so a slow
/// disk holds the encoder back within a few hundred kilobytes.
const CHANNEL_CHUNKS: usize = 4;

/// The exports a workspace has running.
///
/// Each one holds the process, so quitting while one writes still lets
/// it finish or clean up, and while any runs the session is asked not
/// to log out or suspend under it.
pub(crate) struct ExportLedger {
    tasks: Tasks,
    hold: Rc<dyn ProcessHold>,
    reporter: ExportReporter,
    inhibitor: RefCell<WindowInhibitor>,
    /// The running jobs, as the operations popover lists them.
    jobs: gio::ListStore,
    state: RefCell<LedgerState>,
}

#[derive(Default)]
struct LedgerState {
    next: u64,
    running: BTreeMap<ExportJobId, Running>,
    waiters: Vec<oneshot::Sender<()>>,
    /// The workspace shut down: its close already asked about the
    /// exports, and a new one would run with no window to report to.
    shut_down: bool,
}

struct Running {
    cancel: CancellationToken,
    _hold: HoldToken,
}

pub(crate) struct ExportLedgerInit {
    pub tasks: Tasks,
    pub hold: Rc<dyn ProcessHold>,
    pub reporter: ExportReporter,
    pub inhibitor: WindowInhibitor,
}

/// A job the ledger started. Dropping it leaves the job running, and
/// the ledger reports how it ended either way.
pub(crate) struct ExportJobHandle {
    outcome: oneshot::Receiver<ExportOutcome>,
}

impl ExportJobHandle {
    /// How the job ended. `None` when the ledger went before it did.
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "the app hears the outcome through the ledger's toast or alert")
    )]
    pub(crate) async fn outcome(self) -> Option<ExportOutcome> {
        self.outcome.await.ok()
    }
}

impl ExportLedger {
    pub(crate) fn new(init: ExportLedgerInit) -> Rc<Self> {
        Rc::new(Self {
            tasks: init.tasks,
            hold: init.hold,
            reporter: init.reporter,
            inhibitor: RefCell::new(init.inhibitor),
            jobs: gio::ListStore::new::<ExportJobItem>(),
            state: RefCell::default(),
        })
    }

    pub(crate) fn jobs(&self) -> gio::ListStore {
        self.jobs.clone()
    }

    /// Start `job`, unless the workspace has shut down. A file chooser
    /// still open when the window closed can hand one over after that.
    pub(crate) fn begin(self: &Rc<Self>, job: ExportJob) -> Option<ExportJobHandle> {
        if self.state.borrow().shut_down {
            tracing::debug!("an export began after its workspace shut down, and was not started");
            return None;
        }
        let cancel = CancellationToken::new();
        let name = file_name(&job.destination);
        let item = ExportJobItem::new(&name, job.expected_rows, cancel.clone());
        let id = {
            let mut state = self.state.borrow_mut();
            state.next += 1;
            let id = ExportJobId::new(state.next);
            state.running.insert(
                id,
                Running {
                    cancel: cancel.clone(),
                    _hold: self.hold.acquire(),
                },
            );
            id
        };
        self.jobs.append(&item);
        self.refresh_inhibitor();

        let (reply, outcome) = oneshot::channel();
        let ledger = self.clone();
        glib::spawn_future_local(async move {
            let destination = job.destination.clone();
            let ended = run(&ledger.tasks, job, &cancel, &item).await;
            ledger.settle(id, &item);
            ledger.reporter.report(&destination, &item.title(), &ended);
            let _ = reply.send(ended);
        });
        Some(ExportJobHandle { outcome })
    }

    pub(crate) fn in_flight(&self) -> usize {
        self.state.borrow().running.len()
    }

    /// Resolves once no export is running.
    pub(crate) fn when_idle(&self) -> impl Future<Output = ()> + use<> {
        let receiver = if self.in_flight() == 0 {
            None
        } else {
            let (sender, receiver) = oneshot::channel();
            self.state.borrow_mut().waiters.push(sender);
            Some(receiver)
        };
        async move {
            if let Some(receiver) = receiver {
                // A ledger dropped with jobs running wakes nobody, and a
                // waiter that outlived it has nothing left to wait on.
                let _ = receiver.await;
            }
        }
    }

    /// Stop every running export. Each settles once its file is cleaned
    /// up.
    pub(crate) fn cancel_all(&self) {
        for running in self.state.borrow().running.values() {
            running.cancel.cancel();
        }
    }

    /// Stop every running export and refuse new ones, for a workspace
    /// that is going away.
    pub(crate) fn shut_down(&self) {
        self.state.borrow_mut().shut_down = true;
        self.cancel_all();
    }

    fn settle(&self, id: ExportJobId, item: &ExportJobItem) {
        let (finished, woken) = {
            let mut state = self.state.borrow_mut();
            let finished = state.running.remove(&id);
            let woken = if state.running.is_empty() {
                std::mem::take(&mut state.waiters)
            } else {
                Vec::new()
            };
            (finished, woken)
        };
        if let Some(position) = self.jobs.find(item) {
            self.jobs.remove(position);
        }
        self.refresh_inhibitor();
        // The hold goes only after the state is consistent, in case
        // dropping it ends the main loop.
        drop(finished);
        for waiter in woken {
            let _ = waiter.send(());
        }
    }

    fn refresh_inhibitor(&self) {
        let reason = (self.in_flight() > 0).then_some(InhibitReason::Exporting);
        self.inhibitor.borrow_mut().update(reason);
    }

    /// Whether the session is held back for the running exports.
    pub(crate) fn is_inhibiting(&self) -> bool {
        self.inhibitor.borrow().is_held()
    }
}

impl CloseBlocker for ExportLedger {
    fn blocking(&self) -> Option<CloseBlockPrompt> {
        let running = self.in_flight();
        (running > 0).then(|| CloseBlockPrompt {
            heading: gettext("Stop Exports?"),
            body: ngettext_f(
                "{n} export is still running. Stopping it leaves the file unfinished.",
                "{n} exports are still running. Stopping them leaves the files unfinished.",
                plural_count(running as u64),
                &[("n", &running.to_string())],
            ),
            keep_label: gettext("_Keep Exporting"),
            stop_label: gettext("_Stop Exports"),
        })
    }

    fn stop(&self) -> LocalBoxFuture<'static, ()> {
        self.cancel_all();
        Box::pin(self.when_idle())
    }
}

impl std::fmt::Debug for ExportLedger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExportLedger")
            .field("in_flight", &self.in_flight())
            .finish_non_exhaustive()
    }
}

/// The file's name as it is shown until GIO answers with the one the
/// file manager uses.
fn file_name(file: &gio::File) -> String {
    file.basename()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| file.parse_name().to_string())
}

/// Asked once the file exists: a file not yet made has no display name.
async fn show_display_name(file: &gio::File, item: &ExportJobItem) {
    let info = file
        .query_info_future(
            gio::FILE_ATTRIBUTE_STANDARD_DISPLAY_NAME,
            gio::FileQueryInfoFlags::NONE,
            glib::Priority::DEFAULT,
        )
        .await;
    match info {
        Ok(info) => item.set_title(info.display_name()),
        Err(error) => tracing::debug!(%error, "an export's file has no display name"),
    }
}

/// Write the job's file: open it, start the encoder, and take its
/// chunks until it finishes, fails or the job is stopped.
async fn run(tasks: &Tasks, job: ExportJob, cancel: &CancellationToken, item: &ExportJobItem) -> ExportOutcome {
    let writer = match ReplaceFileWriter::open(&job.destination).await {
        Ok(writer) => writer,
        Err(error) => {
            return ExportOutcome::Failed {
                failure: error.into(),
                file: None,
            };
        }
    };
    show_display_name(&job.destination, item).await;
    if cancel.is_cancelled() {
        return ExportOutcome::Stopped(writer.abort().await);
    }
    let (messages, mut received) = mpsc::channel(CHANNEL_CHUNKS);
    let producer = start(tasks, job.format, job.source, messages, cancel);
    loop {
        let next = {
            let stopped = pin!(cancel.cancelled());
            let message = pin!(received.recv());
            match select(stopped, message).await {
                Either::Left(((), _)) => None,
                Either::Right((message, _)) => Some(message),
            }
        };
        match next {
            None => {
                producer.abort();
                return ExportOutcome::Stopped(writer.abort().await);
            }
            Some(Some(ExportMessage::Chunk { bytes, rows })) => {
                if let Err(error) = writer.write(bytes).await {
                    return failed(writer, error.into()).await;
                }
                item.set_rows(rows);
            }
            Some(Some(ExportMessage::Failed(failure))) => return failed(writer, failure.into()).await,
            Some(Some(ExportMessage::Finished { rows })) => {
                return match writer.finish().await {
                    Ok(()) => ExportOutcome::Exported { rows },
                    Err(FinishError { error, file }) => ExportOutcome::Failed {
                        failure: error.into(),
                        file: Some(file),
                    },
                };
            }
            // The producer let go of its sender without finishing:
            // stopped by the cancel, which the next turn sees, or ended
            // by a panic.
            Some(None) => {
                if cancel.is_cancelled() {
                    return ExportOutcome::Stopped(writer.abort().await);
                }
                let failure = producer.await.err().unwrap_or(TaskFailure::Aborted);
                return failed(writer, failure.into()).await;
            }
        }
    }
}

async fn failed(writer: ReplaceFileWriter, failure: ExportFailure) -> ExportOutcome {
    ExportOutcome::Failed {
        failure,
        file: Some(writer.abort().await),
    }
}

fn start(
    tasks: &Tasks,
    format: ExportFormat,
    source: ExportSource,
    messages: mpsc::Sender<ExportMessage>,
    cancel: &CancellationToken,
) -> TaskResult<()> {
    let ExportSource::Rows { columns, rows } = source;
    match format {
        ExportFormat::Rows(format) => start_rows_producer(
            tasks,
            columns,
            rows,
            ExportSinkParts { messages, format },
            cancel.clone(),
        ),
        ExportFormat::Document(format) => {
            start_document_producer(tasks, format, columns, rows, messages, cancel.clone())
        }
    }
}

#[cfg(test)]
mod tests;
