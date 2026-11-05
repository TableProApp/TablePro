use std::sync::Arc;

use async_trait::async_trait;
use gtk4::gio;
use tablepro_core::dump::{
    DumpError, DumpOutput, DumpOutputClosed, DumpProgress, DumpReport, DumpRequest, GzipChunks, write_dump,
};
use tablepro_session::runtime::{TaskResult, Tasks};
use tablepro_session::{OperationError, OperationKind, Session};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use super::ExportMessage;

/// A whole database or schema written to one SQL file.
#[derive(Debug)]
pub(crate) struct DumpJob {
    pub destination: gio::File,
    pub session: Arc<Session>,
    pub request: DumpRequest,
    /// Write the file gzipped, as a `.sql.gz`.
    pub gzip: bool,
}

pub(super) type DumpTask = TaskResult<Result<Result<DumpReport, DumpError>, OperationError>>;

/// Read the database through `session` and hand the file's bytes to
/// `messages`, gzipped when asked. The bounded channel holds the read back
/// while the disk catches up.
pub(super) fn start_dump_producer(
    tasks: &Tasks,
    job: &DumpJob,
    messages: mpsc::Sender<ExportMessage>,
    cancel: CancellationToken,
) -> DumpTask {
    let session = Arc::clone(&job.session);
    let request = Arc::new(job.request.clone());
    let gzip = job.gzip;
    tasks.spawn_task(async move {
        session
            .run_cancellable(OperationKind::Export, &cancel, move |lease, options| {
                let request = Arc::clone(&request);
                let messages = messages.clone();
                async move {
                    let mut output = ChannelOutput::new(messages, gzip);
                    let report = write_dump(lease.connection().as_ref(), &request, &mut output, options).await;
                    let ended = output.finish().await;
                    Ok(match (report, ended) {
                        (Ok(report), Ok(())) => Ok(report),
                        (Ok(_), Err(DumpOutputClosed)) => Err(DumpError::OutputClosed),
                        (Err(error), _) => Err(error),
                    })
                }
            })
            .await
    })
}

struct ChannelOutput {
    messages: mpsc::Sender<ExportMessage>,
    gzip: Option<GzipChunks>,
    rows: u64,
}

impl ChannelOutput {
    fn new(messages: mpsc::Sender<ExportMessage>, gzip: bool) -> Self {
        Self {
            messages,
            gzip: gzip.then(GzipChunks::new),
            rows: 0,
        }
    }

    async fn send(&mut self, bytes: Vec<u8>) -> Result<(), DumpOutputClosed> {
        if bytes.is_empty() {
            return Ok(());
        }
        self.messages
            .send(ExportMessage::Chunk { bytes, rows: self.rows })
            .await
            .map_err(|_| DumpOutputClosed)
    }

    /// The gzip trailer, once every byte is in.
    async fn finish(mut self) -> Result<(), DumpOutputClosed> {
        match self.gzip.take() {
            Some(gzip) => {
                let tail = gzip.finish().map_err(|_| DumpOutputClosed)?;
                self.send(tail).await
            }
            None => Ok(()),
        }
    }
}

#[async_trait]
impl DumpOutput for ChannelOutput {
    async fn write(&mut self, bytes: Vec<u8>) -> Result<(), DumpOutputClosed> {
        let bytes = match &mut self.gzip {
            Some(gzip) => gzip.compress(&bytes).map_err(|_| DumpOutputClosed)?,
            None => bytes,
        };
        self.send(bytes).await
    }

    fn progress(&mut self, progress: DumpProgress) {
        self.rows = progress.rows;
        // Progress is only shown, so a full channel drops it rather than
        // holding the read.
        let _ = self.messages.try_send(ExportMessage::Tables {
            done: progress.tables_done,
            total: progress.tables_total,
            rows: progress.rows,
        });
    }
}
