//! Add-Index and Add-Foreign-Key form dialogs for the Structure tab.
//!
//! A form is an `adw::Dialog` with Cancel and a suggested action in
//! its header bar: the HIG keeps AlertDialog for confirmations. Its
//! fields are rows in an AdwPreferencesGroup, as in GNOME Settings'
//! "Add" dialogs.

use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;

use tablepro_core::ddl::{DraftColumn, ReferentialAction};
use tablepro_core::meta::IndexKey;
use tablepro_core::{ForeignKeyInfo, IndexInfo};

use super::structure_tab::{StructureTabInput, StructureTabOutput, StructureTabSender};

/// `(column name, checkbox)` pairs, shared between the dialog body
/// and the submit handler so the latter can collect which columns the
/// user ticked. Pulled out as an alias so `build_column_checklist`'s
/// return type stays under clippy's complexity threshold.
type ColumnChecks = Rc<RefCell<Vec<(String, gtk::CheckButton)>>>;

/// Build the standard form-dialog skeleton: AdwDialog with an
/// AdwToolbarView, a HeaderBar carrying Cancel + suggested-action
/// submit buttons, and a vertically-scrolling content box. Returned
/// `(dialog, content, submit_btn)` lets the caller append form
/// widgets to `content` and observe `submit_btn` for the Add action.
///
/// `submit_btn` is the dialog's default widget. A row that should
/// submit on Enter sets `activates-default` on itself, matching GNOME
/// Settings' Add-account dialogs.
fn build_form_dialog(title: &str, submit_label: &str) -> (adw::Dialog, gtk::Box, gtk::Button) {
    let dialog = adw::Dialog::builder()
        .title(title)
        .content_width(420)
        .content_height(560)
        .build();

    let header = adw::HeaderBar::builder()
        .show_start_title_buttons(false)
        .show_end_title_buttons(false)
        .build();
    let cancel_btn = gtk::Button::with_label(&crate::i18n::gettext("Cancel"));
    let submit_btn = gtk::Button::with_label(submit_label);
    submit_btn.add_css_class("suggested-action");
    header.pack_start(&cancel_btn);
    header.pack_end(&submit_btn);

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .margin_top(18)
        .margin_bottom(18)
        .margin_start(18)
        .margin_end(18)
        .build();
    let scroller = gtk::ScrolledWindow::builder()
        .child(&content)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .hexpand(true)
        .build();

    let toolbar_view = adw::ToolbarView::new();
    toolbar_view.add_top_bar(&header);
    toolbar_view.set_content(Some(&scroller));
    dialog.set_child(Some(&toolbar_view));
    // Enter submits. Each form row also carries activates-default,
    // which is what makes AdwEntryRow call gtk_widget_activate_default;
    // the default widget alone does nothing without it.
    dialog.set_default_widget(Some(&submit_btn));

    let dialog_for_cancel = dialog.clone();
    cancel_btn.connect_clicked(move |_| {
        dialog_for_cancel.close();
    });

    (dialog, content, submit_btn)
}

/// A heading for the column checklist, which is a boxed list rather
/// than a PreferencesGroup with a title of its own.
fn section_label(title: &str) -> gtk::Label {
    let label = gtk::Label::builder().label(title).xalign(0.0).build();
    label.add_css_class("heading");
    label
}

fn build_column_checklist(columns: &[DraftColumn]) -> (gtk::ListBox, ColumnChecks) {
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    list.add_css_class("boxed-list");
    let checks: ColumnChecks = Rc::new(RefCell::new(Vec::new()));
    for col in columns {
        let row = adw::ActionRow::builder().title(&col.name).build();
        let check = gtk::CheckButton::new();
        check.set_valign(gtk::Align::Center);
        row.add_suffix(&check);
        row.set_activatable_widget(Some(&check));
        list.append(&row);
        checks.borrow_mut().push((col.name.clone(), check));
    }
    (list, checks)
}

pub(super) fn present_index_dialog(parent: &gtk::Widget, columns: &[DraftColumn], sender: StructureTabSender) {
    let (dialog, body, submit_btn) =
        build_form_dialog(&crate::i18n::gettext("Add Index"), &crate::i18n::gettext("Add"));

    // Name + Unique inside one AdwPreferencesGroup. AdwEntryRow's
    // title slot doubles as the placeholder when empty (floats up
    // when filled), so no separate "Name" label is needed.
    let detail_group = adw::PreferencesGroup::builder().build();
    let name_row = adw::EntryRow::builder()
        .title(crate::i18n::gettext("Name"))
        .activates_default(true)
        .build();
    detail_group.add(&name_row);
    let unique_row = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Unique"))
        .subtitle(crate::i18n::gettext(
            "Reject inserts that duplicate the indexed columns",
        ))
        .build();
    detail_group.add(&unique_row);
    body.append(&detail_group);

    body.append(&section_label(&crate::i18n::gettext("Columns")));
    let (columns_list, column_checks) = build_column_checklist(columns);
    body.append(&columns_list);

    let column_checks_for_resp = column_checks.clone();
    let sender_for_resp = sender.clone();
    let dialog_for_submit = dialog.clone();
    submit_btn.connect_clicked(move |_| {
        let name = name_row.text().to_string();
        if name.trim().is_empty() {
            // Toast instead of silent no-op so the user knows why
            // their click didn't land.
            sender_for_resp.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
                "Index name is required.",
            )));
            return;
        }
        let cols: Vec<String> = column_checks_for_resp
            .borrow()
            .iter()
            .filter_map(|(n, c)| if c.is_active() { Some(n.clone()) } else { None })
            .collect();
        if cols.is_empty() {
            sender_for_resp.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
                "Select at least one column.",
            )));
            return;
        }
        sender_for_resp.input(StructureTabInput::AddIndex(IndexInfo {
            name,
            keys: cols
                .into_iter()
                .map(|name| IndexKey::Column {
                    name,
                    descending: false,
                })
                .collect(),
            unique: unique_row.is_active(),
            primary: false,
            predicate: None,
        }));
        dialog_for_submit.close();
    });

    dialog.present(Some(parent));
}

/// `fk_actions` are the engine's, from its DDL dialect, so the combos
/// offer nothing the engine would refuse.
pub(super) fn present_fk_dialog(
    parent: &gtk::Widget,
    columns: &[DraftColumn],
    fk_actions: &'static [ReferentialAction],
    sender: StructureTabSender,
) {
    let action_labels = action_labels(fk_actions);
    let (dialog, body, submit_btn) =
        build_form_dialog(&crate::i18n::gettext("Add Foreign Key"), &crate::i18n::gettext("Add"));

    let name_group = adw::PreferencesGroup::builder().build();
    let name_row = adw::EntryRow::builder()
        .title(crate::i18n::gettext("Name"))
        .activates_default(true)
        .build();
    name_group.add(&name_row);
    body.append(&name_group);

    body.append(&section_label(&crate::i18n::gettext("Source columns")));
    let (columns_list, column_checks) = build_column_checklist(columns);
    body.append(&columns_list);

    // The referenced columns are typed: the dialog does not read the
    // other table.
    let ref_group = adw::PreferencesGroup::builder()
        .title(crate::i18n::gettext("References"))
        .build();
    let ref_table_row = adw::EntryRow::builder()
        .title(crate::i18n::gettext("Table"))
        .activates_default(true)
        .build();
    ref_group.add(&ref_table_row);
    let ref_cols_row = adw::EntryRow::builder()
        .title(crate::i18n::gettext("Columns"))
        .activates_default(true)
        .build();
    ref_group.add(&ref_cols_row);
    let on_delete_row = adw::ComboRow::builder()
        .title(crate::i18n::gettext("On delete"))
        .model(&gtk::StringList::new(&action_labels))
        .build();
    ref_group.add(&on_delete_row);
    let on_update_row = adw::ComboRow::builder()
        .title(crate::i18n::gettext("On update"))
        .model(&gtk::StringList::new(&action_labels))
        .build();
    ref_group.add(&on_update_row);
    body.append(&ref_group);

    let column_checks_for_resp = column_checks.clone();
    let sender_for_resp = sender.clone();
    let dialog_for_submit = dialog.clone();
    submit_btn.connect_clicked(move |_| {
        let name = name_row.text().to_string();
        let ref_table = ref_table_row.text().to_string();
        if name.trim().is_empty() {
            sender_for_resp.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
                "Foreign key name is required.",
            )));
            return;
        }
        if ref_table.trim().is_empty() {
            sender_for_resp.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
                "Reference table is required.",
            )));
            return;
        }
        let cols: Vec<String> = column_checks_for_resp
            .borrow()
            .iter()
            .filter_map(|(n, c)| if c.is_active() { Some(n.clone()) } else { None })
            .collect();
        if cols.is_empty() {
            sender_for_resp.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
                "Select at least one source column.",
            )));
            return;
        }
        let ref_cols: Vec<String> = ref_cols_row
            .text()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if ref_cols.is_empty() {
            sender_for_resp.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
                "Reference columns are required.",
            )));
            return;
        }
        // The server would reject it too, but only at Save and in its
        // own words.
        if ref_cols.len() != cols.len() {
            sender_for_resp.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
                "Source and reference column counts must match.",
            )));
            return;
        }
        let (ref_schema, ref_table_only) = match ref_table.split_once('.') {
            Some((s, t)) => (Some(s.trim().to_string()), t.trim().to_string()),
            None => (None, ref_table),
        };
        // An explicit NO ACTION stays `Some`: `None` is reserved for an
        // action the driver reported that this build does not know.
        let action_at = |row: u32| action_for_row(fk_actions, row);
        sender_for_resp.input(StructureTabInput::AddForeignKey(ForeignKeyInfo {
            name,
            columns: cols,
            ref_schema,
            ref_table: ref_table_only,
            ref_columns: ref_cols,
            on_delete: action_at(on_delete_row.selected()),
            on_update: action_at(on_update_row.selected()),
        }));
        dialog_for_submit.close();
    });

    dialog.present(Some(parent));
}

/// The combo labels for the actions an engine accepts, in its order.
fn action_labels(actions: &[ReferentialAction]) -> Vec<&'static str> {
    actions.iter().map(|action| action.as_sql()).collect()
}

/// The action a combo row stands for. The rows are built from the
/// same list, so a row past its end can only be a stale selection.
fn action_for_row(actions: &[ReferentialAction], row: u32) -> Option<ReferentialAction> {
    actions.get(row as usize).copied()
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use super::*;

    /// GtkButton's activate runs a short press animation and emits
    /// `clicked` when it ends, so the click lands after a spin of the
    /// main loop rather than inside `emit_activate`.
    const ACTIVATE_WAIT: Duration = Duration::from_secs(5);

    /// The GtkText inside an AdwEntryRow. Enter reaches the row through
    /// this delegate, so that is where the test presses it.
    fn press_enter(row: &adw::EntryRow) {
        let text = gtk::prelude::EditableExt::delegate(row)
            .and_then(|delegate| delegate.downcast::<gtk::Text>().ok())
            .expect("an AdwEntryRow delegates to a GtkText");
        text.emit_activate();
    }

    /// An Add Index-shaped dialog on a mapped window, with a counter on
    /// its submit button. The window has to be mapped: GtkButton
    /// refuses to activate an unrealized button, so an unmapped
    /// fixture would pass both tests for the wrong reason.
    fn form_on_a_window(activates_default: bool) -> (adw::Window, adw::EntryRow, Rc<AtomicUsize>) {
        let window = adw::Window::new();
        let (dialog, body, submit) =
            build_form_dialog(&crate::i18n::gettext("Add Index"), &crate::i18n::gettext("Add"));

        let group = adw::PreferencesGroup::builder().build();
        let name_row = adw::EntryRow::builder()
            .title(crate::i18n::gettext("Name"))
            .activates_default(activates_default)
            .build();
        group.add(&name_row);
        body.append(&group);

        let clicks = Rc::new(AtomicUsize::new(0));
        let clicks_for_submit = clicks.clone();
        submit.connect_clicked(move |_| {
            clicks_for_submit.fetch_add(1, Ordering::Relaxed);
        });

        window.present();
        dialog.present(Some(&window));
        crate::test_support::wait_until(ACTIVATE_WAIT, || name_row.is_mapped()).expect("the form never appeared");
        (window, name_row, clicks)
    }

    #[gtk4::test]
    fn enter_in_a_form_row_activates_the_dialog_default() {
        let (_window, name_row, clicks) = form_on_a_window(true);
        name_row.set_text("by_created_at");

        press_enter(&name_row);

        crate::test_support::wait_until(ACTIVATE_WAIT, || clicks.load(Ordering::Relaxed) == 1)
            .expect("Enter did not reach the Add button");
    }

    #[gtk4::test]
    fn a_row_without_activates_default_does_not_submit() {
        // The dialog's default widget alone is not enough, which is why
        // every form row sets activates-default.
        let (_window, name_row, clicks) = form_on_a_window(false);
        name_row.set_text("by_created_at");

        press_enter(&name_row);

        assert!(
            crate::test_support::wait_until(Duration::from_secs(1), || clicks.load(Ordering::Relaxed) > 0).is_err(),
            "a row without activates-default submitted the form"
        );
    }

    #[test]
    fn combo_rows_decode_to_the_actions_they_are_labelled_with() {
        use tablepro_core::ddl::DdlDialect;
        let mssql = drivers_mssql::MssqlDialect::new(16).referential_actions();

        let labels = action_labels(mssql);

        assert!(!labels.contains(&"RESTRICT"), "SQL Server has no RESTRICT: {labels:?}");
        for (row, label) in labels.iter().enumerate() {
            let action = action_for_row(mssql, row as u32).expect("a row the combo shows");
            assert_eq!(action.as_sql(), *label);
        }
        assert_eq!(action_for_row(mssql, labels.len() as u32), None);
    }

    #[gtk4::test]
    fn a_form_dialog_has_a_default_widget() {
        let (dialog, _body, _submit) =
            build_form_dialog(&crate::i18n::gettext("Add Foreign Key"), &crate::i18n::gettext("Add"));

        assert!(
            dialog.default_widget().is_some(),
            "the form dialog has no default widget for Enter to reach"
        );
    }
}
