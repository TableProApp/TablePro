use std::cell::RefCell;
use std::rc::Rc;

use chrono::Datelike;
use gtk4::prelude::*;
use gtk4::{self as gtk, gio, glib};
use sourceview5::prelude::*;

use tablepro_core::{ColumnInfo, QueryResult, Value};

use super::row_object::RowObject;

pub type FilterSetter = Rc<dyn Fn(&str)>;

#[derive(Debug)]
pub enum GridMsg {
    /// User clicked a column header. `(col_idx, ascending)` is the
    /// resolved post-click state read from the GtkColumnViewSorter
    /// — not a "toggle" hint. Reading the sorter directly avoids
    /// the receiver having to keep its own toggle state in sync,
    /// which broke when both `primary-sort-column` and
    /// `primary-sort-order` notify fired for the same logical
    /// click (column change resets order; two events, two flips).
    SortChanged(usize, bool),
    CellEdited {
        row_position: u32,
        col_index: usize,
        new_value: String,
    },
    CopyToClipboard(String),
    CopyRowAsInsert {
        row_position: u32,
    },
    SetCellNull {
        row_position: u32,
        col_index: usize,
    },
    DeleteRowAt {
        row_position: u32,
    },
    /// Context-menu "Insert row" — forwarded by browse_tab as
    /// `BrowseTabInput::InsertRow`. Same effect as the toolbar Insert
    /// button or Ctrl+N.
    InsertRow,
    /// "Duplicate row" — create a fresh draft row whose cell values
    /// are pre-populated from the source row. The browse tab's
    /// handler reads the source row from the result snapshot and
    /// pushes a draft via the change tracker; user can edit before
    /// Save. PK / generated / auto-increment columns are blanked so
    /// the duplicate doesn't inherit the source's identity.
    DuplicateRow {
        row_position: u32,
    },
}

/// Per-tab context plumbed into the grid factory so cell bind-time
/// callbacks can query the change tracker for pending-state CSS
/// classes. `tab_id == None` means the grid is read-only / not
/// associated with a tracked Browse tab (e.g., editor results).
#[derive(Debug, Clone, Default)]
pub struct TabGridContext {
    pub tab_id: Option<uuid::Uuid>,
    pub pk_col_indices: Vec<usize>,
}

#[allow(clippy::too_many_arguments)]
pub fn build_column_view(
    result: &QueryResult,
    schema_columns: &[ColumnInfo],
    table: &str,
    edit_sender: Option<relm4::Sender<GridMsg>>,
    sort: Option<(usize, bool)>,
    sort_sender: Option<relm4::Sender<GridMsg>>,
    connection_id: Option<uuid::Uuid>,
    tab_ctx: TabGridContext,
) -> (gtk::ColumnView, gtk::MultiSelection, FilterSetter) {
    let store = gtk4::gio::ListStore::new::<RowObject>();
    for row in &result.rows {
        store.append(&RowObject::new(row.clone()));
    }
    let filter_text: Rc<RefCell<String>> = Rc::new(RefCell::new(String::new()));
    let filter_text_for_filter = filter_text.clone();
    let filter = gtk::CustomFilter::new(move |item| {
        let query = filter_text_for_filter.borrow();
        if query.is_empty() {
            return true;
        }
        let Some(row) = item.downcast_ref::<RowObject>() else {
            return true;
        };
        // Always show draft rows regardless of search text — their
        // initial NULL values would otherwise hide them from view
        // the moment the user types anything in the find bar.
        if row.draft_id().is_some() {
            return true;
        }
        let needle = query.to_lowercase();
        row.with_cells(|cells| {
            cells
                .iter()
                .any(|v| value_to_display_text(v).to_lowercase().contains(&needle))
        })
    });
    let filter_model = gtk::FilterListModel::new(Some(store), Some(filter.clone()));
    let selection = gtk::MultiSelection::new(Some(filter_model));

    let filter_for_setter = filter.clone();
    let setter: FilterSetter = Rc::new(move |q: &str| {
        filter_text.replace(q.to_string());
        filter_for_setter.changed(gtk::FilterChange::Different);
    });
    let column_view = gtk::ColumnView::builder()
        .model(&selection)
        .show_row_separators(true)
        .show_column_separators(true)
        .build();

    // For wide tables (~9+ columns) the default `expand: true` per
    // column shares the viewport fractionally and produces 20-30px
    // cells that can't show even short values. When a column has no
    // persisted width we fall back to a minimum starting width so the
    // grid is usable on first render; the user can still resize from
    // there and the new width persists. Narrow tables (≤8 columns)
    // keep the expand-to-fill behaviour because there's enough room
    // for every column to render readably.
    let default_min_width = if result.columns.len() > WIDE_TABLE_THRESHOLD {
        Some(MIN_COLUMN_WIDTH_PX)
    } else {
        None
    };
    let mut columns: Vec<gtk::ColumnViewColumn> = Vec::with_capacity(result.columns.len());
    for (i, column) in result.columns.iter().enumerate() {
        // `schema_columns` is preferred when populated (it carries
        // accurate primary_key / is_generated / is_auto_increment from
        // the driver's information_schema fetch). When ColumnsLoaded
        // hasn't fired yet we fall back to the QueryResult's column
        // metadata, which only knows name + data_type and conservatively
        // reports the rest as false.
        let editable = is_cell_editable(schema_columns.get(i).unwrap_or(column));
        let col = build_column(
            column,
            i,
            editable,
            table.to_string(),
            edit_sender.clone(),
            sort_sender.clone(),
            connection_id,
            tab_ctx.clone(),
            default_min_width,
        );
        column_view.append_column(&col);
        columns.push(col);
    }

    // Apply the inbound sort state BEFORE wiring the signal so the resulting
    // primary-sort change doesn't echo back as a SortChanged dispatch.
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
        // Wire BOTH `primary-sort-column` AND `primary-sort-order`
        // notify. Listening only to the former misses the case
        // where the user clicks the same column a second time:
        // GTK keeps `primary-sort-column` constant and just flips
        // `primary-sort-order` (Ascending ↔ Descending). The
        // chevron updates because GTK manages it internally, but
        // without an order-notify listener the model never sees
        // SortChanged, `current_sort` stays stale, and the next
        // FetchPage issues the same ORDER BY as the previous one.
        //
        // Reading both column AND order off the sorter (rather
        // than dispatching a "toggle" hint) makes the receiver's
        // job idempotent: clicking a different column fires both
        // notifies in some order, but each carries the post-state
        // pair, and the receiver short-circuits when the pair
        // already matches `current_sort`.
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

    (column_view, selection, setter)
}

#[allow(clippy::too_many_arguments)]
fn build_column(
    info: &ColumnInfo,
    idx: usize,
    editable: bool,
    table: String,
    sender: Option<relm4::Sender<GridMsg>>,
    sort_sender: Option<relm4::Sender<GridMsg>>,
    connection_id: Option<uuid::Uuid>,
    tab_ctx: TabGridContext,
    default_min_width: Option<i32>,
) -> gtk::ColumnViewColumn {
    let factory = gtk::SignalListItemFactory::new();
    // Editable cells require a sender to dispatch CellEdited / SetCellNull /
    // CopyRowAsInsert events. When `sender` is None (read-only result grids
    // in the editor) we always go through the read-only setup path.
    let edit_sender = if editable { sender.clone() } else { None };
    let readonly_sender = sender.clone();
    let table_for_persist = table;

    let column_data_type = info.data_type.clone();
    let column_name = info.name.clone();
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        if let Some(edit_sender) = edit_sender.clone() {
            // Type-specific cell widgets per HIG:
            // - Bool → GtkCheckButton (single-click toggles, native
            //   Space, no edit-mode dance).
            // - Date → CellEditor for display + GtkCalendar
            //   popover for edit (no inline typing; user picks a day).
            // - Other types → CellEditor + text parsing on
            //   commit (parse_input_for_column on the receiving side
            //   coerces to the right native Value variant).
            if is_bool_type(&column_data_type) {
                setup_bool_cell(item, idx, column_name.clone(), edit_sender);
            } else {
                let editor_kind = classify_editor_kind(&column_data_type);
                setup_editable_cell(item, idx, column_name.clone(), edit_sender, editor_kind);
            }
        } else {
            setup_readonly_cell(item, idx, column_name.clone(), readonly_sender.clone());
        }
    });

    let editable_for_bind = editable && sender.is_some();
    let tab_ctx_for_bind = tab_ctx.clone();
    factory.connect_bind(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let Some(row) = item.item().and_downcast::<RowObject>() else {
            return;
        };
        // For persisted rows, RowObject.cells holds the immutable
        // original DB values — the tracker is the single source of
        // truth for pending edits. Override with the tracker's
        // pending value when one exists so the cell visibly
        // reflects what the user typed (with `tp-cell-modified`
        // applied below for the orange tint). Without this, edits
        // appear to "disappear" the moment the cell rebinds, which
        // is exactly the symptom the user hit on undo.
        //
        // Drafts skip this branch — their cells live inside the
        // tracker's `inserts.values` AND mirror onto RowObject
        // (set_cell at edit time), so `row.cell_value(idx)` is
        // already authoritative for them.
        let raw_value = row.cell_value(idx);
        let value = if let Some(tab_id) = tab_ctx_for_bind.tab_id
            && row.draft_id().is_none()
        {
            let pk_values: Vec<Value> = tab_ctx_for_bind
                .pk_col_indices
                .iter()
                .map(|&i| row.cell_value(i))
                .collect();
            crate::services::change_tracker::with_tab_ref(tab_id, |t| {
                crate::services::change_tracker::RowKey::from_pk_values(&pk_values)
                    .map(|key| t.current_cell_value(&key, idx, &raw_value).clone())
                    .unwrap_or_else(|| raw_value.clone())
            })
            .unwrap_or(raw_value)
        } else {
            raw_value
        };
        let is_null = matches!(value, Value::Null);
        // Editable cells render NULL as the italic <NULL> sentinel —
        // distinguishes a true NULL from an empty string visually.
        // Read-only cells use the regular display path which already
        // shows "NULL" in dim text.
        let text = if editable_for_bind {
            if is_null {
                editable_null_sentinel()
            } else {
                value_to_edit_text(&value)
            }
        } else {
            value_to_display_text(&value)
        };

        // Query the per-tab change tracker for pending state on this
        // (row, col). Apply tp-cell-modified / tp-row-pending-delete /
        // tp-row-pending-insert CSS classes accordingly. Done at bind
        // time so scroll-recycled widgets always reflect current
        // tracker state without needing per-cell signal subscriptions.
        //
        // Draft rows are detected via RowObject's draft_id field
        // (set when the row was created via the inline-Insert flow).
        // Persisted rows are keyed by PK column values via
        // RowKey::from_pk_values.
        //
        // The leftmost cell (idx == 0) gets an extra row-level class
        // (tp-row-leftmost-{insert|update|delete}) that draws a 3px
        // accent ribbon flush to the left edge — a HIG-aligned signal
        // for "this row has changes" that survives row recycling.
        let pending_classes: Vec<&'static str> = if let Some(_tab_id) = tab_ctx_for_bind.tab_id {
            if row.draft_id().is_some() {
                let mut v = vec!["tp-row-pending-insert"];
                if idx == 0 {
                    v.push("tp-row-leftmost-insert");
                }
                v
            } else {
                let pk_values: Vec<Value> = tab_ctx_for_bind
                    .pk_col_indices
                    .iter()
                    .map(|&i| row.cell_value(i))
                    .collect();
                crate::services::change_tracker::with_tab_ref(_tab_id, |t| {
                    let mut v: Vec<&'static str> = Vec::new();
                    let Some(key) = crate::services::change_tracker::RowKey::from_pk_values(&pk_values) else {
                        return v;
                    };
                    let row_state = t.row_state(&key);
                    let cell_state = t.cell_state(&key, idx);
                    use crate::services::change_tracker::{CellState, RowState};
                    match (row_state, cell_state) {
                        (RowState::PendingDelete, _) => v.push("tp-row-pending-delete"),
                        (RowState::InsertDraft, _) => v.push("tp-row-pending-insert"),
                        (_, CellState::Modified) => v.push("tp-cell-modified"),
                        _ => {}
                    }
                    if idx == 0 {
                        // Error-row flash takes precedence over the
                        // pending-state ribbon: the user's attention
                        // should be on the failing row first.
                        if t.is_error_row(&key) {
                            v.push("tp-row-leftmost-error-flash");
                        } else {
                            match row_state {
                                RowState::PendingDelete => v.push("tp-row-leftmost-delete"),
                                RowState::InsertDraft => v.push("tp-row-leftmost-insert"),
                                RowState::Modified => v.push("tp-row-leftmost-update"),
                                RowState::Clean => {}
                            }
                        }
                    }
                    v
                })
                .unwrap_or_default()
            }
        } else {
            Vec::new()
        };

        let is_pending_delete = pending_classes.contains(&"tp-row-pending-delete");
        let Some(child) = item.child() else { return };
        if let Ok(label) = child.clone().downcast::<super::cell_editor::CellEditor>() {
            label.set_text(&text);
            apply_cell_tooltip(label.upcast_ref(), &text, is_null);
            if is_null && !editable_for_bind {
                label.add_css_class("dim-label");
            } else {
                label.remove_css_class("dim-label");
            }
            // Italic-dim render of <NULL> in editable cells
            // distinguishes true NULL from empty string at a glance.
            if is_null && editable_for_bind {
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
            // Bool cell: render via active / inconsistent state. Suppress
            // the toggled signal during programmatic set so the bind
            // doesn't echo as a synthetic CellEdited event.
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
                    // Defensive: a non-bool value in a bool column means
                    // the driver returned an unexpected type. Render
                    // unchecked + inconsistent so the user sees something
                    // is off rather than a confidently-wrong checkbox.
                    checkbox.set_inconsistent(true);
                    checkbox.set_active(false);
                }
            }
            SUPPRESS_SLOT.set(&checkbox, false);
            clear_pending_classes(checkbox.upcast_ref());
            for cls in &pending_classes {
                checkbox.add_css_class(cls);
            }
            // Bool cells can't render a strikethrough on the box; dim
            // via opacity for pending-delete instead.
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
        if let Ok(label) = child.clone().downcast::<super::cell_editor::CellEditor>() {
            if label.is_editing() {
                label.stop_editing(false);
            }
            // Pop down any open popover (calendar / spin / JSON) so it
            // unparents itself before the cell is recycled. Otherwise
            // GTK warns "Finalizing widget, but it still has children
            // left: GtkPopover" on parent destruction.
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
    if let Some(id) = connection_id {
        if let Some(saved) = crate::services::column_widths::load(id, &table_for_persist, &info.name) {
            column.set_fixed_width(saved);
        } else if let Some(min) = default_min_width {
            // No persisted width: seed with the wide-table fallback so
            // the column starts readable. The user can still resize,
            // and connect_fixed_width_notify will persist the new
            // value the moment it changes.
            column.set_fixed_width(min);
        }
        let column_for_save = column.clone();
        let column_name = info.name.clone();
        column.connect_fixed_width_notify(move |_| {
            let width = column_for_save.fixed_width();
            if width > 0 {
                crate::services::column_widths::save(id, &table_for_persist, &column_name, width);
            }
        });
    } else if let Some(min) = default_min_width {
        // Editor result grids run without a connection_id (no
        // persistence), but the wide-table problem still applies.
        column.set_fixed_width(min);
    }
    column
}

/// Setup an editable cell. Display widget is `super::cell_editor::CellEditor`,
/// a `Stack[Label | Text]` glib subclass. The `Label` page is shown at
/// rest; `start_editing()` switches the stack to the `Text` page and
/// the `editing-notify` callback fires `CellEdited` if the text changed.
///
/// We require a deliberate double-click rather than the widget default
/// (focus-then-click) because clicks in a data grid are routinely
/// row-selection clicks — a single-click trigger would silently drop
/// the user into edit mode on the cell they happened to land on.
fn setup_editable_cell(
    item: &gtk::ListItem,
    idx: usize,
    column_name: String,
    sender: relm4::Sender<GridMsg>,
    editor_kind: CellEditorKind,
) {
    let label = super::cell_editor::CellEditor::new();
    label.set_hexpand(true);
    label.set_margin_start(8);
    label.set_margin_end(8);
    // Stash the column index so keyboard shortcuts (Ctrl+Shift+N)
    // can resolve `(row, col)` from the focused widget. POSITION_SLOT
    // is written by connect_bind because the position changes as
    // rows scroll-recycle.
    COLUMN_SLOT.set(&label, idx);
    item.set_child(Some(&label));

    attach_context_menu(label.upcast_ref(), idx, column_name, sender.clone(), true);
    install_edit_commit_handler(&label, idx, sender.clone());
    install_edit_triggers(&label, idx, sender, editor_kind);
}

/// Bool cells render as a real `gtk::CheckButton`. Click toggles, Space
/// toggles (native), no edit-mode dance. The toggled signal emits a
/// `GridMsg::CellEdited` with a "true"/"false" payload that
/// `parse_input_for_column` upgrades to `Value::Bool` on the receiving
/// side. CheckButton's native focus ring already distinguishes it from
/// the row selection, so this path doesn't need the cell focus-ring CSS
/// added in C1.
fn setup_bool_cell(item: &gtk::ListItem, idx: usize, column_name: String, sender: relm4::Sender<GridMsg>) {
    let checkbox = gtk::CheckButton::builder()
        .halign(gtk::Align::Start)
        .valign(gtk::Align::Center)
        .margin_start(8)
        .margin_end(8)
        .build();
    COLUMN_SLOT.set(&checkbox, idx);
    item.set_child(Some(&checkbox));

    attach_context_menu(checkbox.upcast_ref(), idx, column_name, sender.clone(), true);
    checkbox.connect_toggled(move |cb| {
        // Suppress the echo while the bind callback is driving the
        // checkbox programmatically.
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

/// Flip the cell into edit mode, clearing the `<NULL>` sentinel
/// first so the user types into an empty entry rather than over
/// the sentinel string. Centralised so every entry path
/// (double-click, F2, Enter, context-menu Edit) behaves the same.
fn enter_edit_mode(label: &super::cell_editor::CellEditor) {
    if label.text().as_str() == editable_null_sentinel() {
        label.set_text("");
    }
    label.start_editing();
}

/// The user-visible "NULL" sentinel rendered in editable cells. Goes
/// through `tr!` so locales that prefer a different convention can
/// translate it; the bracketed form is the canonical English variant
/// that keeps the sentinel visually distinct from a literal "NULL"
/// text value.
pub(crate) fn editable_null_sentinel() -> String {
    crate::tr!("<NULL>")
}

/// Read-only NULL rendering. Separate from the editable sentinel so
/// translators can localise both forms independently — read-only
/// cells dim the text and don't need the angle-bracket disambig.
pub(crate) fn readonly_null_sentinel() -> String {
    crate::tr!("NULL")
}

/// Detect whether a column's declared data_type is boolean. Mirrors
/// the bool branch of `classify_type` in browse_tab; kept local here
/// to avoid pulling browse_tab into grid's compile graph for one fn.
fn is_bool_type(data_type: &str) -> bool {
    let dt = data_type.to_ascii_lowercase();
    matches!(dt.as_str(), "bool" | "boolean" | "bit" | "tinyint(1)")
}

/// CSS classes that connect_bind toggles per pending-state. Centralised
/// here so the three cell-widget branches (Label, CellEditor,
/// CheckButton) clear the same set without drift.
const PENDING_CSS_CLASSES: &[&str] = &[
    "tp-cell-modified",
    "tp-row-pending-delete",
    "tp-row-pending-insert",
    "tp-row-leftmost-insert",
    "tp-row-leftmost-update",
    "tp-row-leftmost-delete",
    "tp-row-leftmost-error-flash",
];

fn clear_pending_classes(widget: &gtk::Widget) {
    for cls in PENDING_CSS_CLASSES {
        widget.remove_css_class(cls);
    }
}

/// Set a tooltip on a cell widget when its text is long enough that
/// the column may visibly truncate it. The cell label uses Pango
/// ellipsization (`set_ellipsize(EllipsizeMode::End)`) — once a column
/// is narrower than the text, the trailing characters disappear with
/// a "…". The tooltip lets the user hover to see the full value.
///
/// Threshold: `TOOLTIP_MIN_CHARS` covers typical 200px column widths
/// at standard font scaling. Below it the text reliably fits and the
/// tooltip would be redundant. NULL cells skip the tooltip — the
/// rendered "NULL" / "<NULL>" sentinels are already short and a
/// tooltip on every NULL would be visual noise on a column of
/// nullable values.
const TOOLTIP_MIN_CHARS: usize = 40;

/// Column count above which a per-column minimum starting width is
/// applied (in absence of persisted widths). Below this threshold,
/// the default `expand: true` shares the viewport without producing
/// unreadably-narrow cells; above it, fractional sharing becomes the
/// dominant problem.
const WIDE_TABLE_THRESHOLD: usize = 8;
/// Per-column minimum width applied when a wide table has no saved
/// widths. Picked to fit ~14 chars at the standard GTK font scale
/// (a typical short identifier or numeric value); the user can
/// resize from there and the new value persists.
const MIN_COLUMN_WIDTH_PX: i32 = 120;

fn apply_cell_tooltip(widget: &gtk::Widget, text: &str, is_null: bool) {
    if is_null || text.chars().take(TOOLTIP_MIN_CHARS + 1).count() <= TOOLTIP_MIN_CHARS {
        widget.set_tooltip_text(None);
    } else {
        widget.set_tooltip_text(Some(text));
    }
}

/// Apply or clear a Pango strikethrough attribute on a `GtkLabel`.
/// Used in preference to CSS `text-decoration: line-through` because
/// GTK4's CSS engine doesn't reliably cascade text-decoration through
/// the `CellEditor`'s internal `Stack > Label` structure.
fn set_label_strikethrough(label: &gtk::Label, on: bool) {
    if on {
        let attrs = gtk::pango::AttrList::new();
        attrs.insert(gtk::pango::AttrInt::new_strikethrough(true));
        label.set_attributes(Some(&attrs));
    } else {
        label.set_attributes(None);
    }
}

/// Detect whether a column's declared data_type is a plain SQL date
/// (no time component). Datetime, timestamp, and timestamptz columns
/// fall through to text-edit because a calendar widget alone can't
/// capture time + zone — those use the standard CellEditor + ISO
/// 8601 parser.
fn is_date_type(data_type: &str) -> bool {
    let dt = data_type.to_ascii_lowercase();
    dt == "date" || (dt.starts_with("date") && !dt.contains("datetime") && !dt.contains("time"))
}

/// Detect whether a column is integer-typed (excludes `tinyint(1)`
/// which is bool — caller must check `is_bool_type` first).
fn is_int_type(data_type: &str) -> bool {
    let dt = data_type.to_ascii_lowercase();
    matches!(
        dt.as_str(),
        "int"
            | "int2"
            | "int4"
            | "int8"
            | "integer"
            | "smallint"
            | "bigint"
            | "tinyint"
            | "mediumint"
            | "serial"
            | "bigserial"
            | "smallserial"
    ) || dt.starts_with("int(")
        || dt.starts_with("integer(")
        || dt.starts_with("smallint(")
        || dt.starts_with("bigint(")
        || dt.starts_with("mediumint(")
}

/// Detect whether a column is floating-point typed. Decimal /
/// numeric / money are intentionally excluded because `rust_decimal`
/// is arbitrary-precision and `GtkSpinButton` is f64-internally.
fn is_float_type(data_type: &str) -> bool {
    let dt = data_type.to_ascii_lowercase();
    matches!(dt.as_str(), "float" | "double" | "real" | "double precision") || dt.starts_with("float(")
}

/// Detect whether a column is JSON-typed.
fn is_json_type(data_type: &str) -> bool {
    let dt = data_type.to_ascii_lowercase();
    dt.contains("json")
}

/// Per-type cell editor selection. Bool is handled separately via
/// `setup_bool_cell` (CheckButton) and never reaches `setup_editable_cell`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CellEditorKind {
    /// Default `CellEditor` with text parsing on commit.
    Text,
    /// `GtkCalendar` popover, day-selected commits ISO 8601 date.
    Date,
    /// `GtkSpinButton` popover with integer-only adjustment.
    Int,
    /// `GtkSpinButton` popover with floating-point adjustment.
    Float,
    /// `GtkSourceView` popover with json language and Save button.
    Json,
}

fn classify_editor_kind(data_type: &str) -> CellEditorKind {
    // Bool is filtered out at the call site (handled by setup_bool_cell).
    // Order matters: json check before generic int/float since the type
    // strings overlap occasionally on contrived schemas.
    if is_date_type(data_type) {
        CellEditorKind::Date
    } else if is_json_type(data_type) {
        CellEditorKind::Json
    } else if is_int_type(data_type) {
        CellEditorKind::Int
    } else if is_float_type(data_type) {
        CellEditorKind::Float
    } else {
        CellEditorKind::Text
    }
}

/// Ask the window to advance focus by one step in the given direction.
/// `child_focus` on the root window mirrors what a real Tab keypress
/// would do, so the next focusable widget (next cell, with the
/// default `TAB_ALL` behaviour on `GtkColumnView`) gets the cursor.
fn move_focus(widget: &impl IsA<gtk::Widget>, direction: gtk::DirectionType) {
    let Some(root) = widget.root() else { return };
    let Ok(window) = root.dynamic_cast::<gtk::Window>() else {
        return;
    };
    window.child_focus(direction);
}

/// Setup a read-only cell — plain `gtk::Label` with selectable text +
/// ellipsis on overflow, plus the context menu (Copy value, Copy row
/// as INSERT) for non-mutating actions.
fn setup_readonly_cell(
    item: &gtk::ListItem,
    idx: usize,
    column_name: String,
    sender: Option<relm4::Sender<GridMsg>>,
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
    if let Some(sender) = sender {
        attach_context_menu(label.upcast_ref(), idx, column_name, sender, false);
    }
}

/// Capture-phase double-click + key handler bundle. Routes F2 / Enter
/// / double-click to either text-edit mode (default) or a date-picker
/// popover, depending on the column type. Tab / Shift+Tab during text
/// edit commit and traverse cells. The two installs share a single
/// `Rc<dyn Fn>` trigger so the date-popover capture only happens once.
///
/// Capture phase on the gesture is required because `ColumnView`'s
/// row-selection logic absorbs press events in the default Bubble
/// phase before they can reach this cell-level controller.
fn install_edit_triggers(
    label: &super::cell_editor::CellEditor,
    col_index: usize,
    sender: relm4::Sender<GridMsg>,
    editor_kind: CellEditorKind,
) {
    let trigger: std::rc::Rc<dyn Fn(&super::cell_editor::CellEditor)> = match editor_kind {
        CellEditorKind::Text => std::rc::Rc::new(|l: &super::cell_editor::CellEditor| enter_edit_mode(l)),
        CellEditorKind::Date => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_calendar_popover(l, col_index, &sender))
        }
        CellEditorKind::Int => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_spin_button_popover(l, col_index, &sender, false))
        }
        CellEditorKind::Float => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_spin_button_popover(l, col_index, &sender, true))
        }
        CellEditorKind::Json => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_json_popover(l, col_index, &sender))
        }
    };

    // Double-click → trigger. Capture phase so we beat the ColumnView
    // row-selection gesture that runs in Bubble.
    let gesture = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_PRIMARY).build();
    gesture.set_propagation_phase(gtk::PropagationPhase::Capture);
    let label_for_press = label.clone();
    let trigger_for_press = trigger.clone();
    gesture.connect_pressed(move |gesture, n_press, _, _| {
        if n_press != 2 {
            return;
        }
        gesture.set_state(gtk::EventSequenceState::Claimed);
        trigger_for_press(&label_for_press);
    });
    label.add_controller(gesture);

    // Keyboard model:
    // - Not editing: F2 / Return / KP_Enter → trigger (start text edit,
    //   open calendar / spin / json popover, etc.).
    // - Editing (only reachable for `CellEditorKind::Text` since other
    //   kinds use popovers and never enter CellEditor edit mode):
    //   Tab / Shift+Tab commit + traverse. Return / Esc handled by
    //   CellEditor's built-in entry handlers.
    let controller = gtk::EventControllerKey::new();
    let label_for_key = label.clone();
    let trigger_for_key = trigger;
    controller.connect_key_pressed(move |_, keyval, _, modifiers| {
        let editing = label_for_key.is_editing();
        let shift = modifiers.contains(gtk::gdk::ModifierType::SHIFT_MASK);

        if !editing {
            match keyval {
                gtk::gdk::Key::F2 | gtk::gdk::Key::Return | gtk::gdk::Key::KP_Enter => {
                    trigger_for_key(&label_for_key);
                    return glib::Propagation::Stop;
                }
                // Tab / Shift+Tab when NOT editing: traverse cells.
                // Without this they'd fall through to GTK's default
                // focus chain and escape the grid to the paginator.
                gtk::gdk::Key::Tab if !shift => {
                    move_focus(&label_for_key, gtk::DirectionType::TabForward);
                    return glib::Propagation::Stop;
                }
                gtk::gdk::Key::Tab | gtk::gdk::Key::ISO_Left_Tab if shift => {
                    move_focus(&label_for_key, gtk::DirectionType::TabBackward);
                    return glib::Propagation::Stop;
                }
                // Left / Right arrow cell navigation. ColumnView's
                // built-in Up/Down handles row selection; we add the
                // horizontal axis to match spreadsheet convention.
                gtk::gdk::Key::Right => {
                    move_focus(&label_for_key, gtk::DirectionType::TabForward);
                    return glib::Propagation::Stop;
                }
                gtk::gdk::Key::Left => {
                    move_focus(&label_for_key, gtk::DirectionType::TabBackward);
                    return glib::Propagation::Stop;
                }
                _ => {}
            }
            return glib::Propagation::Proceed;
        }

        match keyval {
            gtk::gdk::Key::Tab if !shift => {
                label_for_key.stop_editing(true);
                move_focus(&label_for_key, gtk::DirectionType::TabForward);
                glib::Propagation::Stop
            }
            gtk::gdk::Key::Tab | gtk::gdk::Key::ISO_Left_Tab if shift => {
                label_for_key.stop_editing(true);
                move_focus(&label_for_key, gtk::DirectionType::TabBackward);
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        }
    });
    label.add_controller(controller);
}

/// Open a `GtkCalendar` popover anchored to the cell. Pre-selects the
/// cell's current date if the displayed text is a parseable ISO 8601
/// date; otherwise the calendar shows today's month with no selection.
/// `day-selected` formats YYYY-MM-DD and emits `GridMsg::CellEdited`.
fn show_calendar_popover(label: &super::cell_editor::CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>) {
    let calendar = gtk::Calendar::new();
    if let Ok(parsed) = chrono::NaiveDate::parse_from_str(label.text().as_str(), "%Y-%m-%d")
        && let Ok(dt) = glib::DateTime::from_local(parsed.year(), parsed.month() as i32, parsed.day() as i32, 0, 0, 0.0)
    {
        calendar.select_day(&dt);
    }

    let popover = gtk::Popover::builder().child(&calendar).build();
    popover.set_parent(label);
    POPOVER_SLOT.set(label, popover.clone());

    let label_for_cal = label.clone();
    let popover_for_cal = popover.clone();
    let sender_for_cal = sender.clone();
    calendar.connect_day_selected(move |c| {
        let dt = c.date();
        // glib::DateTime month is 1-based; chrono format directly.
        let formatted = format!("{:04}-{:02}-{:02}", dt.year(), dt.month(), dt.day_of_month());
        let position = POSITION_SLOT.get(&label_for_cal).unwrap_or(0);
        // Update the label text so the visual changes immediately
        // even if the tracker round-trip is async.
        label_for_cal.set_text(&formatted);
        sender_for_cal
            .send(GridMsg::CellEdited {
                row_position: position,
                col_index,
                new_value: formatted,
            })
            .ok();
        popover_for_cal.popdown();
    });

    install_popover_close_cleanup(label, &popover);
    popover.popup();
}

/// Open a `GtkSpinButton` popover anchored to the cell. Pre-fills from
/// the current cell text. Enter (the spin button's `activate` signal)
/// commits and closes; Esc / click-outside cancels. `is_float = true`
/// configures the adjustment for fractional values with 6 digits of
/// precision; `false` for integers (no decimals). Decimal columns
/// stay on the text-edit path because GtkSpinButton is f64-internally
/// and would lose `rust_decimal` precision.
fn show_spin_button_popover(
    label: &super::cell_editor::CellEditor,
    col_index: usize,
    sender: &relm4::Sender<GridMsg>,
    is_float: bool,
) {
    let current_text = label.text().to_string();
    let (initial, lower, upper, step, digits) = if is_float {
        let val = current_text.parse::<f64>().unwrap_or(0.0);
        (val, f64::MIN, f64::MAX, 0.1_f64, 6_u32)
    } else {
        let val = current_text.parse::<i64>().unwrap_or(0) as f64;
        (val, i64::MIN as f64, i64::MAX as f64, 1.0_f64, 0_u32)
    };
    let adjustment = gtk::Adjustment::new(initial, lower, upper, step, step * 10.0, 0.0);
    let spin = gtk::SpinButton::new(Some(&adjustment), step, digits);
    spin.set_numeric(true);
    spin.set_width_chars(20);

    let popover = gtk::Popover::builder().child(&spin).build();
    popover.set_parent(label);
    POPOVER_SLOT.set(label, popover.clone());

    let label_for_commit = label.clone();
    let popover_for_commit = popover.clone();
    let sender_for_commit = sender.clone();
    spin.connect_activate(move |s| {
        // Format faithfully to the column kind: integers as "{}",
        // floats as f64::Display (drops trailing zeros, no fixed
        // precision so we don't lie about precision we don't have).
        let formatted = if is_float {
            format!("{}", s.value())
        } else {
            format!("{}", s.value() as i64)
        };
        let position = POSITION_SLOT.get(&label_for_commit).unwrap_or(0);
        label_for_commit.set_text(&formatted);
        sender_for_commit
            .send(GridMsg::CellEdited {
                row_position: position,
                col_index,
                new_value: formatted,
            })
            .ok();
        popover_for_commit.popdown();
    });

    install_popover_close_cleanup(label, &popover);
    popover.popup();
    spin.grab_focus();
}

/// Open a `GtkSourceView` popover for editing JSON. Multi-line, json
/// language for syntax highlighting, monospace font, line numbers.
/// Explicit Save button (the buffer is multi-line so Enter inserts a
/// newline rather than committing). Esc / click-outside cancels.
fn show_json_popover(label: &super::cell_editor::CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>) {
    let buffer = sourceview5::Buffer::new(None);
    if let Some(lang) = sourceview5::LanguageManager::default().language("json") {
        buffer.set_language(Some(&lang));
    }
    buffer.set_text(label.text().as_str());

    let view = sourceview5::View::with_buffer(&buffer);
    view.set_show_line_numbers(true);
    view.set_monospace(true);
    view.set_auto_indent(true);
    view.set_tab_width(2);
    view.set_indent_width(2);

    let scrolled = gtk::ScrolledWindow::builder()
        .child(&view)
        .min_content_width(420)
        .min_content_height(280)
        .has_frame(true)
        .build();

    let save_button = gtk::Button::with_label(&crate::tr!("Save"));
    save_button.add_css_class("suggested-action");

    let cancel_button = gtk::Button::with_label(&crate::tr!("Cancel"));

    let button_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .halign(gtk::Align::End)
        .build();
    button_box.append(&cancel_button);
    button_box.append(&save_button);

    let container = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .margin_top(8)
        .margin_bottom(8)
        .margin_start(8)
        .margin_end(8)
        .build();
    container.append(&scrolled);
    container.append(&button_box);

    let popover = gtk::Popover::builder().child(&container).build();
    popover.set_parent(label);
    POPOVER_SLOT.set(label, popover.clone());

    let popover_for_cancel = popover.clone();
    cancel_button.connect_clicked(move |_| popover_for_cancel.popdown());

    let label_for_commit = label.clone();
    let popover_for_commit = popover.clone();
    let sender_for_commit = sender.clone();
    let buffer_for_commit = buffer.clone();
    save_button.connect_clicked(move |_| {
        let start = buffer_for_commit.start_iter();
        let end = buffer_for_commit.end_iter();
        let text = buffer_for_commit.text(&start, &end, true).to_string();
        let position = POSITION_SLOT.get(&label_for_commit).unwrap_or(0);
        // Show the new text in the cell immediately. parse_input_for_column
        // on the receiving side validates and rejects with a toast if
        // the JSON is malformed.
        label_for_commit.set_text(&text);
        sender_for_commit
            .send(GridMsg::CellEdited {
                row_position: position,
                col_index,
                new_value: text,
            })
            .ok();
        popover_for_commit.popdown();
    });

    install_popover_close_cleanup(label, &popover);
    popover.popup();
    view.grab_focus();
}

/// Wire `popover.connect_closed` to unparent the popover and clear the
/// per-cell `POPOVER_SLOT`. Used by all three editor popovers
/// (calendar, spin button, JSON sourceview) to share one lifecycle.
fn install_popover_close_cleanup(label: &super::cell_editor::CellEditor, popover: &gtk::Popover) {
    let label_for_close = label.clone();
    // Use the callback's first parameter rather than a captured clone
    // so the closure doesn't hold a strong reference back to the
    // popover. A self-capture would form an Rc cycle that delays the
    // popover's finalisation past popdown.
    popover.connect_closed(move |p| {
        p.unparent();
        POPOVER_SLOT.take(&label_for_close);
    });
}

/// Wire the editing-notify signal: snapshot the original text on
/// entry, commit (or skip if unchanged) on exit. `CellEditor` only
/// switches to edit mode through `start_editing()`, so there's no
/// implicit click-to-edit path to disarm here.
///
/// IME-safe: while the inner GtkText has an active preedit (CJK
/// composition, ibus / fcitx / ime-mode entries), we ignore the
/// `editing-notify(false)` event — it fires when focus shifts to
/// the IME popover. The preedit-changed handler clears the gate
/// when composition completes; the next `editing-notify(false)`
/// after that fires the real commit.
fn install_edit_commit_handler(label: &super::cell_editor::CellEditor, col_index: usize, sender: relm4::Sender<GridMsg>) {
    // The cell's edit-mode child is a `gtk::Text`; that child owns
    // the IME context and emits preedit-changed.
    {
        let text = label.entry();
        let label_for_preedit = label.clone();
        let sender_for_preedit = sender.clone();
        text.connect_preedit_changed(move |_t, preedit| {
            let active = !preedit.is_empty();
            PREEDIT_SLOT.set(&label_for_preedit, active);
            // If preedit just cleared and editing has already ended
            // (focus left to the IME popover then back), fire the
            // pending commit now.
            if !active && !label_for_preedit.is_editing() {
                commit_cell_edit(&label_for_preedit, col_index, &sender_for_preedit);
            }
        });
    }

    label.connect_editing_notify(move |label| {
        if label.is_editing() {
            let position = POSITION_SLOT.get(label).unwrap_or(0);
            let original = label.text().to_string();
            SNAPSHOT_SLOT.set(label, EditSnapshot { position, original });
            return;
        }
        // Defer commit while an IME preedit is still pending — the
        // preedit-changed handler will trigger the commit when
        // composition finishes.
        if PREEDIT_SLOT.get(label).unwrap_or(false) {
            return;
        }
        commit_cell_edit(label, col_index, &sender);
    });
}

/// Commit the current `CellEditor` text via `GridMsg::CellEdited`
/// if it differs from the snapshot taken at edit-mode entry. Shared
/// between the editing-notify path and the IME preedit-cleared path
/// so both produce identical tracker state.
fn commit_cell_edit(label: &super::cell_editor::CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>) {
    let Some(snap) = SNAPSHOT_SLOT.take(label) else {
        return;
    };
    let new_value = label.text().to_string();
    if new_value == snap.original {
        return;
    }
    sender
        .send(GridMsg::CellEdited {
            row_position: snap.position,
            col_index,
            new_value,
        })
        .ok();
}

fn attach_context_menu(
    widget: &gtk::Widget,
    idx: usize,
    column_name: String,
    sender: relm4::Sender<GridMsg>,
    editable: bool,
) {
    // Build the menu in three sections per HIG: edit (cell-scope) →
    // copy (read-only conveniences) → mutate (destructive). Sections
    // render with separators automatically. "Edit cell" is only shown
    // when the cell widget is actually a text-editable widget;
    // CheckButton bool cells do their own editing via click/Space.
    let is_text_editable = editable && widget.is::<super::cell_editor::CellEditor>();
    let menu = gio::Menu::new();
    if is_text_editable {
        let edit = gio::Menu::new();
        edit.append(Some(&crate::tr!("Edit cell")), Some("cell.edit"));
        menu.append_section(None, &edit);
    }
    let copy = gio::Menu::new();
    copy.append(Some(&crate::tr!("Copy value")), Some("cell.copy-value"));
    copy.append(Some(&crate::tr!("Copy column name")), Some("cell.copy-column-name"));
    copy.append(Some(&crate::tr!("Copy row as INSERT")), Some("cell.copy-row-insert"));
    menu.append_section(None, &copy);
    if editable {
        let mutate = gio::Menu::new();
        mutate.append(Some(&crate::tr!("Insert row")), Some("cell.insert-row"));
        mutate.append(Some(&crate::tr!("Duplicate row")), Some("cell.duplicate-row"));
        mutate.append(Some(&crate::tr!("Set to NULL")), Some("cell.set-null"));
        mutate.append(Some(&crate::tr!("Delete row")), Some("cell.delete-row"));
        menu.append_section(None, &mutate);
    }

    // PopoverMenu requires manual unparenting on dispose per GTK4 docs;
    // cell widgets are recycled and finalized by the column-view, and an
    // eagerly-parented popover would leak with the warning
    // "Finalizing widget, but it still has children left: GtkPopoverMenu".
    // Build the menu *model* once, but construct + parent + unparent the
    // popover lazily inside the right-click and Menu-key handlers.
    let menu_model: gio::Menu = menu;

    let group = gio::SimpleActionGroup::new();
    let widget_for_edit = widget.clone();
    let edit = gio::ActionEntry::builder("edit")
        .activate(move |_, _, _| {
            // Mirrors the F2 / double-click trigger. No-op for non-
            // CellEditor cells (the menu item is only shown for
            // text-editable cells anyway).
            if let Ok(label) = widget_for_edit.clone().downcast::<super::cell_editor::CellEditor>() {
                enter_edit_mode(&label);
            }
        })
        .build();
    let widget_for_copy = widget.clone();
    let copy_value = gio::ActionEntry::builder("copy-value")
        .activate({
            let s = sender.clone();
            move |_, _, _| {
                s.send(GridMsg::CopyToClipboard(cell_text(&widget_for_copy))).ok();
            }
        })
        .build();
    let column_name_for_copy = column_name;
    let copy_column_name = gio::ActionEntry::builder("copy-column-name")
        .activate({
            let s = sender.clone();
            move |_, _, _| {
                s.send(GridMsg::CopyToClipboard(column_name_for_copy.clone())).ok();
            }
        })
        .build();
    let widget_for_row = widget.clone();
    let copy_row = gio::ActionEntry::builder("copy-row-insert")
        .activate({
            let s = sender.clone();
            move |_, _, _| {
                let position = POSITION_SLOT.get(&widget_for_row).unwrap_or(0);
                s.send(GridMsg::CopyRowAsInsert { row_position: position }).ok();
            }
        })
        .build();
    let insert_row = gio::ActionEntry::builder("insert-row")
        .activate({
            let s = sender.clone();
            move |_, _, _| {
                s.send(GridMsg::InsertRow).ok();
            }
        })
        .build();
    let widget_for_null = widget.clone();
    let set_null = gio::ActionEntry::builder("set-null")
        .activate({
            let s = sender.clone();
            move |_, _, _| {
                let position = POSITION_SLOT.get(&widget_for_null).unwrap_or(0);
                s.send(GridMsg::SetCellNull {
                    row_position: position,
                    col_index: idx,
                })
                .ok();
            }
        })
        .build();
    let widget_for_delete = widget.clone();
    let delete_row = gio::ActionEntry::builder("delete-row")
        .activate({
            let s = sender.clone();
            move |_, _, _| {
                let position = POSITION_SLOT.get(&widget_for_delete).unwrap_or(0);
                s.send(GridMsg::DeleteRowAt { row_position: position })
                    .ok();
            }
        })
        .build();
    let widget_for_dup = widget.clone();
    let duplicate_row = gio::ActionEntry::builder("duplicate-row")
        .activate({
            let s = sender;
            move |_, _, _| {
                let position = POSITION_SLOT.get(&widget_for_dup).unwrap_or(0);
                s.send(GridMsg::DuplicateRow { row_position: position }).ok();
            }
        })
        .build();
    group.add_action_entries([
        edit,
        copy_value,
        copy_column_name,
        copy_row,
        insert_row,
        set_null,
        delete_row,
        duplicate_row,
    ]);
    widget.insert_action_group("cell", Some(&group));

    let gesture = gtk::GestureClick::new();
    gesture.set_button(3);
    let widget_for_gesture = widget.clone();
    let menu_for_gesture = menu_model.clone();
    gesture.connect_pressed(move |g, _, x, y| {
        g.set_state(gtk::EventSequenceState::Claimed);
        present_cell_popover(
            &widget_for_gesture,
            &menu_for_gesture,
            Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)),
        );
    });
    widget.add_controller(gesture);

    let widget_for_menu_key = widget.clone();
    let menu_for_menu_key = menu_model;
    let menu_shortcut = gtk::Shortcut::builder()
        .trigger(&gtk::ShortcutTrigger::parse_string("Menu").expect("valid trigger"))
        .action(&gtk::CallbackAction::new(move |_, _| {
            present_cell_popover(&widget_for_menu_key, &menu_for_menu_key, None);
            glib::Propagation::Stop
        }))
        .build();
    let shortcut_controller = gtk::ShortcutController::new();
    shortcut_controller.add_shortcut(menu_shortcut);
    widget.add_controller(shortcut_controller);
}

/// Build a fresh `GtkPopoverMenu`, parent it to `anchor`, popup, and
/// arrange to unparent + drop on close. Lazy creation sidesteps the
/// "finalizing widget still has children" warning that
/// `set_parent`-then-leak triggers when the column-view recycles cell
/// widgets without the popover being unparented first.
fn present_cell_popover(anchor: &gtk::Widget, menu: &gio::Menu, pointing_to: Option<&gtk::gdk::Rectangle>) {
    let popover = gtk::PopoverMenu::from_model(Some(menu));
    popover.set_has_arrow(true);
    popover.set_parent(anchor);
    if let Some(rect) = pointing_to {
        popover.set_pointing_to(Some(rect));
    }
    popover.connect_closed(|p| p.unparent());
    popover.popup();
}

fn cell_text(widget: &gtk::Widget) -> String {
    if let Some(label) = widget.downcast_ref::<super::cell_editor::CellEditor>() {
        label.text().to_string()
    } else if let Some(label) = widget.downcast_ref::<gtk::Label>() {
        label.text().to_string()
    } else {
        String::new()
    }
}

fn is_cell_editable(col: &ColumnInfo) -> bool {
    // Primary keys: locked because the grid identifies rows by PK and
    // editing a PK component would orphan the tracker's row identity.
    // Generated columns: the database computes them from other columns;
    // a user-supplied value would be rejected at commit.
    // Auto-increment non-PK: rare but possible; same rejection at commit.
    // Bytes / blobs: not text-editable in any meaningful way.
    !col.primary_key && !col.is_generated && !col.is_auto_increment && !is_bytes_type(&col.data_type)
}

fn is_bytes_type(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    lower.contains("blob") || lower.contains("bytea") || lower == "binary" || lower == "varbinary"
}

#[derive(Debug)]
struct EditSnapshot {
    position: u32,
    original: String,
}

struct WidgetSlot<T: 'static> {
    key: &'static str,
    _phantom: std::marker::PhantomData<T>,
}

impl<T: 'static> WidgetSlot<T> {
    const fn new(key: &'static str) -> Self {
        Self {
            key,
            _phantom: std::marker::PhantomData,
        }
    }

    fn set(&self, widget: &impl IsA<gtk::Widget>, value: T) {
        unsafe { widget.set_data(self.key, value) };
    }

    fn take(&self, widget: &impl IsA<gtk::Widget>) -> Option<T> {
        unsafe { widget.steal_data::<T>(self.key) }
    }
}

impl<T: 'static + Copy> WidgetSlot<T> {
    fn get(&self, widget: &impl IsA<gtk::Widget>) -> Option<T> {
        unsafe { widget.data::<T>(self.key).map(|p| *p.as_ref()) }
    }
}

const POSITION_SLOT: WidgetSlot<u32> = WidgetSlot::new("tp-position");
const SNAPSHOT_SLOT: WidgetSlot<EditSnapshot> = WidgetSlot::new("tp-snapshot");
/// Column index of an editable cell. Set at setup time; read by the
/// "Set to NULL" keyboard shortcut (Ctrl+Shift+N) which routes via the
/// app-level focused-widget lookup and needs `(row, col)` to emit
/// `GridMsg::SetCellNull`.
const COLUMN_SLOT: WidgetSlot<usize> = WidgetSlot::new("tp-column");
/// Suppression flag for `GtkCheckButton::toggled` during programmatic
/// `set_active()` calls in the bind callback. Without this the bind
/// would echo as a synthetic `CellEdited` event and clobber the
/// tracker with the freshly-rendered value, looping forever.
const SUPPRESS_SLOT: WidgetSlot<bool> = WidgetSlot::new("tp-suppress-toggle");
/// Currently-open popover (calendar / spin button / JSON editor)
/// anchored to a cell widget. Set by `show_*_popover` helpers; cleared
/// by `connect_closed`. The factory's `connect_unbind` takes this slot
/// and calls `popdown()` so the popover unparents itself before its
/// parent cell widget is recycled. Without this guard ColumnView's
/// cell pool can drop a parent that still has an open popover child,
/// producing the same "Finalizing widget, but it still has children
/// left: GtkPopover" warning that we hit on context menus.
const POPOVER_SLOT: WidgetSlot<gtk::Popover> = WidgetSlot::new("tp-popover");
/// `true` while the cell's inner GtkText has a non-empty IME preedit
/// (CJK / Korean / Vietnamese / etc. composition in flight). The
/// commit handler reads this flag and defers `editing-notify(false)`
/// commits while preedit is active — focus shifts to an IME popover
/// fire `editing-notify(false)` mid-composition, and committing the
/// raw text at that point would either send an empty value or the
/// pre-composition snapshot. Cleared by the preedit-changed handler
/// when the user finishes composing.
const PREEDIT_SLOT: WidgetSlot<bool> = WidgetSlot::new("tp-preedit-active");

/// Look up the `(row_position, col_index)` of the currently focused
/// cell widget. Returns `None` when the focus is outside the window
/// or on a widget without the per-cell slots set. Widget-type-
/// agnostic by design: works for `super::cell_editor::CellEditor` (text cells),
/// `gtk::CheckButton` (bool cells), and any future cell-widget that
/// writes the slots at setup time.
pub(crate) fn focused_cell_coords(widget: &impl IsA<gtk::Widget>) -> Option<(u32, usize)> {
    let root = widget.root()?;
    let window = root.dynamic_cast::<gtk::Window>().ok()?;
    // Disambiguate `focus()` which exists on both GtkWindowExt (returns
    // the focused widget inside the window) and RootExt (returns the
    // window itself); we want the former.
    let focused = gtk4::prelude::GtkWindowExt::focus(&window)?;
    let position = POSITION_SLOT.get(&focused)?;
    let column = COLUMN_SLOT.get(&focused)?;
    Some((position, column))
}

/// Maximum characters rendered into a single grid cell. A million-
/// character TEXT or JSON column would otherwise hang the GTK main
/// thread inside Pango layout. The full value stays in the model
/// (and the JSON popover renders the unabridged text via
/// SourceView), so no editable data is lost — only the in-grid
/// preview is capped.
const DISPLAY_TEXT_MAX_CHARS: usize = 10_000;
/// Quick byte-length pre-check that avoids an O(n) `chars().count()`
/// call on safely-short strings. Worst-case UTF-8 is 4 bytes/char.
const DISPLAY_TEXT_BYTES_THRESHOLD: usize = DISPLAY_TEXT_MAX_CHARS * 4;

pub fn value_to_display_text(value: &Value) -> String {
    match value {
        Value::Null => readonly_null_sentinel(),
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Text(s) => truncate_for_display(s),
        Value::Bytes(b) => format!("<{} bytes>", b.len()),
        Value::Date(d) => d.format("%Y-%m-%d").to_string(),
        Value::Time(t) => t.format("%H:%M:%S").to_string(),
        Value::DateTime(dt) => dt.format("%Y-%m-%d %H:%M:%S").to_string(),
        Value::TimestampTz(ts) => ts.format("%Y-%m-%d %H:%M:%S%:z").to_string(),
        Value::Decimal(d) => d.to_string(),
        Value::Uuid(u) => u.to_string(),
        Value::Json(j) => truncate_for_display(&j.to_string()),
    }
}

pub fn value_to_edit_text(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        other => value_to_display_text(other),
    }
}

/// Cap a string at `DISPLAY_TEXT_MAX_CHARS` for display purposes.
/// Short strings pass through unchanged (no allocation). Long strings
/// are truncated at a UTF-8 char boundary with a `… (+N more chars)`
/// suffix so the user knows there's content beyond what's shown.
fn truncate_for_display(s: &str) -> String {
    if s.len() < DISPLAY_TEXT_BYTES_THRESHOLD {
        return s.to_string();
    }
    // Find the byte index of the (DISPLAY_TEXT_MAX_CHARS+1)-th char so
    // we slice on a valid UTF-8 boundary.
    let mut cut = s.len();
    for (i, (byte_idx, _)) in s.char_indices().enumerate() {
        if i >= DISPLAY_TEXT_MAX_CHARS {
            cut = byte_idx;
            break;
        }
    }
    if cut >= s.len() {
        return s.to_string();
    }
    let head = &s[..cut];
    let remaining = s[cut..].chars().count();
    format!("{head}… (+{remaining} more chars)")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn col(data_type: &str, primary_key: bool) -> ColumnInfo {
        ColumnInfo {
            name: "x".into(),
            data_type: data_type.into(),
            nullable: true,
            primary_key,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
        }
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
    fn bytes_type_detection() {
        assert!(is_bytes_type("BYTEA"));
        assert!(is_bytes_type("blob"));
        assert!(is_bytes_type("LONGBLOB"));
        assert!(is_bytes_type("mediumblob"));
        assert!(is_bytes_type("tinyblob"));
        assert!(is_bytes_type("VARBINARY"));
        assert!(is_bytes_type("binary"));
        assert!(!is_bytes_type("text"));
        assert!(!is_bytes_type("integer"));
    }

    #[test]
    fn display_text_primitive_variants() {
        assert_eq!(value_to_display_text(&Value::Null), "NULL");
        assert_eq!(value_to_display_text(&Value::Bool(true)), "true");
        assert_eq!(value_to_display_text(&Value::Int(42)), "42");
        assert_eq!(value_to_display_text(&Value::Text("hello".into())), "hello");
        assert_eq!(value_to_display_text(&Value::Bytes(vec![0u8; 16])), "<16 bytes>");
    }

    #[test]
    fn display_text_temporal_variants() {
        let date = chrono::NaiveDate::from_ymd_opt(2026, 4, 26).unwrap();
        assert_eq!(value_to_display_text(&Value::Date(date)), "2026-04-26");

        let time = chrono::NaiveTime::from_hms_opt(14, 30, 0).unwrap();
        assert_eq!(value_to_display_text(&Value::Time(time)), "14:30:00");

        let datetime = chrono::NaiveDateTime::new(date, time);
        assert_eq!(value_to_display_text(&Value::DateTime(datetime)), "2026-04-26 14:30:00");

        let tz = chrono::DateTime::<chrono::Utc>::from_naive_utc_and_offset(datetime, chrono::Utc);
        assert_eq!(
            value_to_display_text(&Value::TimestampTz(tz)),
            "2026-04-26 14:30:00+00:00"
        );
    }

    #[test]
    fn display_text_extended_variants() {
        let dec: rust_decimal::Decimal = "1234.56789".parse().unwrap();
        assert_eq!(value_to_display_text(&Value::Decimal(dec)), "1234.56789");

        let id = uuid::Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        assert_eq!(
            value_to_display_text(&Value::Uuid(id)),
            "550e8400-e29b-41d4-a716-446655440000"
        );

        let json = serde_json::json!({"a": 1, "b": [2, 3]});
        let text = value_to_display_text(&Value::Json(json));
        assert!(text.contains("\"a\":1"));
    }

    #[test]
    fn edit_text_distinguishes_null_from_text_null() {
        assert_eq!(value_to_edit_text(&Value::Null), "");
        assert_eq!(value_to_edit_text(&Value::Text("NULL".into())), "NULL");
        assert_eq!(value_to_edit_text(&Value::Int(0)), "0");
    }

    #[test]
    fn edit_text_keeps_extended_variants_visible() {
        let date = chrono::NaiveDate::from_ymd_opt(2026, 4, 26).unwrap();
        assert_eq!(value_to_edit_text(&Value::Date(date)), "2026-04-26");

        let id = uuid::Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        assert_eq!(
            value_to_edit_text(&Value::Uuid(id)),
            "550e8400-e29b-41d4-a716-446655440000"
        );
    }

    #[test]
    fn truncate_short_text_passes_through() {
        let s = "hello world";
        assert_eq!(truncate_for_display(s), "hello world");
    }

    #[test]
    fn truncate_caps_long_text_at_char_boundary() {
        // 100k ASCII chars: should truncate to ~10k + suffix.
        let s = "a".repeat(100_000);
        let out = truncate_for_display(&s);
        assert!(out.starts_with(&"a".repeat(10_000)));
        assert!(out.contains("more chars"));
        assert!(out.len() < 10_500); // ~10k chars + suffix bytes
    }

    #[test]
    fn truncate_handles_multibyte_boundary() {
        // 30k 4-byte emoji (120k bytes) — truncation must land on a
        // char boundary, not mid-codepoint.
        let s = "🦀".repeat(30_000);
        let out = truncate_for_display(&s);
        // Must be valid UTF-8.
        assert!(std::str::from_utf8(out.as_bytes()).is_ok());
        // First DISPLAY_TEXT_MAX_CHARS chars should be 🦀 plus the
        // suffix appended after.
        assert!(out.contains("more chars"));
    }

    #[test]
    fn display_text_truncates_huge_text_value() {
        let huge = "x".repeat(1_000_000);
        let display = value_to_display_text(&Value::Text(huge));
        assert!(display.len() < 100_000); // bounded
        assert!(display.contains("more chars"));
    }
}
