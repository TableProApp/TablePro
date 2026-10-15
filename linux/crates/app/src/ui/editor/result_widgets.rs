use gtk4::prelude::*;
use libadwaita as adw;

use super::run_log::{EntryKind, RunLogEntry};
use crate::ui::export::ExportSource;
use crate::ui::grid::GridSink;
use crate::ui::icons;
use crate::ui::result_pane::result_set_page;

/// What a page's buttons reach in the editor.
pub struct PageActions<G, E> {
    /// Put the editor cursor where the server says a statement went
    /// wrong.
    pub go_to_error: G,
    /// Offer every row of a result the row limit cut short, with the
    /// rows its grid shows.
    pub export_all: E,
}

/// The widget a results list line shows.
pub fn entry_widget<G, E>(entry: &RunLogEntry, grid_sink: &GridSink, actions: PageActions<G, E>) -> gtk4::Widget
where
    G: Fn(usize) + 'static,
    E: Fn(ExportSource) + 'static,
{
    let PageActions {
        go_to_error,
        export_all,
    } = actions;
    match &entry.kind {
        EntryKind::ResultSet(result) => result_set_page(result, grid_sink.clone(), export_all),
        EntryKind::Command { rows_affected } => {
            let title = match rows_affected {
                Some(rows) => crate::i18n::ngettext_f(
                    "{n} Row Affected",
                    "{n} Rows Affected",
                    u32::try_from(*rows).unwrap_or(u32::MAX),
                    &[("n", &rows.to_string())],
                ),
                None => crate::i18n::gettext("Command Completed"),
            };
            status_page(&title, &entry.preview, icons::SUCCESS).upcast()
        }
        EntryKind::Notice { message } => {
            status_page(&crate::i18n::gettext("Notice"), message, icons::TEXT_X_GENERIC).upcast()
        }
        EntryKind::Failed { message, error_char } => {
            let page = status_page(&crate::i18n::gettext("Statement Failed"), message, icons::DIALOG_ERROR);
            if let Some(position) = *error_char {
                let button = gtk4::Button::builder()
                    .label(crate::i18n::gettext("Go to Error"))
                    .halign(gtk4::Align::Center)
                    .build();
                button.add_css_class("pill");
                button.connect_clicked(move |_| go_to_error(position));
                page.set_child(Some(&button));
            }
            page.upcast()
        }
        EntryKind::ClientWarning { message } => status_page(
            &crate::i18n::gettext("Check the Script"),
            message,
            icons::DIALOG_WARNING,
        )
        .upcast(),
        EntryKind::Cancelled => status_page(
            &crate::i18n::gettext("Query Stopped"),
            &crate::i18n::gettext("The running query was stopped."),
            icons::PROCESS_STOP,
        )
        .upcast(),
        EntryKind::TimedOut { server_cancelled } => {
            let description = if *server_cancelled {
                crate::i18n::gettext(
                    "The statement ran past the time limit set in Preferences, so the server stopped it.",
                )
            } else {
                crate::i18n::gettext(
                    "The statement ran past the time limit set in Preferences. The server may still be running it.",
                )
            };
            status_page(
                &crate::i18n::gettext("Query Timed Out"),
                &description,
                icons::DIALOG_WARNING,
            )
            .upcast()
        }
        EntryKind::NotRun => status_page(
            &crate::i18n::gettext("Not Run"),
            &crate::i18n::gettext("Skipped because an earlier statement failed or the run was stopped."),
            icons::STATEMENT_PENDING,
        )
        .upcast(),
    }
}

/// A status page whose description is shown as written. The property
/// takes Pango markup, so a server message with a `<` in it would be
/// read as markup otherwise.
fn status_page(title: &str, description: &str, icon: &str) -> adw::StatusPage {
    adw::StatusPage::builder()
        .title(title)
        .description(glib::markup_escape_text(description).as_str())
        .icon_name(icon)
        .vexpand(true)
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sink() -> GridSink {
        std::rc::Rc::new(|_| {})
    }

    fn actions<G: Fn(usize) + 'static>(go_to_error: G) -> PageActions<G, impl Fn(ExportSource) + 'static> {
        PageActions {
            go_to_error,
            export_all: |_| {},
        }
    }

    #[gtk4::test]
    fn markup_in_error_is_rendered_literally() {
        let entry = RunLogEntry {
            kind: EntryKind::Failed {
                message: "column <b>name</b> & more".to_owned(),
                error_char: None,
            },
            batch: Some(0),
            preview: String::new(),
        };

        let widget = entry_widget(&entry, &sink(), actions(|_| {}));

        let page = widget.downcast::<adw::StatusPage>().expect("a status page");
        assert_eq!(
            page.description().as_deref(),
            Some("column &lt;b&gt;name&lt;/b&gt; &amp; more")
        );
    }

    #[gtk4::test]
    fn go_to_error_reports_the_buffer_position() {
        let entry = RunLogEntry {
            kind: EntryKind::Failed {
                message: "syntax error".to_owned(),
                error_char: Some(42),
            },
            batch: Some(0),
            preview: String::new(),
        };
        let reached = std::rc::Rc::new(std::cell::Cell::new(None));
        let seen = reached.clone();

        let widget = entry_widget(&entry, &sink(), actions(move |position| seen.set(Some(position))));
        let page = widget.downcast::<adw::StatusPage>().expect("a status page");
        let button = page.child().and_downcast::<gtk4::Button>().expect("Go to Error");
        button.emit_clicked();

        assert_eq!(reached.get(), Some(42));
    }
}
