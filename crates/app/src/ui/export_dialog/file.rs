use adw::prelude::*;
use relm4::{adw, gtk};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tablepro_core::export::{CsvOptions, ExportError, ResultExport, ResultFormat, SqlTarget};
use tokio_util::sync::CancellationToken;

pub(super) enum JobSource {
    Loaded(tablepro_core::QueryResult),
    Paged {
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
        JobSource::Paged { columns, total, open } => tablepro_core::export::write_paged_file(
            &job.path,
            &columns,
            total.unwrap_or(0),
            &export,
            open(cancel.clone()),
            cancelled,
            progress,
        ),
    }
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
