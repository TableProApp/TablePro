//! Add-Index and Add-Foreign-Key form dialogs for the Structure tab.
//!
//! Split out of `structure_tab.rs` so that file can stay focused on
//! the SimpleComponent itself. Both dialogs follow the same skeleton
//! (`build_form_dialog`): an `adw::Dialog` carrying a custom HeaderBar
//! with Cancel + suggested-action buttons and a vertically-scrolling
//! content box. Per HIG, AlertDialog is for confirmation prompts; data
//! entry forms belong on AdwDialog with explicit headerbar buttons.
//!
//! Form fields use AdwEntryRow / AdwSwitchRow / AdwComboRow inside an
//! AdwPreferencesGroup — the same pattern GNOME Settings uses for
//! every "Add account / Add network / Add printer" dialog. Raw
//! GtkEntry + sibling labels was the quick-MVP layout but it doesn't
//! pick up the rounded-corner / row-separator styling and breaks
//! typing flow (the title float of AdwEntryRow doubles as the
//! placeholder, halving vertical space).

use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw, gtk};

use tablepro_core::sql_ddl::DraftColumn;
use tablepro_core::{ForeignKeyInfo, IndexInfo};

use super::structure_tab::{StructureTab, StructureTabInput, StructureTabOutput};

/// Foreign-key referential action choices, in the same order they
/// appear in the `AdwComboRow`s. The index returned by
/// `selected()` is mapped back to a string via this slice.
const FK_ACTIONS: &[&str] = &["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"];

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
/// `submit_btn` is set as the dialog's default widget so Enter-key
/// activation in any AdwEntryRow inside `content` submits the form
/// (matches GNOME Settings's Add-account-style dialogs).
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
    let cancel_btn = gtk::Button::with_label(&crate::tr!("Cancel"));
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
    // Enter inside any AdwEntryRow descendant fires the default widget.
    // Without this the Add button only responds to mouse / Tab+Space.
    dialog.set_default_widget(Some(&submit_btn));

    let dialog_for_cancel = dialog.clone();
    cancel_btn.connect_clicked(move |_| {
        dialog_for_cancel.close();
    });

    (dialog, content, submit_btn)
}

/// Build a section header label sized as a small caption — used
/// above sub-groupings inside form dialogs. AdwPreferencesGroup
/// already handles its own header, so this is for the "Columns"
/// label that sits above the column checklist (which is itself a
/// boxed-list, not a PreferencesGroup).
fn section_label(title: &str) -> gtk::Label {
    let label = gtk::Label::builder().label(title).xalign(0.0).build();
    label.add_css_class("heading");
    label
}

/// Build a boxed-list `ListBox` of `AdwActionRow` + `CheckButton` —
/// one per draft column — for picking columns inside a form dialog.
/// Returns the list (so the caller can `body.append` it) plus the
/// shared `Rc` of name/check pairs so the submit handler can extract
/// which columns the user ticked.
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

pub(super) fn present_index_dialog(
    parent: &gtk::Widget,
    columns: &[DraftColumn],
    sender: ComponentSender<StructureTab>,
) {
    let (dialog, body, submit_btn) = build_form_dialog(&crate::tr!("Add Index"), &crate::tr!("Add"));

    // Name + Unique inside one AdwPreferencesGroup. AdwEntryRow's
    // title slot doubles as the placeholder when empty (floats up
    // when filled), so no separate "Name" label is needed.
    let detail_group = adw::PreferencesGroup::builder().build();
    let name_row = adw::EntryRow::builder().title(crate::tr!("Name")).build();
    detail_group.add(&name_row);
    let unique_row = adw::SwitchRow::builder()
        .title(crate::tr!("Unique"))
        .subtitle(crate::tr!("Reject inserts that duplicate the indexed columns"))
        .build();
    detail_group.add(&unique_row);
    body.append(&detail_group);

    body.append(&section_label(&crate::tr!("Columns")));
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
            let _ = sender_for_resp.output(StructureTabOutput::ShowToast(crate::tr!("Index name is required.")));
            return;
        }
        let cols: Vec<String> = column_checks_for_resp
            .borrow()
            .iter()
            .filter_map(|(n, c)| if c.is_active() { Some(n.clone()) } else { None })
            .collect();
        if cols.is_empty() {
            let _ = sender_for_resp.output(StructureTabOutput::ShowToast(crate::tr!("Select at least one column.")));
            return;
        }
        sender_for_resp.input(StructureTabInput::AddIndex(IndexInfo {
            name,
            columns: cols,
            unique: unique_row.is_active(),
            primary: false,
        }));
        dialog_for_submit.close();
    });

    dialog.present(Some(parent));
}

pub(super) fn present_fk_dialog(parent: &gtk::Widget, columns: &[DraftColumn], sender: ComponentSender<StructureTab>) {
    let (dialog, body, submit_btn) = build_form_dialog(&crate::tr!("Add Foreign Key"), &crate::tr!("Add"));

    // Name in its own AdwPreferencesGroup at the top — matches the
    // shape of the column-edit drawer + every other GNOME form.
    let name_group = adw::PreferencesGroup::builder().build();
    let name_row = adw::EntryRow::builder().title(crate::tr!("Name")).build();
    name_group.add(&name_row);
    body.append(&name_group);

    body.append(&section_label(&crate::tr!("Source columns")));
    let (columns_list, column_checks) = build_column_checklist(columns);
    body.append(&columns_list);

    // Reference target + ON DELETE / ON UPDATE in a second group.
    // Reference columns stay free-text — wiring up an async fetch of
    // the referenced table's columns is out of scope for an MVP.
    let ref_group = adw::PreferencesGroup::builder().title(crate::tr!("References")).build();
    let ref_table_row = adw::EntryRow::builder().title(crate::tr!("Table")).build();
    ref_group.add(&ref_table_row);
    let ref_cols_row = adw::EntryRow::builder().title(crate::tr!("Columns")).build();
    ref_group.add(&ref_cols_row);
    let on_delete_row = adw::ComboRow::builder()
        .title(crate::tr!("On delete"))
        .model(&gtk::StringList::new(FK_ACTIONS))
        .build();
    ref_group.add(&on_delete_row);
    let on_update_row = adw::ComboRow::builder()
        .title(crate::tr!("On update"))
        .model(&gtk::StringList::new(FK_ACTIONS))
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
            let _ = sender_for_resp.output(StructureTabOutput::ShowToast(crate::tr!(
                "Foreign key name is required."
            )));
            return;
        }
        if ref_table.trim().is_empty() {
            let _ = sender_for_resp.output(StructureTabOutput::ShowToast(crate::tr!(
                "Reference table is required."
            )));
            return;
        }
        let cols: Vec<String> = column_checks_for_resp
            .borrow()
            .iter()
            .filter_map(|(n, c)| if c.is_active() { Some(n.clone()) } else { None })
            .collect();
        if cols.is_empty() {
            let _ = sender_for_resp.output(StructureTabOutput::ShowToast(crate::tr!(
                "Select at least one source column."
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
            let _ = sender_for_resp.output(StructureTabOutput::ShowToast(crate::tr!(
                "Reference columns are required."
            )));
            return;
        }
        // Source and reference column counts must match — `(a, b) → (x)`
        // is structurally invalid SQL. Drivers reject it, but with an
        // opaque error after Save instead of an inline guard.
        if ref_cols.len() != cols.len() {
            let _ = sender_for_resp.output(StructureTabOutput::ShowToast(crate::tr!(
                "Source and reference column counts must match."
            )));
            return;
        }
        let (ref_schema, ref_table_only) = match ref_table.split_once('.') {
            Some((s, t)) => (Some(s.trim().to_string()), t.trim().to_string()),
            None => (None, ref_table),
        };
        // Preserve the user's explicit "NO ACTION" choice as
        // `Some("NO ACTION")`. Reserve `None` for the
        // driver-returned-unknown case so the SQL emitter can choose
        // sensibly per dialect (MySQL implicit RESTRICT vs Postgres
        // implicit NO ACTION).
        let action_at = |idx: u32| -> Option<String> { FK_ACTIONS.get(idx as usize).map(|s| (*s).to_string()) };
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
