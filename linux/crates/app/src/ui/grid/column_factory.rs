use gtk4::prelude::*;
use gtk4::{self as gtk, glib};

use tablepro_core::column::ResultColumn;
use tablepro_core::{ColumnInfo, QueryResult, Value};

use super::cell_editor::CellEditor;
use super::cell_editor_kind::{CellEditorKind, classify_editor_kind, is_bool_type};
use super::context_menu::{CellMenuTarget, attach_cell_gesture};
use super::display_text::{auto_filled_sentinel, editable_null_sentinel, value_to_display_text, value_to_edit_text};
use super::grid_menus::{GridMenuInit, GridMenus, install_grid_context_menus};
use super::inline_edit::{install_edit_commit_handler, install_edit_triggers};
use super::widget_slot::{COLUMN_SLOT, POPOVER_SLOT, POSITION_SLOT, SNAPSHOT_SLOT, SUPPRESS_SLOT};
use super::{GridMsg, RowObject, TabGridContext};

const PENDING_CSS_CLASSES: &[&str] = &[
    "tp-cell-modified",
    "tp-row-pending-delete",
    "tp-row-pending-insert",
    "tp-row-leftmost-error-flash",
];

/// Shorter text fits a typical 200 px column, so its ellipsized label
/// needs no tooltip.
const TOOLTIP_MIN_CHARS: usize = 40;

const WIDE_TABLE_THRESHOLD: usize = 8;
/// About 14 characters at the default font size.
const MIN_COLUMN_WIDTH_PX: i32 = 120;

pub fn build_column_view(
    result: &QueryResult,
    schema_columns: &[ColumnInfo],
    sender: relm4::Sender<GridMsg>,
    editable: bool,
    sort: Option<(usize, bool)>,
    sort_sender: Option<relm4::Sender<GridMsg>>,
    tab_ctx: TabGridContext,
) -> (gtk::ColumnView, gtk::MultiSelection) {
    let store = gtk4::gio::ListStore::new::<RowObject>();
    for row in &result.rows {
        store.append(&RowObject::new(row.clone()));
    }
    let selection = gtk::MultiSelection::new(Some(store));
    let column_view = gtk::ColumnView::builder()
        .model(&selection)
        .show_row_separators(true)
        .show_column_separators(true)
        .build();

    let grid_menus = install_grid_context_menus(GridMenuInit {
        column_view: &column_view,
        sender: sender.clone(),
        columns: result.columns.clone(),
        truncated: result.truncated,
        tab_ctx: tab_ctx.clone(),
        editable,
    });

    // Sharing the viewport by `expand` alone leaves a wide table with 20
    // to 30 px columns that show nothing, so a column with no saved width
    // starts at a readable minimum there.
    let default_min_width = if result.columns.len() > WIDE_TABLE_THRESHOLD {
        Some(MIN_COLUMN_WIDTH_PX)
    } else {
        None
    };
    let mut columns: Vec<gtk::ColumnViewColumn> = Vec::with_capacity(result.columns.len());
    for (i, column) in result.columns.iter().enumerate() {
        // The catalogue is the authority on what can be edited: it
        // knows the keys, the generated columns and the defaults. Until
        // it has loaded, the type alone decides, which is what a
        // result column can say.
        let cell_editable = editable
            && match schema_columns.get(i) {
                Some(catalog) => is_cell_editable(catalog),
                None => !is_bytes_kind(&column.column_type.kind),
            };
        let col = build_column(
            column,
            i,
            cell_editable,
            schema_columns
                .get(i)
                .is_some_and(|catalog| catalog.is_auto_increment || catalog.is_generated),
            sender.clone(),
            sort_sender.clone(),
            tab_ctx.clone(),
            default_min_width,
            column_view.downgrade(),
            grid_menus.clone(),
        );
        column_view.append_column(&col);
        columns.push(col);
    }

    // Applied before the notify handlers are wired, so it does not echo
    // back as a SortChanged.
    if let Some((col_idx, ascending)) = sort
        && let Some(col) = columns.get(col_idx)
    {
        let direction = if ascending {
            gtk::SortType::Ascending
        } else {
            gtk::SortType::Descending
        };
        column_view.sort_by_column(Some(col), direction);
    }

    if let Some(app_sender) = sort_sender
        && let Some(view_sorter) = column_view
            .sorter()
            .and_then(|s| s.downcast::<gtk::ColumnViewSorter>().ok())
    {
        // A second click on the same column flips only
        // `primary-sort-order`, so both notifies are wired. Each sends the
        // sorter's post-click pair, which the receiver drops when it
        // already matches.
        let dispatch = {
            let app_sender = app_sender.clone();
            let columns = columns.clone();
            move |sorter: &gtk::ColumnViewSorter| {
                let Some(active) = sorter.primary_sort_column() else {
                    return;
                };
                let ascending = matches!(sorter.primary_sort_order(), gtk::SortType::Ascending);
                for (idx, col) in columns.iter().enumerate() {
                    if col == &active {
                        app_sender.send(GridMsg::SortChanged(idx, ascending)).ok();
                        break;
                    }
                }
            }
        };
        view_sorter.connect_primary_sort_column_notify({
            let dispatch = dispatch.clone();
            move |sorter| dispatch(sorter)
        });
        view_sorter.connect_primary_sort_order_notify(move |sorter| dispatch(sorter));
    }

    (column_view, selection)
}

#[expect(
    clippy::too_many_arguments,
    reason = "each argument is captured by a different column factory closure"
)]
fn build_column(
    info: &ResultColumn,
    idx: usize,
    editable: bool,
    // Whether the server fills this column in, so a draft row shows a
    // placeholder rather than an empty cell the user should type in.
    auto_filled: bool,
    sender: relm4::Sender<GridMsg>,
    sort_sender: Option<relm4::Sender<GridMsg>>,
    tab_ctx: TabGridContext,
    default_min_width: Option<i32>,
    column_view: glib::WeakRef<gtk::ColumnView>,
    grid_menus: GridMenus,
) -> gtk::ColumnViewColumn {
    let factory = gtk::SignalListItemFactory::new();

    let column_data_type = info.column_type.name.clone();
    let column_name = info.name.clone();
    let accepts_empty = info.column_type.kind.accepts_empty_string();
    let column_view_for_setup = column_view.clone();
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        if !editable {
            setup_readonly_cell(item, idx, column_name.clone(), &column_view_for_setup, &grid_menus);
            return;
        }
        if is_bool_type(&column_data_type) {
            setup_bool_cell(
                item,
                idx,
                column_name.clone(),
                sender.clone(),
                &column_view_for_setup,
                &grid_menus,
            );
        } else {
            let editor_kind = classify_editor_kind(&column_data_type);
            setup_editable_cell(
                item,
                idx,
                column_name.clone(),
                sender.clone(),
                editor_kind,
                accepts_empty,
                &column_view_for_setup,
                &grid_menus,
            );
        }
    });

    let editable_for_bind = editable;
    let column_auto_filled = auto_filled;
    let tab_ctx_for_bind = tab_ctx.clone();
    factory.connect_bind(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let Some(row) = item.item().and_downcast::<RowObject>() else {
            return;
        };
        let (value, pending_classes) = tab_ctx_for_bind.bind_state(&row, idx);
        let is_null = matches!(value, Value::Null);
        // An editable cell shows NULL as `<NULL>`, so it reads differently
        // from an empty string; a read-only one dims a plain NULL.
        let text = if is_null && column_auto_filled {
            auto_filled_sentinel()
        } else if editable_for_bind {
            if is_null {
                editable_null_sentinel()
            } else {
                value_to_edit_text(&value)
            }
        } else {
            value_to_display_text(&value)
        };

        let is_pending_delete = pending_classes.contains(&"tp-row-pending-delete");
        let Some(child) = item.child() else { return };
        if let Ok(label) = child.clone().downcast::<CellEditor>() {
            label.set_text(&text);
            apply_cell_tooltip(label.upcast_ref(), &text, is_null);
            if is_null && !editable_for_bind {
                label.add_css_class("dim-label");
            } else {
                label.remove_css_class("dim-label");
            }
            if is_null && (editable_for_bind || column_auto_filled) {
                label.add_css_class("tp-null-sentinel");
            } else {
                label.remove_css_class("tp-null-sentinel");
            }
            clear_pending_classes(label.upcast_ref());
            for cls in &pending_classes {
                label.add_css_class(cls);
            }
            label.set_strikethrough(is_pending_delete);
            POSITION_SLOT.set(&label, item.position());
        } else if let Ok(checkbox) = child.clone().downcast::<gtk::CheckButton>() {
            // Suppressed, so drawing the value does not echo back as an edit.
            SUPPRESS_SLOT.set(&checkbox, true);
            match value {
                Value::Bool(true) => {
                    checkbox.set_inconsistent(false);
                    checkbox.set_active(true);
                }
                Value::Bool(false) => {
                    checkbox.set_inconsistent(false);
                    checkbox.set_active(false);
                }
                Value::Null => {
                    checkbox.set_inconsistent(true);
                    checkbox.set_active(false);
                }
                _ => {
                    // A value that is not a bool shows as inconsistent
                    // rather than as a confidently wrong check box.
                    checkbox.set_inconsistent(true);
                    checkbox.set_active(false);
                }
            }
            SUPPRESS_SLOT.set(&checkbox, false);
            clear_pending_classes(checkbox.upcast_ref());
            for cls in &pending_classes {
                checkbox.add_css_class(cls);
            }
            // A check box has no strikethrough, so a pending delete dims it.
            checkbox.set_opacity(if is_pending_delete { 0.5 } else { 1.0 });
            POSITION_SLOT.set(&checkbox, item.position());
        } else if let Ok(label) = child.downcast::<gtk::Label>() {
            label.set_text(&text);
            apply_cell_tooltip(label.upcast_ref(), &text, is_null);
            if is_null {
                label.add_css_class("dim-label");
            } else {
                label.remove_css_class("dim-label");
            }
            clear_pending_classes(label.upcast_ref());
            for cls in &pending_classes {
                label.add_css_class(cls);
            }
            set_label_strikethrough(&label, is_pending_delete);
            POSITION_SLOT.set(&label, item.position());
        }
    });

    factory.connect_unbind(|_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let Some(child) = item.child() else { return };
        if let Ok(label) = child.clone().downcast::<CellEditor>() {
            if label.is_editing() {
                label.stop_editing(false);
            }
            // An open popover unparents before the cell is recycled, or
            // GTK finalizes the cell with a GtkPopover child left in it.
            if let Some(popover) = POPOVER_SLOT.take(&label) {
                popover.popdown();
            }
            POSITION_SLOT.take(&label);
            SNAPSHOT_SLOT.take(&label);
        } else if let Ok(checkbox) = child.clone().downcast::<gtk::CheckButton>() {
            POSITION_SLOT.take(&checkbox);
        } else if let Ok(label) = child.downcast::<gtk::Label>() {
            POSITION_SLOT.take(&label);
        }
    });

    let column = gtk::ColumnViewColumn::builder()
        .title(&info.name)
        .factory(&factory)
        .resizable(true)
        .expand(true)
        .build();
    if sort_sender.is_some() {
        let dummy = gtk::CustomSorter::new(|_, _| gtk::Ordering::Equal);
        column.set_sorter(Some(&dummy));
    }
    if let Some(widths) = tab_ctx.column_widths.clone() {
        if let Some(saved) = widths.width(&info.name) {
            column.set_fixed_width(saved);
        } else if let Some(min) = default_min_width {
            column.set_fixed_width(min);
        }
        let column_name = info.name.clone();
        column.connect_fixed_width_notify(move |column| {
            widths.record(&column_name, column.fixed_width());
        });
    } else if let Some(min) = default_min_width {
        // Editor results remember no widths, but can be just as wide.
        column.set_fixed_width(min);
    }
    column
}

#[expect(
    clippy::too_many_arguments,
    reason = "each argument is captured by a different cell signal handler"
)]
fn setup_editable_cell(
    item: &gtk::ListItem,
    idx: usize,
    column_name: String,
    sender: relm4::Sender<GridMsg>,
    editor_kind: CellEditorKind,
    accepts_empty: bool,
    column_view: &glib::WeakRef<gtk::ColumnView>,
    menus: &GridMenus,
) {
    let label = CellEditor::new();
    label.set_hexpand(true);
    label.set_margin_start(8);
    label.set_margin_end(8);
    // Ctrl+Shift+N reads the focused cell's column from here. Its row
    // changes as rows are recycled, so the bind writes POSITION_SLOT.
    COLUMN_SLOT.set(&label, idx);
    item.set_child(Some(&label));

    attach_cell_gesture(
        label.upcast_ref(),
        column_view,
        CellMenuTarget {
            col_index: idx,
            column_name,
            editable: true,
            text_editable: true,
            accepts_empty,
        },
        menus,
    );
    install_edit_commit_handler(&label, idx, sender.clone());
    install_edit_triggers(&label, idx, sender, editor_kind);
}

fn setup_bool_cell(
    item: &gtk::ListItem,
    idx: usize,
    column_name: String,
    sender: relm4::Sender<GridMsg>,
    column_view: &glib::WeakRef<gtk::ColumnView>,
    menus: &GridMenus,
) {
    let checkbox = gtk::CheckButton::builder()
        .halign(gtk::Align::Start)
        .valign(gtk::Align::Center)
        .margin_start(8)
        .margin_end(8)
        .build();
    COLUMN_SLOT.set(&checkbox, idx);
    item.set_child(Some(&checkbox));

    attach_cell_gesture(
        checkbox.upcast_ref(),
        column_view,
        CellMenuTarget {
            col_index: idx,
            column_name,
            editable: true,
            text_editable: false,
            accepts_empty: false,
        },
        menus,
    );
    checkbox.connect_toggled(move |cb| {
        if SUPPRESS_SLOT.get(cb).unwrap_or(false) {
            return;
        }
        let position = POSITION_SLOT.get(cb).unwrap_or(0);
        let new_value = if cb.is_active() { "true" } else { "false" };
        sender
            .send(GridMsg::CellEdited {
                row_position: position,
                col_index: idx,
                new_value: new_value.to_string(),
            })
            .ok();
    });
}

fn setup_readonly_cell(
    item: &gtk::ListItem,
    idx: usize,
    column_name: String,
    column_view: &glib::WeakRef<gtk::ColumnView>,
    menus: &GridMenus,
) {
    let label = gtk::Label::builder()
        .xalign(0.0)
        .hexpand(true)
        .selectable(true)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .margin_start(8)
        .margin_end(8)
        .build();
    item.set_child(Some(&label));
    attach_cell_gesture(
        label.upcast_ref(),
        column_view,
        CellMenuTarget {
            col_index: idx,
            column_name,
            editable: false,
            text_editable: false,
            accepts_empty: false,
        },
        menus,
    );
}

fn clear_pending_classes(widget: &gtk::Widget) {
    for cls in PENDING_CSS_CLASSES {
        widget.remove_css_class(cls);
    }
}

fn apply_cell_tooltip(widget: &gtk::Widget, text: &str, is_null: bool) {
    if is_null || text.chars().take(TOOLTIP_MIN_CHARS + 1).count() <= TOOLTIP_MIN_CHARS {
        widget.set_tooltip_text(None);
    } else {
        widget.set_tooltip_text(Some(text));
    }
}

/// A Pango attribute, because CSS `text-decoration` does not cascade
/// reliably into a cell's label.
fn set_label_strikethrough(label: &gtk::Label, on: bool) {
    if on {
        let attrs = gtk::pango::AttrList::new();
        attrs.insert(gtk::pango::AttrInt::new_strikethrough(true));
        label.set_attributes(Some(&attrs));
    } else {
        label.set_attributes(None);
    }
}

fn is_cell_editable(col: &ColumnInfo) -> bool {
    // A primary key is the row's identity in the tracker, and the server
    // rejects a value for a generated or auto-increment column.
    !col.primary_key && !col.is_generated && !col.is_auto_increment && !is_bytes_kind(&col.column_type.kind)
}

/// A blob has no text form to type into, so the grid never offers one.
fn is_bytes_kind(kind: &tablepro_core::column::ColumnKind) -> bool {
    matches!(kind, tablepro_core::column::ColumnKind::Bytes { .. })
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use gtk4::{self as gtk, gio, glib};

    use tablepro_core::{ColumnInfo, QueryResult, Value};

    use super::{build_column_view, is_cell_editable};
    use crate::services::change_tracker::RowKey;
    use crate::services::tab_tracker_handle::TabTrackerHandle;
    use crate::ui::grid::{CellEditor, ColumnWidthBinding, GridMsg, RowObject, TabGridContext};

    #[expect(
        clippy::disallowed_methods,
        reason = "a test fixture stands in for the catalogue, which is where this text comes from in production"
    )]
    fn col(data_type: &str, primary_key: bool) -> ColumnInfo {
        let kind = tablepro_core::column::classify_type_name(data_type);
        ColumnInfo {
            name: "x".into(),
            column_type: tablepro_core::column::ColumnType {
                name: data_type.to_owned(),
                dynamic_storage: tablepro_core::column::has_dynamic_storage(&kind),
                kind,
                catalog: Some(tablepro_core::column::CatalogType {
                    declaration: tablepro_core::column::SqlTypeExpr::from_catalog_text(data_type),
                    cast_target: tablepro_core::column::SqlTypeExpr::from_catalog_text(data_type),
                }),
                read_form: tablepro_core::column::ReadForm::Native,
            },
            nullable: true,
            primary_key,
            is_auto_increment: false,
            is_generated: false,
            default: tablepro_core::column::ColumnDefault::None,
            comment: None,
        }
    }

    fn cell_texts(root: &impl IsA<gtk::Widget>) -> Vec<String> {
        crate::test_support::descendants(root)
            .into_iter()
            .filter_map(|widget| widget.downcast::<CellEditor>().ok())
            .map(|cell| cell.text().to_string())
            .collect()
    }

    #[gtk4::test]
    fn edit_during_rebind_shows_pending_value() {
        use crate::services::tracker_edit::TrackerEdit;

        let mut id = col("integer", true);
        id.name = "id".into();
        let mut name = col("text", false);
        name.name = "name".into();
        let columns = vec![id, name];
        let result = QueryResult::new(
            columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
            vec![vec![Value::Int(1), Value::Text("old".into())]],
        );
        let tracker = TabTrackerHandle::default();
        let (sender, _receiver) = relm4::channel::<GridMsg>();
        let context = TabGridContext {
            tracker: Some(tracker.clone()),
            pk_col_indices: vec![0],
            column_widths: None,
        };
        let (view, selection) = build_column_view(&result, &columns, sender, true, None, None, context);
        let window = gtk::Window::new();
        window.set_child(Some(&view));
        window.present();
        crate::test_support::wait_until(std::time::Duration::from_secs(5), || {
            cell_texts(&view).iter().any(|text| text == "old")
        })
        .expect("the fetched value is drawn");

        let delta = tracker.apply(TrackerEdit::Cell {
            row_key: RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"),
            col: 1,
            original: Value::Text("old".into()),
            value: Value::Text("new".into()),
        });
        // A fresh row object, because the list item manager skips the
        // rebind for an items-changed that keeps the same item.
        let store = selection
            .model()
            .and_downcast::<gio::ListStore>()
            .expect("a list store");
        let row = store.item(0).and_downcast::<RowObject>().expect("a row");
        store.splice(0, 1, &[RowObject::new(row.cells_clone())]);

        crate::test_support::wait_until(std::time::Duration::from_secs(5), || {
            cell_texts(&view).iter().any(|text| text == "new")
        })
        .expect("the rebind draws the pending value");
        assert_eq!(delta.pending_count, 1);
        window.close();
        crate::test_support::drain_main_context();
    }

    fn width_binding(tasks: &tablepro_session::runtime::Tasks, root: &tempfile::TempDir) -> ColumnWidthBinding {
        ColumnWidthBinding {
            store: crate::persistence::ColumnWidthStore::load(root.path().join("column-widths.json"), tasks),
            connection_id: uuid::Uuid::new_v4(),
            schema: None,
            table: "t".to_owned(),
        }
    }

    #[gtk4::test]
    fn column_freed_with_column_view() {
        let runtime = crate::test_support::test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let mut name = col("text", false);
        name.name = "name".into();
        let columns = vec![name];
        let result = QueryResult::new(
            columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
            vec![vec![Value::Text("a".into())]],
        );
        let (sender, _receiver) = relm4::channel::<GridMsg>();
        let context = TabGridContext {
            tracker: None,
            pk_col_indices: Vec::new(),
            column_widths: Some(width_binding(&runtime.tasks(), &root)),
        };
        let (view, selection) = build_column_view(
            &result,
            &columns,
            sender.clone(),
            true,
            Some((0, true)),
            Some(sender),
            context,
        );
        let column = view
            .columns()
            .item(0)
            .and_downcast::<gtk::ColumnViewColumn>()
            .expect("a column")
            .downgrade();
        let view_ref = view.downgrade();

        drop((view, selection));
        crate::test_support::drain_main_context();

        assert!(column.upgrade().is_none(), "the column outlived its column view");
        assert!(view_ref.upgrade().is_none(), "the column view outlived its owner");
    }

    fn menu_gesture(cell: &gtk::Widget) -> Option<gtk::GestureClick> {
        let controllers = cell.observe_controllers();
        (0..controllers.n_items())
            .filter_map(|index| controllers.item(index).and_downcast::<gtk::GestureClick>())
            .find(|gesture| gesture.button() == 3)
    }

    #[gtk4::test]
    fn cells_freed_with_column_view() {
        let mut id = col("integer", true);
        id.name = "id".into();
        let mut name = col("text", false);
        name.name = "name".into();
        let mut flag = col("boolean", false);
        flag.name = "flag".into();
        let columns = vec![id, name, flag];
        let result = QueryResult::new(
            columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
            vec![vec![Value::Int(7), Value::Text("a".into()), Value::Bool(true)]],
        );
        let (sender, _receiver) = relm4::channel::<GridMsg>();
        let context = TabGridContext {
            tracker: Some(TabTrackerHandle::default()),
            pk_col_indices: vec![0],
            column_widths: None,
        };
        let (view, selection) = build_column_view(&result, &columns, sender, true, None, None, context);
        let window = gtk::Window::new();
        window.set_child(Some(&view));
        window.present();
        let cells = || -> Vec<gtk::Widget> {
            crate::test_support::descendants(&view)
                .into_iter()
                .filter(|widget| {
                    widget.is::<CellEditor>()
                        || widget.is::<gtk::CheckButton>()
                        || widget
                            .downcast_ref::<gtk::Label>()
                            .is_some_and(|label| label.text() == "7")
                })
                .collect()
        };
        crate::test_support::wait_until(std::time::Duration::from_secs(5), || cells().len() == 3)
            .expect("the read-only, text and bool cells are drawn");
        // A right-click is what fills the menu's target, so it has to be
        // in the picture too.
        for cell in cells() {
            let gesture = menu_gesture(&cell).expect("a cell answers a right-click");
            gesture.emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
        }
        let freed: Vec<glib::WeakRef<gtk::Widget>> = cells().iter().map(ObjectExt::downgrade).collect();

        window.destroy();
        drop(window);
        drop((view, selection));
        crate::test_support::drain_main_context();

        let alive = freed.iter().filter(|cell| cell.upgrade().is_some()).count();
        assert_eq!(alive, 0, "cells outlived their column view");
    }

    #[test]
    fn editable_for_normal_column() {
        assert!(is_cell_editable(&col("text", false)));
        assert!(is_cell_editable(&col("integer", false)));
    }

    #[test]
    fn not_editable_for_primary_key() {
        assert!(!is_cell_editable(&col("integer", true)));
    }

    #[test]
    fn not_editable_for_generated_column() {
        let mut c = col("integer", false);
        c.is_generated = true;
        assert!(!is_cell_editable(&c));
    }

    #[test]
    fn not_editable_for_auto_increment_non_pk() {
        let mut c = col("integer", false);
        c.is_auto_increment = true;
        assert!(!is_cell_editable(&c));
    }

    #[test]
    fn not_editable_for_bytes() {
        assert!(!is_cell_editable(&col("bytea", false)));
        assert!(!is_cell_editable(&col("blob", false)));
        assert!(!is_cell_editable(&col("longblob", false)));
        assert!(!is_cell_editable(&col("BINARY", false)));
        assert!(!is_cell_editable(&col("varbinary", false)));
    }

    #[test]
    fn only_columns_with_an_empty_value_accept_an_empty_string() {
        // Clearing a text cell stores the empty string; clearing a
        // number or a date can only mean NULL.
        for text in ["text", "VARCHAR(255)", "char(3)", "longtext"] {
            assert!(
                col(text, false).column_type.kind.accepts_empty_string(),
                "{text} should accept an empty string"
            );
        }
        for other in [
            "integer",
            "bigint",
            "numeric(10,2)",
            "date",
            "timestamp",
            "uuid",
            "boolean",
        ] {
            assert!(
                !col(other, false).column_type.kind.accepts_empty_string(),
                "{other} should not accept an empty string"
            );
        }
    }

    #[test]
    fn a_blob_is_never_editable_whatever_the_engine_calls_it() {
        for name in [
            "BYTEA",
            "blob",
            "LONGBLOB",
            "mediumblob",
            "tinyblob",
            "VARBINARY",
            "binary",
        ] {
            assert!(
                !is_cell_editable(&col(name, false)),
                "{name} was offered as an editable cell"
            );
        }
        assert!(is_cell_editable(&col("text", false)));
        assert!(is_cell_editable(&col("integer", false)));
    }
}
