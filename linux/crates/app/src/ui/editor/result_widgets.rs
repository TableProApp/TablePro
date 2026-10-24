use gtk4::prelude::*;
use libadwaita as adw;

use super::run_log::{EntryKind, RunLogEntry};
use crate::ui::export::ExportSource;
use crate::ui::grid::GridSink;
use crate::ui::icons;
use crate::ui::result_pane::result_set_page;

/// What a page's buttons reach in the editor.
pub struct PageActions<G, E, F> {
    /// Put the editor cursor where the server says a statement went
    /// wrong.
    pub go_to_error: G,
    /// Offer every row of a result the row limit cut short, with the
    /// rows its grid shows.
    pub export_all: E,
    /// Ask the assistant to fix a failed statement. `None` where the tab
    /// has no assistant.
    pub fix: Option<FixHook<F>>,
}

/// Fix with AI on a failed statement's page. The page is built once and
/// kept, so the button follows `available` rather than how things were
/// when the statement failed.
pub struct FixHook<F> {
    pub run: F,
    pub available: gtk4::gio::SimpleAction,
}

/// The widget the results list's `index`th line shows. `in_clause` is
/// false where the engine has no SQL to copy rows into.
pub fn entry_widget<G, E, F>(
    index: usize,
    entry: &RunLogEntry,
    grid_sink: &GridSink,
    in_clause: bool,
    actions: PageActions<G, E, F>,
) -> gtk4::Widget
where
    G: Fn(usize) + 'static,
    E: Fn(ExportSource) + 'static,
    F: Fn() + 'static,
{
    let PageActions {
        go_to_error,
        export_all,
        fix,
    } = actions;
    match &entry.kind {
        EntryKind::ResultSet(result) => result_set_page(
            result,
            &result.summary.tab_label(index),
            grid_sink.clone(),
            in_clause,
            export_all,
        ),
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
        EntryKind::Failed { message, error_char } => failed_page(message, *error_char, go_to_error, fix),
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

/// A failed statement's page: Go to Error where the server says where,
/// and Fix with AI while the assistant may send from here.
fn failed_page<G, F>(message: &str, error_char: Option<usize>, go_to_error: G, fix: Option<FixHook<F>>) -> gtk4::Widget
where
    G: Fn(usize) + 'static,
    F: Fn() + 'static,
{
    let page = status_page(&crate::i18n::gettext("Statement Failed"), message, icons::DIALOG_ERROR);
    let go = error_char.map(|position| {
        let button = gtk4::Button::builder()
            .label(crate::i18n::gettext("Go to Error"))
            .halign(gtk4::Align::Center)
            .build();
        button.add_css_class("pill");
        button.connect_clicked(move |_| go_to_error(position));
        button
    });
    let fix = fix.map(|FixHook { run, available }| {
        let button = gtk4::Button::builder()
            .label(crate::i18n::gettext("Fix with AI"))
            .halign(gtk4::Align::Center)
            .build();
        button.add_css_class("pill");
        available
            .bind_property("enabled", &button, "visible")
            .sync_create()
            .build();
        button.connect_clicked(move |_| run());
        button
    });
    match (go, fix) {
        (Some(go), Some(fix)) => {
            let buttons = gtk4::Box::new(gtk4::Orientation::Horizontal, 12);
            buttons.set_halign(gtk4::Align::Center);
            buttons.append(&go);
            buttons.append(&fix);
            page.set_child(Some(&buttons));
        }
        (Some(only), None) | (None, Some(only)) => page.set_child(Some(&only)),
        (None, None) => {}
    }
    page.upcast()
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

    fn actions<G: Fn(usize) + 'static>(
        go_to_error: G,
    ) -> PageActions<G, impl Fn(ExportSource) + 'static, impl Fn() + 'static> {
        PageActions {
            go_to_error,
            export_all: |_| {},
            fix: None::<FixHook<fn()>>,
        }
    }

    #[gtk4::test]
    fn a_result_grid_is_named_as_its_line_in_the_list() {
        let columns: std::sync::Arc<[tablepro_core::column::ResultColumn]> =
            std::sync::Arc::from([tablepro_core::column::ResultColumn::new(
                "a",
                tablepro_core::column::ColumnType::untyped_text("text"),
            )]);
        let view = crate::ui::result_pane::ResultSetView::new(columns, tablepro_core::UserSql::new("SELECT a FROM t"));
        let name = view.summary.tab_label(1);
        let entry = RunLogEntry {
            kind: EntryKind::ResultSet(view),
            batch: Some(0),
            preview: String::new(),
        };

        let widget = entry_widget(1, &entry, &sink(), true, actions(|_| {}));

        let grid = crate::test_support::first_descendant_of_type::<gtk4::ColumnView>(&widget).expect("the grid");
        assert_eq!(name, "Result 2 (0)");
        assert!(gtk4::test_accessible_has_property(
            &grid,
            gtk4::AccessibleProperty::Label
        ));
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

        let widget = entry_widget(0, &entry, &sink(), true, actions(|_| {}));

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

        let widget = entry_widget(
            0,
            &entry,
            &sink(),
            true,
            actions(move |position| seen.set(Some(position))),
        );
        let page = widget.downcast::<adw::StatusPage>().expect("a status page");
        let button = page.child().and_downcast::<gtk4::Button>().expect("Go to Error");
        button.emit_clicked();

        assert_eq!(reached.get(), Some(42));
    }

    #[gtk4::test]
    fn a_failed_statement_offers_a_fix_beside_go_to_error() {
        let entry = RunLogEntry {
            kind: EntryKind::Failed {
                message: "syntax error".to_owned(),
                error_char: Some(3),
            },
            batch: Some(0),
            preview: String::new(),
        };
        let asked = std::rc::Rc::new(std::cell::Cell::new(false));
        let seen = asked.clone();
        let available = gtk4::gio::SimpleAction::new("ai-explain", None);

        let widget = entry_widget(
            0,
            &entry,
            &sink(),
            true,
            PageActions {
                go_to_error: |_| {},
                export_all: |_| {},
                fix: Some(FixHook {
                    run: move || seen.set(true),
                    available: available.clone(),
                }),
            },
        );
        let fix = crate::test_support::descendants(&widget)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
            .find(|button| button.label().as_deref() == Some("Fix with AI"))
            .expect("Fix with AI");
        fix.emit_clicked();

        assert!(asked.get());
        assert!(fix.is_visible());
        available.set_enabled(false);
        assert!(!fix.is_visible(), "Fix with AI stayed after the assistant went off");
        assert!(
            crate::test_support::descendants(&widget)
                .into_iter()
                .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
                .any(|button| button.label().as_deref() == Some("Go to Error"))
        );
    }
}
