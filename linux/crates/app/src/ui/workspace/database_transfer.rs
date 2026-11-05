use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::{gio, glib};
use libadwaita::prelude::*;
use tablepro_core::dialect::DatabaseLayout;
use tablepro_core::import::{SqlImportOptions, SqlImportProgress, SqlImportReport, run_sql_import};
use tablepro_core::{EditorSessionOptions, SafeModeLevel};
use tablepro_session::Session;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::{WorkspaceInput, WorkspaceModel};
use crate::runtime::DeliverInput;
use crate::ui::dump_dialog::DumpDialogInit;
use crate::ui::sql_import_dialog::{SqlImportDialog, SqlImportDialogInit};

/// How often the import dialog's progress moves at most.
const PROGRESS_EVERY: Duration = Duration::from_millis(100);

/// Whether the session's engine writes a SQL dump and runs one back.
pub(crate) fn dumps(session: &Session) -> bool {
    session
        .current_dialect()
        .is_some_and(|dialect| dialect.dump().is_some())
}

/// Whether a SQL file may run on the session: its engine has a dump, and
/// neither the connection nor its Safe Mode is read-only.
pub(crate) fn imports_sql(session: &Session) -> bool {
    dumps(session) && !session.read_only() && session.safe_mode() != SafeModeLevel::ReadOnly
}

impl WorkspaceModel {
    /// Export Database: the scope and options, then the file to write.
    pub(super) fn on_export_database(&self) {
        let Some(session) = self.context.active.get() else {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        };
        if !dumps(&session) {
            self.show_error_alert(
                &crate::i18n::gettext("Couldn't Export"),
                &crate::i18n::gettext("This database cannot be exported as a SQL file."),
            );
            return;
        }
        let Some(window) = self.window() else {
            return;
        };
        let exports = self.exports.clone();
        let database = session
            .database()
            .map_or_else(|| session.metadata().name.clone(), str::to_owned);
        let layout = session
            .current_dialect()
            .map_or(DatabaseLayout::Single, |dialect| dialect.database_layout());
        let reading = session.clone();
        glib::spawn_future_local(async move {
            // The catalog's schemas are cached; a read that fails leaves
            // the whole database as the only choice.
            let schemas = match layout {
                DatabaseLayout::WithSchemas => reading
                    .schemas()
                    .await
                    .map(|schemas| {
                        schemas
                            .iter()
                            .filter(|schema| !schema.is_system)
                            .map(|schema| schema.name.clone())
                            .collect()
                    })
                    .unwrap_or_default(),
                DatabaseLayout::Single | DatabaseLayout::AsSchemas => Vec::new(),
            };
            crate::ui::dump_dialog::present(DumpDialogInit {
                parent: window,
                exports,
                session: reading,
                database,
                schemas,
            });
        });
    }

    /// Import SQL File: the file, then its options, its progress and
    /// what it did, in one dialog.
    pub(super) fn on_import_sql_file(&self) {
        let Some(session) = self.context.active.get() else {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        };
        if !imports_sql(&session) {
            let message = match dumps(&session) {
                true => crate::i18n::gettext("This connection is read-only."),
                false => crate::i18n::gettext("This database cannot run a SQL file."),
            };
            self.show_error_alert(&crate::i18n::gettext("Couldn't Import"), &message);
            return;
        }
        let filter = gtk::FileFilter::new();
        filter.set_name(Some(&crate::i18n::gettext("SQL files")));
        filter.add_suffix("sql");
        filter.add_suffix("gz");
        filter.add_mime_type("application/sql");
        filter.add_mime_type("application/gzip");
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let file_dialog = gtk::FileDialog::builder()
            .title(crate::i18n::gettext("Import SQL File"))
            .modal(true)
            .default_filter(&filter)
            .filters(&filters)
            .build();
        let input = self.input.clone();
        file_dialog.open(self.window().as_ref(), gio::Cancellable::NONE, move |chosen| {
            if let Ok(file) = chosen {
                input.deliver(WorkspaceInput::ImportSqlFileChosen(file));
            }
        });
    }

    pub(super) fn on_import_sql_file_chosen(&self, file: gio::File) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        let Some(path) = file.path() else {
            self.show_error_alert(
                &crate::i18n::gettext("Couldn't Import"),
                &crate::i18n::gettext("Choose a file on this computer."),
            );
            return;
        };
        let size = std::fs::metadata(&path).map(|metadata| metadata.len()).unwrap_or(0);
        let file_name = file.basename().map_or_else(
            || file.parse_name().to_string(),
            |name| name.to_string_lossy().into_owned(),
        );
        let transactional = session
            .current_dialect()
            .and_then(|dialect| dialect.dump().map(|dump| dump.transactional_ddl()))
            .unwrap_or(false);
        let init = SqlImportDialogInit {
            file_name,
            file_size: size,
            connection: session.metadata().name.clone(),
            transactional,
            confirms_writes: session.safe_mode() == SafeModeLevel::ConfirmWrites,
        };
        let running: Rc<RefCell<Option<CancellationToken>>> = Rc::default();
        let stopping = running.clone();
        let started = Rc::new(RefCell::new(None::<StartImport>));
        let starting = started.clone();
        let dialog = SqlImportDialog::new(
            &init,
            move |options| {
                if let Some(start) = starting.borrow_mut().take() {
                    start.run(options);
                }
            },
            move || {
                if let Some(cancel) = stopping.borrow().as_ref() {
                    cancel.cancel();
                }
            },
        );
        started.replace(Some(StartImport {
            session,
            path,
            running,
            dialog: Rc::downgrade(&dialog),
            imports: self.imports.clone(),
            tasks: self.context.tasks.clone(),
            input: self.input.clone(),
        }));
        if let Some(parent) = self.dialog_parent() {
            dialog.present(&parent);
        }
        // The dialog lives while it is shown: it cannot close during an
        // import, and once closed it lets itself go.
        let keeper = Rc::new(RefCell::new(Some(dialog.clone())));
        dialog.dialog().connect_closed(move |_| {
            keeper.borrow_mut().take();
        });
    }
}

/// What Import needs once its button is clicked.
struct StartImport {
    session: Arc<Session>,
    path: std::path::PathBuf,
    /// The running import's stop, which the dialog's Stop fires.
    running: Rc<RefCell<Option<CancellationToken>>>,
    dialog: std::rc::Weak<SqlImportDialog>,
    imports: Rc<super::import_ledger::ImportLedger>,
    tasks: tablepro_session::runtime::Tasks,
    input: super::WorkspaceSender,
}

impl StartImport {
    fn run(self, options: SqlImportOptions) {
        let Some(ticket) = self.imports.begin() else {
            if let Some(dialog) = self.dialog.upgrade() {
                dialog.show_failure(&crate::i18n::gettext("The window is closing."));
            }
            return;
        };
        // The dialog's Stop and the window's close stop the same import.
        let cancel = ticket.cancel.clone();
        self.running.replace(Some(cancel.clone()));
        let (progress, mut seen) = watch::channel(SqlImportProgress::default());
        let dialog = self.dialog.clone();
        glib::spawn_future_local(async move {
            while seen.changed().await.is_ok() {
                let latest = *seen.borrow_and_update();
                let Some(dialog) = dialog.upgrade() else {
                    return;
                };
                dialog.show_progress(latest);
                drop(dialog);
                glib::timeout_future(PROGRESS_EVERY).await;
            }
        });
        let work = import(self.session.clone(), self.path, options, progress, cancel);
        let imports = self.imports.clone();
        let input = self.input.clone();
        let dialog = self.dialog;
        let _delivery = crate::runtime::spawn_and_deliver(&self.tasks, work, move |finished| {
            imports.settle(ticket.id);
            input.deliver(WorkspaceInput::SchemaChanged {
                schema: None,
                table: None,
            });
            let Some(dialog) = dialog.upgrade() else {
                return;
            };
            match finished {
                Ok(Ok(report)) => dialog.show_report(&report),
                Ok(Err(message)) => dialog.show_failure(&message),
                Err(failure) => dialog.show_failure(&crate::ui::error_text::task_failure_message(&failure)),
            }
        });
    }
}

/// Open an editor session of the import's own and run the file on it, so
/// what the file sets stays on that session, then close it.
async fn import(
    session: Arc<Session>,
    path: std::path::PathBuf,
    options: SqlImportOptions,
    progress: watch::Sender<SqlImportProgress>,
    cancel: CancellationToken,
) -> Result<SqlImportReport, String> {
    let Some(dialect) = session.current_dialect() else {
        return Err(crate::i18n::gettext("Connect to a database first."));
    };
    let file = std::fs::File::open(&path).map_err(|error| {
        crate::i18n::gettext_f("The file cannot be read: {detail}", &[("detail", &error.to_string())])
    })?;
    let editor = session
        .open_editor_session(EditorSessionOptions::default(), &cancel)
        .await
        .map_err(|error| crate::ui::error_text::operation_error_message(&error))?;
    let mut report_progress = move |latest: SqlImportProgress| {
        progress.send_replace(latest);
    };
    let report = run_sql_import(
        editor.as_ref(),
        &*dialect,
        Box::new(file),
        options,
        &mut report_progress,
        &cancel,
    )
    .await;
    editor.close().await;
    tracing::info!(
        statements = report.statements,
        failed = report.failed,
        end = ?report.end,
        "ran a SQL file"
    );
    Ok(report)
}
