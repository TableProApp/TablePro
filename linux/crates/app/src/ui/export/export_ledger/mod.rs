use std::cell::RefCell;
use std::collections::BTreeMap;
use std::future::Future;
use std::pin::pin;
use std::rc::Rc;

use futures::channel::oneshot;
use futures::future::{Either, LocalBoxFuture, select};
use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::StreamSummary;
use tablepro_session::OperationError;
use tablepro_session::runtime::{HoldToken, ProcessHold, TaskResult, Tasks};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use super::export_producer::{start_query_producer, start_rows_producer};
use super::{
    ExportFailure, ExportJob, ExportJobId, ExportJobItem, ExportMessage, ExportOutcome, ExportQuery, ExportReporter,
    ExportSinkParts, ExportSource, ExportStreamFailure, FinishError, ReplaceFileWriter,
};
use crate::i18n::{gettext, ngettext_f};
use crate::ui::format::plural_count;
use crate::workspace::{CloseBlockPrompt, CloseBlocker, InhibitReason, WindowInhibitor, WorkOutcome};

/// Chunks in flight between the encoder and the file. Few, so a slow
/// disk holds the encoder back within a few hundred kilobytes.
const CHANNEL_CHUNKS: usize = 4;
/// An image is written this much at a time, so Stop is heard on a slow
/// destination, as a row export's chunks are.
const IMAGE_CHUNK: usize = 64 * 1024;

type EndedListener = Rc<dyn Fn(Uuid, WorkOutcome)>;

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
    ended: RefCell<Vec<EndedListener>>,
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

/// A file made whole before it is written, such as a diagram's image:
/// its bytes come from a task already running.
pub(crate) struct ImageExport {
    pub destination: gio::File,
    pub bytes: TaskResult<Result<Vec<u8>, String>>,
    /// The tab the image came from, which hears how the export ended.
    pub tab: Option<Uuid>,
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
            ended: RefCell::default(),
        })
    }

    /// Call `listener` with the tab and the outcome of each job that
    /// came from a tab, once the job has settled.
    pub(crate) fn on_ended(&self, listener: impl Fn(Uuid, WorkOutcome) + 'static) {
        self.ended.borrow_mut().push(Rc::new(listener));
    }

    pub(crate) fn jobs(&self) -> gio::ListStore {
        self.jobs.clone()
    }

    /// Start `job`, unless the workspace has shut down. A file chooser
    /// still open when the window closed can hand one over after that.
    pub(crate) fn begin(self: &Rc<Self>, job: ExportJob) -> Option<ExportJobHandle> {
        let cancel = CancellationToken::new();
        let item = ExportJobItem::new(&file_name(&job.destination), job.expected_rows, cancel.clone());
        let (destination, tab) = (job.destination.clone(), job.tab);
        let tasks = self.tasks.clone();
        let running = item.clone();
        self.start(item, cancel.clone(), destination, tab, async move {
            run(&tasks, job, &cancel, &running).await
        })
    }

    /// Start writing `image`, as `begin` starts an export of rows: listed
    /// with Stop, holding the process and the session, and asked about
    /// when the window closes.
    pub(crate) fn begin_image(self: &Rc<Self>, image: ImageExport) -> Option<ExportJobHandle> {
        let cancel = CancellationToken::new();
        let item = ExportJobItem::whole_file(&file_name(&image.destination), cancel.clone());
        let (destination, tab) = (image.destination.clone(), image.tab);
        let running = item.clone();
        self.start(item, cancel.clone(), destination, tab, async move {
            run_image(image, &cancel, &running).await
        })
    }

    fn start(
        self: &Rc<Self>,
        item: ExportJobItem,
        cancel: CancellationToken,
        destination: gio::File,
        tab: Option<Uuid>,
        work: impl Future<Output = ExportOutcome> + 'static,
    ) -> Option<ExportJobHandle> {
        if self.state.borrow().shut_down {
            tracing::debug!("an export began after its workspace shut down, and was not started");
            return None;
        }
        let id = {
            let mut state = self.state.borrow_mut();
            state.next += 1;
            let id = ExportJobId::new(state.next);
            state.running.insert(
                id,
                Running {
                    cancel,
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
            let ended = work.await;
            ledger.settle(id, &item);
            ledger.reporter.report(&destination, &item.title(), &ended);
            if let Some(tab) = tab {
                ledger.tell_ended(tab, WorkOutcome::from(&ended));
            }
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

    fn tell_ended(&self, tab: Uuid, outcome: WorkOutcome) {
        let listeners: Vec<EndedListener> = self.ended.borrow().clone();
        for listener in listeners {
            listener(tab, outcome);
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

/// Write the job's file: open it, start the producer, and take its
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
    let parts = ExportSinkParts {
        messages,
        format: job.format,
        tasks: tasks.clone(),
    };
    let producer = Producer::start(tasks, job.source, parts, cancel);
    loop {
        let Some(next) = until_cancelled(cancel, received.recv()).await else {
            return ExportOutcome::Stopped(writer.abort().await);
        };
        match next {
            Some(ExportMessage::Chunk { bytes, rows }) => {
                if let Err(error) = writer.write(bytes).await {
                    cancel.cancel();
                    return failed(writer, error.into()).await;
                }
                item.set_rows(rows);
            }
            Some(ExportMessage::Progress { rows }) => item.set_rows(rows),
            Some(ExportMessage::Failed(failure)) => {
                cancel.cancel();
                return failed(writer, failure.into()).await;
            }
            Some(ExportMessage::Finished { rows }) => {
                // A read can still fail once its rows are in, as a
                // statement that writes after it reads does, and the
                // file is kept only for a read that ended well.
                let Some(ended) = until_cancelled(cancel, producer.finish()).await else {
                    return ExportOutcome::Stopped(writer.abort().await);
                };
                // A sink that stopped the read on a second result set
                // says so here, and a driver may still end that read
                // Ok, as SQL Server's does.
                if let Some(failure) = sent_failure(&mut received) {
                    return failed(writer, failure).await;
                }
                if let Err(failure) = ended {
                    return failed(writer, failure).await;
                }
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
            // by a failure or a panic.
            None => {
                if cancel.is_cancelled() {
                    return ExportOutcome::Stopped(writer.abort().await);
                }
                let failure = match producer.finish().await {
                    Ok(()) => ExportStreamFailure::NoResultSet.into(),
                    Err(failure) => failure,
                };
                return failed(writer, failure).await;
            }
        }
    }
}

/// Write an image's bytes once its task has made them.
async fn run_image(image: ImageExport, cancel: &CancellationToken, item: &ExportJobItem) -> ExportOutcome {
    let writer = match ReplaceFileWriter::open(&image.destination).await {
        Ok(writer) => writer,
        Err(error) => {
            return ExportOutcome::Failed {
                failure: error.into(),
                file: None,
            };
        }
    };
    show_display_name(&image.destination, item).await;
    let Some(made) = until_cancelled(cancel, image.bytes).await else {
        return ExportOutcome::Stopped(writer.abort().await);
    };
    let bytes = match made {
        Ok(Ok(bytes)) => bytes,
        Ok(Err(reason)) => return failed(writer, ExportFailure::Image(reason)).await,
        Err(failure) => return failed(writer, failure.into()).await,
    };
    // Each write runs to its end, as a row export's chunks do: a write
    // dropped mid-flight leaves the stream busy, and the abort could not
    // close it. Stop is heard between chunks.
    for chunk in bytes.chunks(IMAGE_CHUNK) {
        if cancel.is_cancelled() {
            return ExportOutcome::Stopped(writer.abort().await);
        }
        if let Err(error) = writer.write(chunk.to_vec()).await {
            return failed(writer, error.into()).await;
        }
    }
    if cancel.is_cancelled() {
        return ExportOutcome::Stopped(writer.abort().await);
    }
    match writer.finish().await {
        Ok(()) => ExportOutcome::Saved,
        Err(FinishError { error, file }) => ExportOutcome::Failed {
            failure: error.into(),
            file: Some(file),
        },
    }
}

/// `work`'s output, or `None` once the job is stopped.
async fn until_cancelled<T>(cancel: &CancellationToken, work: impl Future<Output = T>) -> Option<T> {
    let stopped = pin!(cancel.cancelled());
    let work = pin!(work);
    match select(stopped, work).await {
        Either::Left(((), _)) => None,
        Either::Right((output, _)) => Some(output),
    }
}

/// The failure a sink sent after its result finished. It says more than
/// the read's own end: a second result set stops the read, which then
/// reports only that it was stopped, or nothing wrong at all.
fn sent_failure(received: &mut mpsc::Receiver<ExportMessage>) -> Option<ExportFailure> {
    while let Ok(message) = received.try_recv() {
        if let ExportMessage::Failed(failure) = message {
            return Some(failure.into());
        }
    }
    None
}

async fn failed(writer: ReplaceFileWriter, failure: ExportFailure) -> ExportOutcome {
    ExportOutcome::Failed {
        failure,
        file: Some(writer.abort().await),
    }
}

/// What feeds a job's sink: rows a grid already holds, or a read
/// streamed from the server.
enum Producer {
    Rows(TaskResult<()>),
    Query {
        task: TaskResult<Result<StreamSummary, OperationError>>,
        rerun: bool,
    },
}

impl Producer {
    /// Neither kind is aborted when the job stops. The cancel reaches
    /// both: the rows producer checks it between batches, and a read
    /// stops its statement on the server, which an abort would leave
    /// running behind a dropped future.
    fn start(tasks: &Tasks, source: ExportSource, parts: ExportSinkParts, cancel: &CancellationToken) -> Self {
        match source {
            ExportSource::Rows { columns, rows } => {
                Self::Rows(start_rows_producer(tasks, columns, rows, parts, cancel.clone()))
            }
            ExportSource::Query { session, query } => {
                let rerun = matches!(query, ExportQuery::Editor { .. });
                Self::Query {
                    task: start_query_producer(tasks, session, query, parts, cancel.clone()),
                    rerun,
                }
            }
        }
    }

    async fn finish(self) -> Result<(), ExportFailure> {
        match self {
            Self::Rows(task) => task.await.map_err(ExportFailure::from),
            Self::Query { task, rerun } => match task.await {
                Ok(Ok(_)) => Ok(()),
                Ok(Err(error)) if rerun => Err(ExportFailure::Statement(error)),
                Ok(Err(error)) => Err(ExportFailure::Table(error)),
                Err(failure) => Err(failure.into()),
            },
        }
    }
}

#[cfg(test)]
mod tests;
