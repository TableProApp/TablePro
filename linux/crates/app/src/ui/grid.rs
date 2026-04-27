use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio, glib};

use tablepro_core::{ColumnInfo, QueryResult, Value};

use super::row_object::RowObject;

pub type FilterSetter = Rc<dyn Fn(&str)>;

#[derive(Debug)]
pub enum GridMsg {
    SortChanged(usize),
    CellEdited {
        table: String,
        row_position: u32,
        col_index: usize,
        new_value: String,
    },
    CopyToClipboard(String),
    CopyRowAsInsert {
        row_position: u32,
    },
    SetCellNull {
        table: String,
        row_position: u32,
        col_index: usize,
    },
    DeleteRowAt {
        table: String,
        row_position: u32,
    },
}

pub fn build_column_view(
    result: &QueryResult,
    schema_columns: &[ColumnInfo],
    table: &str,
    edit_sender: Option<relm4::Sender<GridMsg>>,
    sort: Option<(usize, bool)>,
    sort_sender: Option<relm4::Sender<GridMsg>>,
    connection_id: Option<uuid::Uuid>,
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
        let needle = query.to_lowercase();
        row.cells_clone()
            .iter()
            .any(|v| value_to_display_text(v).to_lowercase().contains(&needle))
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

    let mut columns: Vec<gtk::ColumnViewColumn> = Vec::with_capacity(result.columns.len());
    for (i, column) in result.columns.iter().enumerate() {
        let editable = is_cell_editable(schema_columns.get(i).unwrap_or(column));
        let sort_indicator = sort.and_then(|(c, asc)| if c == i { Some(asc) } else { None });
        let col = build_column(
            column,
            i,
            editable,
            table.to_string(),
            edit_sender.clone(),
            sort_indicator,
            sort_sender.clone(),
            connection_id,
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
        view_sorter.connect_primary_sort_column_notify(move |sorter| {
            let Some(active) = sorter.primary_sort_column() else {
                return;
            };
            for (idx, col) in columns.iter().enumerate() {
                if col == &active {
                    app_sender.send(GridMsg::SortChanged(idx)).ok();
                    break;
                }
            }
        });
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
    sort_indicator: Option<bool>,
    sort_sender: Option<relm4::Sender<GridMsg>>,
    connection_id: Option<uuid::Uuid>,
) -> gtk::ColumnViewColumn {
    let factory = gtk::SignalListItemFactory::new();
    let editable_for_setup = editable && sender.is_some();
    let sender_for_setup = sender.clone();
    let table_for_setup = table.clone();
    let table_for_persist = table;

    let context_sender = sender.clone();
    let context_table = table_for_setup.clone();
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        if editable_for_setup {
            // Double-click-to-edit, matching GNOME Files filename rename.
            // Single-click triggering edit is destructive in a database
            // grid: an accidental row-selection click would commit the
            // user into edit mode on the cell they happened to land on.
            // Pattern: keep editable=false at rest so the EditableLabel's
            // internal click→edit path is inert; flip true on double-click,
            // call start_editing(), and flip back to false on
            // editing-notify exit.
            let label = gtk::EditableLabel::builder()
                .xalign(0.0)
                .hexpand(true)
                .margin_start(8)
                .margin_end(8)
                .build();
            label.set_editable(false);
            item.set_child(Some(&label));

            let dbl_click = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_PRIMARY).build();
            let label_for_dbl = label.clone();
            dbl_click.connect_pressed(move |gesture, n_press, _, _| {
                if n_press == 2 {
                    gesture.set_state(gtk::EventSequenceState::Claimed);
                    label_for_dbl.set_editable(true);
                    label_for_dbl.start_editing();
                }
            });
            label.add_controller(dbl_click);

            if let Some(ctx_sender) = context_sender.clone() {
                attach_context_menu(label.upcast_ref(), idx, context_table.clone(), ctx_sender);
            }

            let Some(sender_clone) = sender_for_setup.clone() else {
                return;
            };
            let table_clone = table_for_setup.clone();
            label.connect_editing_notify(move |label| {
                if label.is_editing() {
                    label.add_css_class("accent");
                    let position = POSITION_SLOT.get(label).unwrap_or(0);
                    let original = label.text().to_string();
                    SNAPSHOT_SLOT.set(label, EditSnapshot { position, original });
                    return;
                }
                label.remove_css_class("accent");
                // Reset to display-only so the next click won't enter
                // edit mode via EditableLabel's internal handler.
                label.set_editable(false);
                let Some(snap) = SNAPSHOT_SLOT.take(label) else {
                    return;
                };
                let new_value = label.text().to_string();
                if new_value == snap.original {
                    return;
                }
                sender_clone
                    .send(GridMsg::CellEdited {
                        table: table_clone.clone(),
                        row_position: snap.position,
                        col_index: idx,
                        new_value,
                    })
                    .ok();
            });
        } else {
            let label = gtk::Label::builder()
                .xalign(0.0)
                .hexpand(true)
                .selectable(true)
                .ellipsize(gtk::pango::EllipsizeMode::End)
                .margin_start(8)
                .margin_end(8)
                .build();
            item.set_child(Some(&label));
            if let Some(ctx_sender) = context_sender.clone() {
                attach_context_menu(label.upcast_ref(), idx, context_table.clone(), ctx_sender);
            }
        }
    });

    let editable_for_bind = editable_for_setup;
    factory.connect_bind(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let Some(row) = item.item().and_downcast::<RowObject>() else {
            return;
        };
        let value = row.cell_value(idx);
        let is_null = matches!(value, Value::Null);
        let text = if editable_for_bind {
            value_to_edit_text(&value)
        } else {
            value_to_display_text(&value)
        };
        let Some(child) = item.child() else { return };
        if let Ok(label) = child.clone().downcast::<gtk::EditableLabel>() {
            label.set_text(&text);
            if is_null && !editable_for_bind {
                label.add_css_class("dim-label");
            } else {
                label.remove_css_class("dim-label");
            }
            POSITION_SLOT.set(&label, item.position());
        } else if let Ok(label) = child.downcast::<gtk::Label>() {
            label.set_text(&text);
            if is_null {
                label.add_css_class("dim-label");
            } else {
                label.remove_css_class("dim-label");
            }
            POSITION_SLOT.set(&label, item.position());
        }
    });

    factory.connect_unbind(|_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let Some(child) = item.child() else { return };
        if let Ok(label) = child.clone().downcast::<gtk::EditableLabel>() {
            if label.is_editing() {
                label.stop_editing(false);
            }
            POSITION_SLOT.take(&label);
            SNAPSHOT_SLOT.take(&label);
        } else if let Ok(label) = child.downcast::<gtk::Label>() {
            POSITION_SLOT.take(&label);
        }
    });

    let _ = sort_indicator; // Native ColumnView sort triangle is set on the
    // primary sort column by the caller via sort_by_column.
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
        }
        let column_for_save = column.clone();
        let column_name = info.name.clone();
        column.connect_fixed_width_notify(move |_| {
            let width = column_for_save.fixed_width();
            if width > 0 {
                crate::services::column_widths::save(id, &table_for_persist, &column_name, width);
            }
        });
    }
    column
}

fn attach_context_menu(widget: &gtk::Widget, idx: usize, table: String, sender: relm4::Sender<GridMsg>) {
    let editable = widget.is::<gtk::EditableLabel>();
    let menu = gio::Menu::new();
    menu.append(Some(&crate::tr!("Copy value")), Some("cell.copy-value"));
    menu.append(Some(&crate::tr!("Copy row as INSERT")), Some("cell.copy-row-insert"));
    if editable {
        let mutate = gio::Menu::new();
        mutate.append(Some(&crate::tr!("Set to NULL")), Some("cell.set-null"));
        mutate.append(Some(&crate::tr!("Delete row")), Some("cell.delete-row"));
        menu.append_section(None, &mutate);
    }

    let popover = gtk::PopoverMenu::from_model(Some(&menu));
    popover.set_has_arrow(true);
    popover.set_parent(widget);

    let group = gio::SimpleActionGroup::new();
    let widget_for_copy = widget.clone();
    let copy_value = gio::ActionEntry::builder("copy-value")
        .activate({
            let s = sender.clone();
            move |_, _, _| {
                s.send(GridMsg::CopyToClipboard(cell_text(&widget_for_copy))).ok();
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
    let widget_for_null = widget.clone();
    let table_for_null = table.clone();
    let set_null = gio::ActionEntry::builder("set-null")
        .activate({
            let s = sender.clone();
            move |_, _, _| {
                let position = POSITION_SLOT.get(&widget_for_null).unwrap_or(0);
                s.send(GridMsg::SetCellNull {
                    table: table_for_null.clone(),
                    row_position: position,
                    col_index: idx,
                })
                .ok();
            }
        })
        .build();
    let widget_for_delete = widget.clone();
    let table_for_delete = table;
    let delete_row = gio::ActionEntry::builder("delete-row")
        .activate({
            let s = sender;
            move |_, _, _| {
                let position = POSITION_SLOT.get(&widget_for_delete).unwrap_or(0);
                s.send(GridMsg::DeleteRowAt {
                    table: table_for_delete.clone(),
                    row_position: position,
                })
                .ok();
            }
        })
        .build();
    group.add_action_entries([copy_value, copy_row, set_null, delete_row]);
    widget.insert_action_group("cell", Some(&group));

    let gesture = gtk::GestureClick::new();
    gesture.set_button(3);
    let popover_for_gesture = popover.clone();
    gesture.connect_pressed(move |g, _, x, y| {
        g.set_state(gtk::EventSequenceState::Claimed);
        popover_for_gesture.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        popover_for_gesture.popup();
    });
    widget.add_controller(gesture);

    let menu_shortcut = gtk::Shortcut::builder()
        .trigger(&gtk::ShortcutTrigger::parse_string("Menu").expect("valid trigger"))
        .action(&gtk::CallbackAction::new({
            let popover = popover.clone();
            move |_, _| {
                popover.popup();
                glib::Propagation::Stop
            }
        }))
        .build();
    let shortcut_controller = gtk::ShortcutController::new();
    shortcut_controller.add_shortcut(menu_shortcut);
    widget.add_controller(shortcut_controller);
}

fn cell_text(widget: &gtk::Widget) -> String {
    if let Some(label) = widget.downcast_ref::<gtk::EditableLabel>() {
        label.text().to_string()
    } else if let Some(label) = widget.downcast_ref::<gtk::Label>() {
        label.text().to_string()
    } else {
        String::new()
    }
}

fn is_cell_editable(col: &ColumnInfo) -> bool {
    !col.primary_key && !is_bytes_type(&col.data_type)
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

pub fn value_to_display_text(value: &Value) -> String {
    match value {
        Value::Null => "NULL".into(),
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Text(s) => s.clone(),
        Value::Bytes(b) => format!("<{} bytes>", b.len()),
        Value::Date(d) => d.format("%Y-%m-%d").to_string(),
        Value::Time(t) => t.format("%H:%M:%S").to_string(),
        Value::DateTime(dt) => dt.format("%Y-%m-%d %H:%M:%S").to_string(),
        Value::TimestampTz(ts) => ts.format("%Y-%m-%d %H:%M:%S%:z").to_string(),
        Value::Decimal(d) => d.to_string(),
        Value::Uuid(u) => u.to_string(),
        Value::Json(j) => j.to_string(),
    }
}

pub fn value_to_edit_text(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        other => value_to_display_text(other),
    }
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
}
