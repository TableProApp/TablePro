//! Add-Index and Add-Foreign-Key form dialogs for the Structure tab.
//!
//! Split out of `structure_tab.rs` so that file can stay focused on
//! the SimpleComponent itself. Both dialogs follow the same skeleton
//! (`build_form_dialog`): an `adw::Dialog` carrying a custom HeaderBar
//! with Cancel + suggested-action buttons and a vertically-scrolling
//! content box. Per HIG, AlertDialog is for confirmation prompts; data
//! entry forms belong on AdwDialog with explicit headerbar buttons.

use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw, gtk};

use tablepro_core::sql_ddl::DraftColumn;
use tablepro_core::{ForeignKeyInfo, IndexInfo};

use super::structure_tab::{StructureTab, StructureTabInput, StructureTabOutput};

/// Foreign-key referential action choices, in the same order they
/// appear in the `gtk::DropDown`s. The index returned by
/// `DropDown::selected()` is mapped back to a string via this slice.
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
        .spacing(12)
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

    let dialog_for_cancel = dialog.clone();
    cancel_btn.connect_clicked(move |_| {
        dialog_for_cancel.close();
    });

    (dialog, content, submit_btn)
}

/// Build a boxed-list `ListBox` of `AdwActionRow` + `CheckButton` —
/// one per draft column — for picking columns inside a form dialog.
/// Returns the list (so the caller can `body.append` it) plus the
/// shared `Rc` of name/check pairs so the submit handler can extract
/// which columns the user ticked.
fn build_column_checklist(columns: &[DraftColumn]) -> (gtk::ListBox, ColumnChecks) {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
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

    let name_entry = gtk::Entry::builder().placeholder_text(crate::tr!("index_name")).build();
    body.append(&gtk::Label::builder().label(crate::tr!("Name")).xalign(0.0).build());
    body.append(&name_entry);

    body.append(
        &gtk::Label::builder()
            .label(crate::tr!("Columns"))
            .xalign(0.0)
            .margin_top(6)
            .build(),
    );
    let (columns_list, column_checks) = build_column_checklist(columns);
    body.append(&columns_list);

    let unique_check = gtk::CheckButton::builder().label(crate::tr!("Unique")).build();
    unique_check.set_margin_top(6);
    body.append(&unique_check);

    let column_checks_for_resp = column_checks.clone();
    let sender_for_resp = sender.clone();
    let dialog_for_submit = dialog.clone();
    submit_btn.connect_clicked(move |_| {
        let name = name_entry.text().to_string();
        if name.trim().is_empty() {
            return;
        }
        let cols: Vec<String> = column_checks_for_resp
            .borrow()
            .iter()
            .filter_map(|(n, c)| if c.is_active() { Some(n.clone()) } else { None })
            .collect();
        if cols.is_empty() {
            let _ = sender_for_resp.output(StructureTabOutput::ShowToast(crate::tr!(
                "Select at least one column."
            )));
            return;
        }
        sender_for_resp.input(StructureTabInput::AddIndex(IndexInfo {
            name,
            columns: cols,
            unique: unique_check.is_active(),
            primary: false,
        }));
        dialog_for_submit.close();
    });

    dialog.present(Some(parent));
}

pub(super) fn present_fk_dialog(
    parent: &gtk::Widget,
    columns: &[DraftColumn],
    sender: ComponentSender<StructureTab>,
) {
    let (dialog, body, submit_btn) = build_form_dialog(&crate::tr!("Add Foreign Key"), &crate::tr!("Add"));

    let name_entry = gtk::Entry::builder().placeholder_text(crate::tr!("fk_name")).build();
    body.append(&gtk::Label::builder().label(crate::tr!("Name")).xalign(0.0).build());
    body.append(&name_entry);

    body.append(
        &gtk::Label::builder()
            .label(crate::tr!("Columns"))
            .xalign(0.0)
            .margin_top(6)
            .build(),
    );
    let (columns_list, column_checks) = build_column_checklist(columns);
    body.append(&columns_list);

    body.append(
        &gtk::Label::builder()
            .label(crate::tr!("References (table)"))
            .xalign(0.0)
            .margin_top(6)
            .build(),
    );
    let ref_table_entry = gtk::Entry::builder()
        .placeholder_text(crate::tr!("schema.referenced_table"))
        .build();
    body.append(&ref_table_entry);

    body.append(
        &gtk::Label::builder()
            .label(crate::tr!("Reference columns"))
            .xalign(0.0)
            .margin_top(6)
            .build(),
    );
    let ref_cols_entry = gtk::Entry::builder().placeholder_text(crate::tr!("col1, col2")).build();
    body.append(&ref_cols_entry);

    let actions = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .margin_top(6)
        .build();
    let on_delete = gtk::DropDown::from_strings(FK_ACTIONS);
    let on_update = gtk::DropDown::from_strings(FK_ACTIONS);
    actions.append(
        &gtk::Label::builder()
            .label(crate::tr!("ON DELETE"))
            .valign(gtk::Align::Center)
            .build(),
    );
    actions.append(&on_delete);
    actions.append(
        &gtk::Label::builder()
            .label(crate::tr!("ON UPDATE"))
            .valign(gtk::Align::Center)
            .margin_start(12)
            .build(),
    );
    actions.append(&on_update);
    body.append(&actions);

    let column_checks_for_resp = column_checks.clone();
    let sender_for_resp = sender.clone();
    let dialog_for_submit = dialog.clone();
    submit_btn.connect_clicked(move |_| {
        let name = name_entry.text().to_string();
        let ref_table = ref_table_entry.text().to_string();
        if name.trim().is_empty() || ref_table.trim().is_empty() {
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
        let ref_cols: Vec<String> = ref_cols_entry
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
            on_delete: action_at(on_delete.selected()),
            on_update: action_at(on_update.selected()),
        }));
        dialog_for_submit.close();
    });

    dialog.present(Some(parent));
}
