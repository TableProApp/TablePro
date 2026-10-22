use std::cell::Cell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw, gtk};
use uuid::Uuid;

use super::{SqlEditor, SqlEditorInput, StatementOutcomeKind};

pub(super) struct TransactionActions {
    pub(super) row: gtk::FlowBox,
    id: Rc<Cell<Option<Uuid>>>,
}

impl TransactionActions {
    pub(super) fn install(toolbar: &adw::ToolbarView, sender: &ComponentSender<SqlEditor>) -> Self {
        let row = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .min_children_per_line(1)
            .max_children_per_line(3)
            .column_spacing(6)
            .row_spacing(4)
            .margin_start(8)
            .margin_end(8)
            .visible(false)
            .build();
        row.set_widget_name("editor-transaction-actions");
        let label = gtk::Label::new(Some(&crate::tr!("Transaction active")));
        label.add_css_class("warning");
        row.insert(&label, -1);
        let id = Rc::new(Cell::new(None));
        for (label, commit) in [
            (crate::tr!("Commit & close session"), true),
            (crate::tr!("Roll back & close session"), false),
        ] {
            let button = gtk::Button::with_label(&label);
            let active = id.clone();
            let sender = sender.clone();
            button.connect_clicked(move |_| {
                if let Some(session_id) = active.get() {
                    sender.input(SqlEditorInput::SessionAction { session_id, commit });
                }
            });
            row.insert(&button, -1);
        }
        toolbar.add_top_bar(&row);
        Self { row, id }
    }
}

impl SqlEditor {
    pub(super) fn run_scope(&mut self, current: bool, sender: ComponentSender<Self>) {
        self.timeout_retry.clear_override();
        let buffer = self.source_view.buffer();
        let (start, end) = buffer.bounds();
        let sql = buffer.text(&start, &end, true).to_string();
        if current
            && self
                .metadata()
                .is_some_and(|metadata| super::grammar_for(&metadata.driver_id).is_none())
        {
            let cursor = super::cursor_byte_offset(&sql, buffer.cursor_position() as usize);
            let driver = self.metadata().map(|metadata| metadata.driver_id).unwrap_or_default();
            if let Some(text) = super::statement_at_cursor(&sql, self.lexing(&driver), cursor) {
                self.begin_run(text, None, true, sender);
            } else {
                self.status.set_label(&crate::tr!("No statement to run"));
            }
            return;
        }
        let range = if current {
            let cursor = super::cursor_byte_offset(&sql, buffer.iter_at_mark(&buffer.get_insert()).offset() as usize);
            let driver = self.metadata().map(|metadata| metadata.driver_id).unwrap_or_default();
            super::statement_cursor::statement_range_at(&sql, self.lexing(&driver), cursor)
        } else {
            let start = sql.len() - sql.trim_start().len();
            (!sql.trim().is_empty()).then_some(start..start + sql.trim().len())
        };
        let Some(range) = range else {
            self.status.set_label(&crate::tr!("No statement to run"));
            return;
        };
        let anchor = super::SourceAnchor {
            revision: self.drop_generation.revision(),
            start: sql[..range.start].chars().count(),
        };
        self.begin_run(sql[range].to_string(), Some(anchor), current, sender);
    }

    pub(super) fn session_action_idle(&self) -> bool {
        self.run_generation.active.is_empty()
            && !self.reading_lexing
            && !self.session_open_in_flight
            && self.ending_session_id.is_none()
            && !self.session_teardown_active
    }

    pub(super) fn sync_session_controls(&self) {
        let id = self.toolbar_transaction_id();
        self.session_button.set_label(&crate::tr!("Session"));
        self.session_button
            .update_property(&[gtk::accessible::Property::Label(&crate::tr!("Session"))]);
        self.transaction_actions.id.set(id);
        self.transaction_actions.row.set_visible(id.is_some());
        self.transaction_actions.row.set_sensitive(self.session_action_idle());
        self.run_options.set_sensitive(self.session_action_idle());
    }

    pub(super) fn refresh_run_options(&self, sender: &ComponentSender<Self>) {
        let group = gtk::gio::SimpleActionGroup::new();
        for (name, current) in [("all", false), ("current", true)] {
            let action = gtk::gio::SimpleAction::new(name, None);
            let sender = sender.clone();
            action.connect_activate(move |_, _| {
                sender.input(if current {
                    SqlEditorInput::RunAtCursor
                } else {
                    SqlEditorInput::Run
                })
            });
            group.add_action(&action);
        }
        if let Some(parent) = self.run_options.parent() {
            parent.insert_action_group("editor-run", Some(&group));
        }
        self.source_view.insert_action_group("editor-run", Some(&group));
        if let Some(root) = self.source_view.ancestor(adw::BreakpointBin::static_type()) {
            root.insert_action_group("editor-run", Some(&group));
        }
        self.refresh_result_exports();
    }

    pub(super) fn refresh_result_exports(&self) {
        let menu = gtk::gio::Menu::new();
        for (label, action, accelerator) in run_menu_items() {
            let item = gtk::gio::MenuItem::new(Some(&label), Some(action));
            item.set_attribute_value("accel", Some(&accelerator.to_variant()));
            menu.append_item(&item);
        }
        let exports = gtk::gio::Menu::new();
        let actions = gtk::gio::SimpleActionGroup::new();
        for (statement, outcome) in self.pinned.latest().iter().enumerate() {
            match &outcome.kind {
                StatementOutcomeKind::Rows(results) => {
                    for (result_set, result) in results.iter().enumerate() {
                        if result.columns.is_empty() {
                            continue;
                        }
                        let name = format!("result-{statement}-{result_set}");
                        let label = crate::tr!("Export loaded rows: statement {statement}, result {result}")
                            .replace("{statement}", &(statement + 1).to_string())
                            .replace("{result}", &(result_set + 1).to_string());
                        let action = gtk::gio::SimpleAction::new(&name, None);
                        let result = result.clone();
                        let sender = self.grid_sender.clone();
                        action.connect_activate(move |_, _| {
                            let _ = sender.send(super::GridMsg::ExportResults((*result).clone()));
                        });
                        actions.add_action(&action);
                        exports.append(Some(&label), Some(&format!("editor-export.{name}")));
                    }
                }
                StatementOutcomeKind::Streamed(result)
                    if !matches!(result.terminal, super::StreamTerminal::Loading) =>
                {
                    if let Some(request) = result.export.clone() {
                        let action = gtk::gio::SimpleAction::new("all-query-rows", None);
                        let sender = self.grid_sender.clone();
                        action.connect_activate(move |_, _| {
                            let _ = sender.send(super::GridMsg::ExportStreamedResults(request.clone()));
                        });
                        actions.add_action(&action);
                        exports.append(
                            Some(&crate::tr!("Export all query rows (run again)…")),
                            Some("editor-export.all-query-rows"),
                        );
                    }
                }
                _ => {}
            }
        }
        self.run_options.insert_action_group("editor-export", Some(&actions));
        if exports.n_items() > 0 {
            menu.append_section(Some(&crate::tr!("File output")), &exports);
        }
        self.run_options.set_menu_model(Some(&menu));
    }
}

pub(super) fn run_menu_items() -> [(String, &'static str, &'static str); 2] {
    [
        (
            crate::tr!("Run selection or all statements"),
            "editor-run.all",
            "<Primary>Return",
        ),
        (
            crate::tr!("Run current statement"),
            "editor-run.current",
            "<Primary><Shift>Return",
        ),
    ]
}
