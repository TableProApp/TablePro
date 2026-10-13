use gtk4::prelude::*;
use libadwaita as adw;

use super::run_log::{EntryKind, RunLogEntry};
use crate::ui::grid::{GridSink, RowObject, TabGridContext, build_column_view};
use crate::ui::icons;

/// The widget a results list line shows. `go_to_error` puts the editor
/// cursor where the server says a statement went wrong.
pub fn entry_widget(entry: &RunLogEntry, grid_sink: &GridSink, go_to_error: impl Fn(usize) + 'static) -> gtk4::Widget {
    match &entry.kind {
        EntryKind::ResultSet { result, total_rows } => {
            let rows = result.rows.iter().map(|cells| RowObject::result(cells.clone().into()));
            let (column_view, _selection) = build_column_view(
                result,
                rows,
                &[],
                grid_sink.clone(),
                None,
                false,
                TabGridContext::default(),
            );
            let scrolled = gtk4::ScrolledWindow::builder()
                .child(&column_view)
                .hexpand(true)
                .vexpand(true)
                .build();
            let footer = gtk4::Label::builder()
                .label(row_count_text(result.row_count(), result.truncated, *total_rows))
                .xalign(0.0)
                .margin_start(12)
                .margin_end(12)
                .margin_top(4)
                .margin_bottom(4)
                .build();
            footer.add_css_class("dim-label");
            footer.add_css_class("caption");
            let page = gtk4::Box::builder().orientation(gtk4::Orientation::Vertical).build();
            page.append(&scrolled);
            page.append(&footer);
            page.upcast()
        }
        EntryKind::Command { rows_affected } => {
            let title = match rows_affected {
                Some(rows) => crate::i18n::ngettext_f(
                    "{n} row affected",
                    "{n} rows affected",
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

fn row_count_text(rows: usize, truncated: bool, total: Option<u64>) -> String {
    let shown = rows.to_string();
    match (truncated, total) {
        (true, Some(total)) => crate::i18n::gettext_f(
            "Showing the first {shown} of {total} rows",
            &[("shown", &shown), ("total", &total.to_string())],
        ),
        (true, None) => crate::i18n::gettext_f(
            "Showing the first {shown} rows. The query returned more.",
            &[("shown", &shown)],
        ),
        (false, _) => crate::i18n::ngettext_f(
            "{n} row",
            "{n} rows",
            u32::try_from(rows).unwrap_or(u32::MAX),
            &[("n", &shown)],
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sink() -> GridSink {
        std::rc::Rc::new(|_| {})
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

        let widget = entry_widget(&entry, &sink(), |_| {});

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

        let widget = entry_widget(&entry, &sink(), move |position| seen.set(Some(position)));
        let page = widget.downcast::<adw::StatusPage>().expect("a status page");
        let button = page.child().and_downcast::<gtk4::Button>().expect("Go to Error");
        button.emit_clicked();

        assert_eq!(reached.get(), Some(42));
    }

    #[test]
    fn a_truncated_set_says_so() {
        assert!(row_count_text(10, true, Some(50)).contains("50"));
        assert!(row_count_text(10, true, None).contains("more"));
        assert_eq!(row_count_text(1, false, None), "1 row");
    }
}
