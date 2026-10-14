use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::{QueryHistory, StorageError};

use crate::i18n::gettext;
use crate::ui::export::{ExportFailure, FinishError, ReplaceFileWriter, failure_text};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ExportKind {
    Sql,
    Csv,
}

impl ExportKind {
    pub(super) async fn render(self, history: QueryHistory, ids: Vec<i64>) -> Result<String, StorageError> {
        match self {
            Self::Sql => history.export_sql(&ids).await,
            Self::Csv => history.export_csv(&ids).await,
        }
    }

    fn suggested_name(self) -> &'static str {
        match self {
            Self::Sql => "tablepro-history.sql",
            Self::Csv => "tablepro-history.csv",
        }
    }

    fn filter(self) -> gtk::FileFilter {
        let filter = gtk::FileFilter::new();
        match self {
            Self::Sql => {
                filter.set_name(Some(&gettext("SQL files")));
                filter.add_mime_type("text/x-sql");
                filter.add_suffix("sql");
            }
            Self::Csv => {
                filter.set_name(Some(&gettext("CSV files")));
                filter.add_mime_type("text/csv");
                filter.add_suffix("csv");
            }
        }
        filter
    }
}

/// Ask where to keep `content`, then write it there.
pub(super) fn save_export(parent: &adw::Dialog, kind: ExportKind, content: String) {
    let filter = kind.filter();
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    let chooser = gtk::FileDialog::builder()
        .title(gettext("Export Query History"))
        .modal(true)
        .initial_name(kind.suggested_name())
        .default_filter(&filter)
        .filters(&filters)
        .build();
    let window = parent.root().and_downcast::<gtk::Window>();
    let parent = parent.clone().upcast::<gtk::Widget>();
    glib::spawn_future_local(async move {
        // Cancelling the chooser is the only way it fails without a file.
        let Ok(file) = chooser.save_future(window.as_ref()).await else {
            return;
        };
        write_history_export(&parent, &file, content).await;
    });
}

/// Write the exported history to `file`, and say over `parent` when it
/// fails and what it left of the file.
pub(super) async fn write_history_export(parent: &gtk::Widget, file: &gio::File, content: String) {
    let written = async {
        let writer = ReplaceFileWriter::open(file)
            .await
            .map_err(|error| (ExportFailure::from(error), None))?;
        if let Err(error) = writer.write(content.into_bytes()).await {
            return Err((error.into(), Some(writer.abort().await)));
        }
        writer
            .finish()
            .await
            .map_err(|FinishError { error, file }| (error.into(), Some(file)))
    }
    .await;
    if let Err((failure, left)) = written {
        tracing::warn!(%failure, path = %file.parse_name(), "history export write failed");
        let name = file.basename().map_or_else(
            || file.parse_name().to_string(),
            |name| name.to_string_lossy().into_owned(),
        );
        show_export_failure(parent, &failure_text(&failure, left, &name));
    }
}

/// Why the entries could not be read for an export. The storage error
/// is logged; its text is not translated.
pub(super) fn history_export_failure_text(error: &StorageError) -> String {
    match error {
        StorageError::Encode(_) => gettext("The selected entries couldn't be written as CSV."),
        _ => gettext("The selected entries couldn't be read from the query history."),
    }
}

pub(super) fn show_export_failure(parent: &gtk::Widget, body: &str) {
    let alert = adw::AlertDialog::new(Some(&gettext("Couldn't Export")), Some(body));
    alert.add_response("close", &gettext("_Close"));
    alert.set_default_response(Some("close"));
    alert.set_close_response("close");
    alert.present(Some(parent));
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::test_support::finish_on_main;
    use crate::workspace::visible_alert;

    #[gtk4::test]
    fn history_export_failure_presents_alert() {
        adw::init().expect("libadwaita initialises under the test backend");
        let window = adw::Window::new();
        window.present();
        let dir = tempfile::tempdir().expect("tempdir");
        let file = gio::File::for_path(dir.path().join("missing").join("history.csv"));
        let parent = window.clone().upcast::<gtk::Widget>();

        finish_on_main(Duration::from_secs(10), async move {
            write_history_export(&parent, &file, "query\n".to_owned()).await;
        })
        .expect("the write to end");

        let alert = visible_alert(&window).expect("an alert");
        assert_eq!(alert.heading().as_deref(), Some("Couldn't Export"));
        assert!(
            alert.body().contains("history.csv"),
            "the alert does not name the file: {}",
            alert.body()
        );
        assert!(!alert.body().contains("incomplete"), "{}", alert.body());
    }

    #[test]
    fn history_export_failure_text_is_not_the_storage_error() {
        let errors = [
            StorageError::NotInitialised,
            StorageError::Encode(tablepro_core::export::RenderError::Flush(std::io::Error::other("full"))),
        ];

        for error in errors {
            let text = history_export_failure_text(&error);
            assert!(!text.contains(&error.to_string()), "{text}");
            assert!(text.starts_with("The selected entries couldn't"), "{text}");
        }
    }
}
