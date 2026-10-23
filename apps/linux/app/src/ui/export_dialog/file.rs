use adw::prelude::*;
use relm4::{adw, gtk};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tablepro_core::export::{CsvOptions, ExportError, ResultExport, ResultFormat, SqlTarget};
use tokio_util::sync::CancellationToken;

pub(super) enum JobSource {
    Loaded(Arc<tablepro_core::QueryResult>),
    Paged {
        mode: super::PagedExportMode,
        columns: Vec<tablepro_core::ColumnInfo>,
        total: Option<usize>,
        open: super::PageFetcherFactory,
    },
}

pub(super) struct ExportJob {
    pub(super) path: std::path::PathBuf,
    pub(super) source: JobSource,
    pub(super) format: super::ExportFormat,
    pub(super) options: CsvOptions,
    pub(super) driver_id: String,
    pub(super) schema: Option<String>,
    pub(super) table: String,
}

fn write_export(job: ExportJob, cancel: &CancellationToken, completed: &AtomicUsize) -> Result<(), ExportError> {
    if matches!(
        &job.source,
        JobSource::Paged {
            mode: super::PagedExportMode::FullTable,
            ..
        }
    ) {
        return Err(ExportError::Source(snapshot_refusal_message()));
    }
    let export = ResultExport {
        format: result_format(job.format),
        csv: &job.options,
        sql: Some(SqlTarget {
            driver_id: &job.driver_id,
            schema: job.schema.as_deref(),
            table: &job.table,
        }),
    };
    let cancelled = || cancel.is_cancelled();
    let progress = |rows| completed.store(rows, Ordering::Relaxed);
    match job.source {
        JobSource::Loaded(result) => {
            tablepro_core::export::write_result_file(&job.path, &result, &export, cancelled, progress)
        }
        JobSource::Paged {
            mode: super::PagedExportMode::GuardedQuery,
            columns,
            total,
            open,
        } => {
            let mut pages = open(cancel.clone());
            let result = tablepro_core::export::write_paged_file(
                &job.path,
                &columns,
                total.unwrap_or(0),
                &export,
                || pages.next_page(),
                cancelled,
                progress,
            );
            finish_pages(result, pages.finish())
        }
        JobSource::Paged {
            mode: super::PagedExportMode::FullTable,
            ..
        } => Err(ExportError::Source(snapshot_refusal_message())),
    }
}

fn finish_pages(result: Result<(), ExportError>, finish: Result<(), ExportError>) -> Result<(), ExportError> {
    match (result, finish) {
        (Err(error), Err(cleanup)) => {
            crate::services::driver_diagnostics::warn_export_cleanup(&cleanup, "finish_after_error");
            Err(error)
        }
        (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(())) => Ok(()),
    }
}

pub(super) fn snapshot_refusal_message() -> String {
    crate::tr!("Full-table export requires a consistent snapshot. Export the current page or a query result instead.")
}

fn result_format(format: super::ExportFormat) -> ResultFormat {
    match format {
        super::ExportFormat::Csv => ResultFormat::Csv,
        super::ExportFormat::Json => ResultFormat::Json,
        super::ExportFormat::Markdown => ResultFormat::Markdown,
        super::ExportFormat::Html => ResultFormat::Html,
        super::ExportFormat::Xml => ResultFormat::Xml,
        super::ExportFormat::Sql => ResultFormat::Sql,
        super::ExportFormat::Xlsx => ResultFormat::Xlsx,
    }
}

pub(super) fn start(parent: &adw::ApplicationWindow, toast: &adw::ToastOverlay, job: ExportJob) {
    let cancel = CancellationToken::new();
    let completed = Arc::new(AtomicUsize::new(0));
    let (total, paged) = match &job.source {
        JobSource::Loaded(result) => (Some(result.rows.len()), false),
        JobSource::Paged { total, .. } => (*total, true),
    };
    let path = job.path.clone();
    let label = gtk::Label::new(Some(&if paged {
        crate::tr!("Exporting all rows…")
    } else {
        crate::tr!("Exporting loaded rows…")
    }));
    let progress = gtk::ProgressBar::new();
    let stop = gtk::Button::with_label(&crate::tr!("Cancel"));
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    content.append(&label);
    content.append(&progress);
    content.append(&stop);
    let dialog = adw::Dialog::builder()
        .title(crate::tr!("Export Results"))
        .child(&content)
        .content_width(400)
        .build();
    stop.connect_clicked({
        let cancel = cancel.clone();
        move |button| {
            cancel.cancel();
            button.set_sensitive(false);
        }
    });
    dialog.connect_closed({
        let cancel = cancel.clone();
        move |_| cancel.cancel()
    });
    dialog.present(Some(parent));
    let (send, recv) = async_channel::bounded(1);
    let count = completed.clone();
    let final_count = completed.clone();
    let worker = std::thread::Builder::new().name("result-export".into()).spawn(move || {
        let _ = send.send_blocking(write_export(job, &cancel, &count));
    });
    if let Err(error) = worker {
        dialog.close();
        super::show_export_error(parent, &path, &ExportError::Write(error));
        return;
    }
    let timer = glib::timeout_add_local(std::time::Duration::from_millis(100), move || {
        let done = completed.load(Ordering::Relaxed);
        match total {
            Some(total) => {
                progress.set_fraction(if total == 0 { 0.0 } else { done as f64 / total as f64 });
                label.set_label(
                    &crate::tr!("{done} / {total} rows")
                        .replace("{done}", &done.to_string())
                        .replace("{total}", &total.to_string()),
                );
            }
            None => {
                progress.pulse();
                label.set_label(&crate::tr!("{done} rows written").replace("{done}", &done.to_string()));
            }
        }
        glib::ControlFlow::Continue
    });
    let parent = parent.downgrade();
    let toast = toast.downgrade();
    glib::spawn_future_local(async move {
        let outcome = recv.recv().await;
        timer.remove();
        dialog.close();
        match outcome {
            Ok(Ok(())) => {
                if let Some(toast) = toast.upgrade() {
                    toast.add_toast(adw::Toast::new(
                        &crate::tr!("Exported {n} rows to {path}")
                            .replace("{n}", &final_count.load(Ordering::Relaxed).to_string())
                            .replace("{path}", &path.display().to_string()),
                    ));
                }
            }
            Ok(Err(error)) if error.is_cancelled() => {}
            Ok(Err(error)) => {
                if let Some(parent) = parent.upgrade() {
                    super::show_export_error(&parent, &path, &error);
                }
            }
            Err(_) => {
                if let Some(parent) = parent.upgrade() {
                    let stopped = ExportError::Write(std::io::Error::other("Export worker stopped"));
                    super::show_export_error(&parent, &path, &stopped);
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Default)]
    struct Capture(Arc<std::sync::Mutex<Vec<u8>>>);

    impl std::io::Write for Capture {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn cleanup_warning_keeps_source_payloads_out_of_logs_and_preserves_the_primary_error() {
        let capture = Capture::default();
        let writer = capture.clone();
        let subscriber = tracing_subscriber::fmt()
            .without_time()
            .with_ansi(false)
            .with_writer(move || writer.clone())
            .finish();
        let _guard = tracing::subscriber::set_default(subscriber);
        let outcome = finish_pages(
            Err(ExportError::Source("primary-private-marker".into())),
            Err(ExportError::Source("cleanup-private-marker".into())),
        );
        assert!(matches!(outcome, Err(ExportError::Source(message)) if message == "primary-private-marker"));
        let output = String::from_utf8(capture.0.lock().unwrap().clone()).unwrap();
        assert!(!output.contains("private-marker"));
        assert!(output.contains("cleanup failed"));
    }

    fn job(path: std::path::PathBuf, source: JobSource) -> ExportJob {
        ExportJob {
            path,
            source,
            format: super::super::ExportFormat::Csv,
            options: CsvOptions::default(),
            driver_id: "postgres".into(),
            schema: None,
            table: "t".into(),
        }
    }

    #[test]
    fn an_unverified_paged_export_never_opens_its_source_or_replaces_a_file() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("saved.csv");
        std::fs::write(&path, "existing export").unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let opened = calls.clone();
        let source = JobSource::Paged {
            mode: super::super::PagedExportMode::FullTable,
            columns: Vec::new(),
            total: None,
            open: Arc::new(move |_| {
                opened.fetch_add(1, Ordering::SeqCst);
                super::super::PageFetcher::new(|| Ok(None), || Ok(()))
            }),
        };
        let outcome = write_export(
            job(path.clone(), source),
            &CancellationToken::new(),
            &AtomicUsize::new(0),
        );
        assert!(matches!(outcome, Err(ExportError::Source(_))));
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "existing export");
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn a_loaded_result_still_exports_successfully() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("result.csv");
        let source = JobSource::Loaded(Arc::new(tablepro_core::QueryResult {
            columns: vec![tablepro_core::ColumnInfo {
                name: "label".into(),
                data_type: "text".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: vec![vec![tablepro_core::Value::Text("hello, export".into())]],
            truncated: false,
        }));
        write_export(
            job(path.clone(), source),
            &CancellationToken::new(),
            &AtomicUsize::new(0),
        )
        .unwrap();
        assert_eq!(std::fs::read_to_string(path).unwrap(), "label\n\"hello, export\"\n");
    }

    #[test]
    fn a_guarded_query_export_finishes_its_source_after_writing() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("query.csv");
        let finished = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let finished_source = finished.clone();
        let source = JobSource::Paged {
            mode: super::super::PagedExportMode::GuardedQuery,
            columns: vec![tablepro_core::ColumnInfo {
                name: "id".into(),
                data_type: "BIGINT".into(),
                nullable: false,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            total: None,
            open: Arc::new(move |_| {
                let mut sent = false;
                let finished = finished_source.clone();
                super::super::PageFetcher::new(
                    move || {
                        if sent {
                            return Ok(None);
                        }
                        sent = true;
                        Ok(Some(vec![vec![tablepro_core::Value::Int(42)]]))
                    },
                    move || {
                        finished.store(true, Ordering::SeqCst);
                        Ok(())
                    },
                )
            }),
        };

        write_export(
            job(path.clone(), source),
            &CancellationToken::new(),
            &AtomicUsize::new(0),
        )
        .unwrap();

        assert!(finished.load(Ordering::SeqCst));
        assert_eq!(std::fs::read_to_string(path).unwrap(), "id\n42\n");
    }

    #[test]
    fn a_cancelled_guarded_query_export_still_finishes_its_source() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("query.csv");
        let cancel = CancellationToken::new();
        let finished = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let finished_source = finished.clone();
        let source = JobSource::Paged {
            mode: super::super::PagedExportMode::GuardedQuery,
            columns: vec![tablepro_core::ColumnInfo {
                name: "id".into(),
                data_type: "BIGINT".into(),
                nullable: false,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            total: None,
            open: Arc::new(move |cancel| {
                let finished = finished_source.clone();
                let mut sent = false;
                super::super::PageFetcher::new(
                    move || {
                        if sent {
                            return Ok(None);
                        }
                        sent = true;
                        cancel.cancel();
                        Ok(Some(vec![vec![tablepro_core::Value::Int(42)]]))
                    },
                    move || {
                        finished.store(true, Ordering::SeqCst);
                        Ok(())
                    },
                )
            }),
        };
        let rows = Arc::new(AtomicUsize::new(0));
        let rows_written = rows.clone();
        let outcome = write_export(job(path.clone(), source), &cancel, &rows);
        assert!(matches!(outcome, Err(ExportError::Cancelled)));
        assert!(finished.load(Ordering::SeqCst));
        assert_eq!(rows_written.load(Ordering::SeqCst), 0);
        assert!(!path.exists());
    }

    #[test]
    fn a_failed_guarded_query_export_finishes_its_source_and_keeps_the_source_error() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("query.csv");
        let finished = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let finished_source = finished.clone();
        let source = JobSource::Paged {
            mode: super::super::PagedExportMode::GuardedQuery,
            columns: Vec::new(),
            total: None,
            open: Arc::new(move |_| {
                let finished = finished_source.clone();
                super::super::PageFetcher::new(
                    || Err(ExportError::Source("source page failed".into())),
                    move || {
                        finished.store(true, Ordering::SeqCst);
                        Ok(())
                    },
                )
            }),
        };

        let outcome = write_export(
            job(path.clone(), source),
            &CancellationToken::new(),
            &AtomicUsize::new(0),
        );

        assert!(matches!(outcome, Err(ExportError::Source(message)) if message == "source page failed"));
        assert!(finished.load(Ordering::SeqCst));
        assert!(!path.exists());
    }
}
