use std::fs::File;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use tablepro_core::dump::{
    self, DumpError, DumpOutput, DumpOutputClosed, DumpRequest, DumpScope, GzipChunks, write_dump,
};
use tablepro_session::OperationKind;
use tablepro_session::runtime::Tasks;

use crate::cancel_token::{CancelToken, token};
use crate::error::CoreError;
use crate::export::{PartFile, blocking, destination, io_error};
use crate::runtime::on_runtime;
use crate::session::DatabaseSession;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum DumpScopeArg {
    // Every schema of the connection's database.
    Database,
    Schema { name: String },
}

impl From<DumpScopeArg> for DumpScope {
    fn from(scope: DumpScopeArg) -> Self {
        match scope {
            DumpScopeArg::Database => Self::Database,
            DumpScopeArg::Schema { name } => Self::Schema(name),
        }
    }
}

// What a dump wrote, for the summary the app shows. The counts the report keeps, each as a number here.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DumpReportRecord {
    pub tables: u64,
    pub rows: u64,
    pub objects: u64,
    // Values with no SQL literal on the engine, written as NULL.
    pub omitted: u64,
    // Objects the catalog could not carry, such as a table of no columns.
    pub skipped: u64,
    // Tables whose foreign keys point at each other, written in the order they were listed.
    pub unordered: u64,
}

// What a dump has written so far, which the app reads while it runs, as ExportProgress does for a row export.
#[derive(Debug, Default, uniffi::Object)]
pub struct DumpProgress {
    rows: AtomicU64,
    tables_done: AtomicU64,
    tables_total: AtomicU64,
}

#[uniffi::export]
impl DumpProgress {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn rows(&self) -> u64 {
        self.rows.load(Ordering::Relaxed)
    }

    pub fn tables_done(&self) -> u64 {
        self.tables_done.load(Ordering::Relaxed)
    }

    pub fn tables_total(&self) -> u64 {
        self.tables_total.load(Ordering::Relaxed)
    }
}

impl DumpProgress {
    fn set(&self, progress: dump::DumpProgress) {
        self.rows.store(progress.rows, Ordering::Relaxed);
        self.tables_done.store(progress.tables_done as u64, Ordering::Relaxed);
        self.tables_total.store(progress.tables_total as u64, Ordering::Relaxed);
    }
}

// The file's own error, kept so a dump that closed the output reports the disk's failure, not just "output closed".
type FileFailure = Arc<Mutex<Option<CoreError>>>;

#[uniffi::export]
impl DatabaseSession {
    // A whole database or schema written to one SQL file. `data` writes the tables' rows as INSERTs; false writes only
    // their structure. `gzip` writes the file gzipped, as a `.sql.gz`. The read is held back while the disk catches up.
    pub async fn dump_database(
        &self,
        scope: DumpScopeArg,
        data: bool,
        path: String,
        gzip: bool,
        progress: Option<Arc<DumpProgress>>,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<DumpReportRecord, CoreError> {
        let session = self.session().clone();
        let tasks = self.tasks().clone();
        let cancel = token(cancel);
        on_runtime(self.tasks(), async move {
            let target = destination(&path)?;
            let part = Arc::new(PartFile::beside(target)?);
            let request = Arc::new(DumpRequest {
                scope: scope.into(),
                data,
            });
            let failure: FileFailure = Arc::new(Mutex::new(None));
            let written = session
                .run_cancellable(OperationKind::Export, &cancel, |lease, options| {
                    let (part, tasks, progress, failure, request) = (
                        part.clone(),
                        tasks.clone(),
                        progress.clone(),
                        failure.clone(),
                        request.clone(),
                    );
                    async move {
                        let mut output = match FileDumpOutput::open(part, tasks, gzip, progress, failure.clone()).await
                        {
                            Ok(output) => output,
                            Err(error) => {
                                store(&failure, error);
                                return Ok(Err(DumpError::OutputClosed));
                            }
                        };
                        let report = write_dump(lease.connection().as_ref(), &request, &mut output, options).await;
                        let ended = output.finish().await;
                        Ok(match (report, ended) {
                            (Ok(report), Ok(())) => Ok(report),
                            (Ok(_), Err(closed)) => Err(DumpError::from(closed)),
                            (Err(error), _) => Err(error),
                        })
                    }
                })
                .await?;
            let report = match written {
                Ok(report) => report,
                Err(error) => {
                    // The disk's own error explains a closed output better than the dump's wording of it.
                    if let Some(disk) = failure.lock().unwrap_or_else(PoisonError::into_inner).take() {
                        return Err(disk);
                    }
                    return Err(CoreError::failed(error.code(), error.to_string()));
                }
            };
            blocking(&tasks, move || part.place()).await?;
            Ok(DumpReportRecord {
                tables: report.tables as u64,
                rows: report.rows,
                objects: report.objects as u64,
                omitted: report.omitted.iter().map(|omitted| omitted.count).sum(),
                skipped: report.skipped.len() as u64,
                unordered: report.unordered.len() as u64,
            })
        })
        .await
    }
}

fn store(failure: &FileFailure, error: CoreError) {
    let mut slot = failure.lock().unwrap_or_else(PoisonError::into_inner);
    if slot.is_none() {
        *slot = Some(error);
    }
}

// Writes a dump's bytes to the part file on the blocking pool, so a slow disk never holds a runtime thread, and the
// dump's read is held back a write at a time. The file is placed only after `finish` syncs it.
struct FileDumpOutput {
    part: Arc<PartFile>,
    tasks: Tasks,
    file: Option<File>,
    gzip: Option<GzipChunks>,
    progress: Option<Arc<DumpProgress>>,
    failure: FileFailure,
}

impl FileDumpOutput {
    async fn open(
        part: Arc<PartFile>,
        tasks: Tasks,
        gzip: bool,
        progress: Option<Arc<DumpProgress>>,
        failure: FileFailure,
    ) -> Result<Self, CoreError> {
        let opened = part.clone();
        let file = blocking(&tasks, move || {
            File::create(opened.path()).map_err(|error| io_error(opened.target(), &error))
        })
        .await?;
        Ok(Self {
            part,
            tasks,
            file: Some(file),
            gzip: gzip.then(GzipChunks::new),
            progress,
            failure,
        })
    }

    async fn write_all(&mut self, bytes: Vec<u8>) -> Result<(), DumpOutputClosed> {
        if bytes.is_empty() {
            return Ok(());
        }
        let mut file = self.file.take().ok_or(DumpOutputClosed)?;
        let part = self.part.clone();
        let written = blocking(&self.tasks, move || {
            file.write_all(&bytes)
                .map_err(|error| io_error(part.target(), &error))?;
            Ok(file)
        })
        .await;
        match written {
            Ok(file) => {
                self.file = Some(file);
                Ok(())
            }
            Err(error) => {
                store(&self.failure, error);
                Err(DumpOutputClosed)
            }
        }
    }

    // The gzip trailer and a sync, so the name never points at a file still short of its bytes.
    async fn finish(mut self) -> Result<(), DumpOutputClosed> {
        if let Some(gzip) = self.gzip.take() {
            let tail = gzip.finish().map_err(|_| DumpOutputClosed)?;
            self.write_all(tail).await?;
        }
        let file = self.file.take().ok_or(DumpOutputClosed)?;
        let part = self.part.clone();
        let synced = blocking(&self.tasks, move || {
            file.sync_all().map_err(|error| io_error(part.target(), &error))
        })
        .await;
        synced.map_err(|error| {
            store(&self.failure, error);
            DumpOutputClosed
        })
    }
}

#[async_trait]
impl DumpOutput for FileDumpOutput {
    async fn write(&mut self, bytes: Vec<u8>) -> Result<(), DumpOutputClosed> {
        let bytes = match &mut self.gzip {
            Some(gzip) => gzip.compress(&bytes).map_err(|_| DumpOutputClosed)?,
            None => bytes,
        };
        self.write_all(bytes).await
    }

    fn progress(&mut self, progress: dump::DumpProgress) {
        if let Some(sink) = &self.progress {
            sink.set(progress);
        }
    }
}
