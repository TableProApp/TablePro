use chrono::Datelike;
use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use sourceview5::prelude::*;

use super::GridMsg;
use super::context_menu::{GridMenus, attach_cell_gesture};
use super::display::{
    COLUMN_SLOT, EditSnapshot, FULL_EDIT_TEXT_SLOT, IS_NULL_SLOT, POPOVER_SLOT, POSITION_SLOT, PREEDIT_SLOT,
    ROW_KEY_SLOT, SNAPSHOT_SLOT, SUPPRESS_SLOT,
};
use super::types::CellEditorKind;
use crate::ui::cell_editor::CellEditor;

pub(super) fn enter_edit_mode(label: &CellEditor) {
    if !label.is_inline_editable() {
        return;
    }
    if IS_NULL_SLOT.get(label).unwrap_or(false) {
        label.start_editing_with("");
        return;
    }
    match FULL_EDIT_TEXT_SLOT.cloned(label) {
        Some(full) => label.start_editing_with(&full),
        None => label.start_editing(),
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn setup_editable_cell(
    item: &gtk::ListItem,
    idx: usize,
    column_name: String,
    sender: relm4::Sender<GridMsg>,
    editor_kind: CellEditorKind,
    column_view: &gtk::ColumnView,
    menus: Option<&GridMenus>,
) {
    let label = CellEditor::new();
    label.set_hexpand(true);
    label.set_margin_start(8);
    label.set_margin_end(8);
    COLUMN_SLOT.set(&label, idx);
    item.set_child(Some(&label));

    if let Some(menus) = menus {
        attach_cell_gesture(label.upcast_ref(), column_view, idx, column_name, true, true, menus);
    }
    install_edit_commit_handler(&label, idx, sender.clone());
    install_edit_triggers(&label, idx, sender, editor_kind);
}

pub(super) fn setup_bool_cell(
    item: &gtk::ListItem,
    idx: usize,
    column_name: String,
    sender: relm4::Sender<GridMsg>,
    column_view: &gtk::ColumnView,
    menus: Option<&GridMenus>,
) {
    let checkbox = gtk::CheckButton::builder()
        .halign(gtk::Align::Start)
        .valign(gtk::Align::Center)
        .margin_start(8)
        .margin_end(8)
        .build();
    COLUMN_SLOT.set(&checkbox, idx);
    item.set_child(Some(&checkbox));

    if let Some(menus) = menus {
        attach_cell_gesture(checkbox.upcast_ref(), column_view, idx, column_name, true, false, menus);
    }
    checkbox.connect_toggled(move |cb| {
        if !cb.is_sensitive() || SUPPRESS_SLOT.get(cb).unwrap_or(false) {
            return;
        }
        let position = POSITION_SLOT.get(cb).unwrap_or(0);
        let row_key = ROW_KEY_SLOT.cloned(cb).unwrap_or_default();
        let new_value = if cb.is_active() { "true" } else { "false" };
        sender
            .send(GridMsg::CellEdited {
                row_position: position,
                col_index: idx,
                new_value: new_value.to_string(),
                row_key,
            })
            .ok();
    });
}

pub(super) fn setup_readonly_cell(
    item: &gtk::ListItem,
    idx: usize,
    column_name: String,
    _sender: Option<relm4::Sender<GridMsg>>,
    column_view: &gtk::ColumnView,
    menus: Option<&GridMenus>,
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
    if let Some(menus) = menus {
        attach_cell_gesture(label.upcast_ref(), column_view, idx, column_name, false, false, menus);
    }
}

fn move_focus(widget: &impl IsA<gtk::Widget>, direction: gtk::DirectionType) {
    let Some(root) = widget.root() else { return };
    let Ok(window) = root.dynamic_cast::<gtk::Window>() else {
        return;
    };
    window.child_focus(direction);
}

fn install_edit_triggers(
    label: &CellEditor,
    col_index: usize,
    sender: relm4::Sender<GridMsg>,
    editor_kind: CellEditorKind,
) {
    let trigger: std::rc::Rc<dyn Fn(&CellEditor)> = match editor_kind {
        CellEditorKind::Text => std::rc::Rc::new(|l: &CellEditor| enter_edit_mode(l)),
        CellEditorKind::Date => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_calendar_popover(l, col_index, &sender))
        }
        CellEditorKind::Int => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_numeric_popover(l, col_index, &sender, false))
        }
        CellEditorKind::Float => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_numeric_popover(l, col_index, &sender, true))
        }
        CellEditorKind::Json => {
            let sender = sender.clone();
            std::rc::Rc::new(move |l| show_json_popover(l, col_index, &sender))
        }
    };
    let trigger: std::rc::Rc<dyn Fn(&CellEditor)> = {
        let inner = trigger;
        std::rc::Rc::new(move |label: &CellEditor| {
            if label.is_inline_editable() {
                inner(label);
            }
        })
    };

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
                gtk::gdk::Key::Tab if !shift => {
                    move_focus(&label_for_key, gtk::DirectionType::TabForward);
                    return glib::Propagation::Stop;
                }
                gtk::gdk::Key::Tab | gtk::gdk::Key::ISO_Left_Tab if shift => {
                    move_focus(&label_for_key, gtk::DirectionType::TabBackward);
                    return glib::Propagation::Stop;
                }
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

fn show_calendar_popover(label: &CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>) {
    let calendar = gtk::Calendar::new();
    if let Ok(parsed) = chrono::NaiveDate::parse_from_str(label.text().as_str(), "%Y-%m-%d")
        && let Ok(dt) = glib::DateTime::from_local(parsed.year(), parsed.month() as i32, parsed.day() as i32, 0, 0, 0.0)
    {
        calendar.set_date(Some(&dt));
    }

    let popover = gtk::Popover::builder().child(&calendar).build();
    popover.set_parent(label);
    POPOVER_SLOT.set(label, popover.clone());

    let label_for_cal = label.clone();
    let popover_for_cal = popover.clone();
    let sender_for_cal = sender.clone();
    calendar.connect_day_selected(move |c| {
        let dt = c.date();
        let formatted = format!("{:04}-{:02}-{:02}", dt.year(), dt.month(), dt.day_of_month());
        let position = POSITION_SLOT.get(&label_for_cal).unwrap_or(0);
        let row_key = ROW_KEY_SLOT.cloned(&label_for_cal).unwrap_or_default();
        label_for_cal.set_text(&formatted);
        sender_for_cal
            .send(GridMsg::CellEdited {
                row_position: position,
                col_index,
                new_value: formatted,
                row_key,
            })
            .ok();
        popover_for_cal.popdown();
    });

    install_popover_close_cleanup(label, &popover);
    popover.popup();
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum NumericEditor {
    Spin(f64),
    ExactText,
}

const MAX_EXACT_F64_INTEGER: i64 = 1 << 53;

pub(crate) fn numeric_editor(text: &str, is_float: bool) -> NumericEditor {
    let trimmed = text.trim();
    if is_float {
        return match trimmed.parse::<f64>() {
            Ok(value) if value.is_finite() => NumericEditor::Spin(value),
            _ => NumericEditor::ExactText,
        };
    }
    match trimmed.parse::<i64>() {
        Ok(value) if value.unsigned_abs() <= MAX_EXACT_F64_INTEGER as u64 => NumericEditor::Spin(value as f64),
        _ => NumericEditor::ExactText,
    }
}

fn show_numeric_popover(label: &CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>, is_float: bool) {
    match numeric_editor(label.text().as_str(), is_float) {
        NumericEditor::Spin(value) => show_spin_button_popover(label, col_index, sender, is_float, value),
        NumericEditor::ExactText => show_exact_text_popover(label, col_index, sender),
    }
}

fn show_exact_text_popover(label: &CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>) {
    let entry = gtk::Entry::new();
    entry.set_text(label.text().as_str());
    entry.set_width_chars(24);

    let popover = gtk::Popover::builder().child(&entry).build();
    popover.set_parent(label);
    POPOVER_SLOT.set(label, popover.clone());

    let label_for_commit = label.clone();
    let popover_for_commit = popover.clone();
    let sender_for_commit = sender.clone();
    entry.connect_activate(move |e| {
        let formatted = e.text().to_string();
        let position = POSITION_SLOT.get(&label_for_commit).unwrap_or(0);
        let row_key = ROW_KEY_SLOT.cloned(&label_for_commit).unwrap_or_default();
        label_for_commit.set_text(&formatted);
        sender_for_commit
            .send(GridMsg::CellEdited {
                row_position: position,
                col_index,
                new_value: formatted,
                row_key,
            })
            .ok();
        popover_for_commit.popdown();
    });

    install_popover_close_cleanup(label, &popover);
    popover.popup();
    entry.grab_focus();
}

fn show_spin_button_popover(
    label: &CellEditor,
    col_index: usize,
    sender: &relm4::Sender<GridMsg>,
    is_float: bool,
    initial: f64,
) {
    let (lower, upper, step, digits) = if is_float {
        (f64::MIN, f64::MAX, 0.1_f64, 6_u32)
    } else {
        let bound = MAX_EXACT_F64_INTEGER as f64;
        (-bound, bound, 1.0_f64, 0_u32)
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
        let formatted = if is_float {
            format!("{}", s.value())
        } else {
            format!("{}", s.value() as i64)
        };
        let position = POSITION_SLOT.get(&label_for_commit).unwrap_or(0);
        let row_key = ROW_KEY_SLOT.cloned(&label_for_commit).unwrap_or_default();
        label_for_commit.set_text(&formatted);
        sender_for_commit
            .send(GridMsg::CellEdited {
                row_position: position,
                col_index,
                new_value: formatted,
                row_key,
            })
            .ok();
        popover_for_commit.popdown();
    });

    install_popover_close_cleanup(label, &popover);
    popover.popup();
    spin.grab_focus();
}

fn show_json_popover(label: &CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>) {
    let buffer = sourceview5::Buffer::new(None);
    if let Some(lang) = sourceview5::LanguageManager::default().language("json") {
        buffer.set_language(Some(&lang));
    }
    let seed = FULL_EDIT_TEXT_SLOT
        .cloned(label)
        .unwrap_or_else(|| label.text().to_string());
    buffer.set_text(&seed);

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
        let row_key = ROW_KEY_SLOT.cloned(&label_for_commit).unwrap_or_default();
        label_for_commit.set_text(&text);
        FULL_EDIT_TEXT_SLOT.set(&label_for_commit, text.clone());
        sender_for_commit
            .send(GridMsg::CellEdited {
                row_position: position,
                col_index,
                new_value: text,
                row_key,
            })
            .ok();
        popover_for_commit.popdown();
    });

    install_popover_close_cleanup(label, &popover);
    popover.popup();
    view.grab_focus();
}

fn install_popover_close_cleanup(label: &CellEditor, popover: &gtk::Popover) {
    let label_for_close = label.clone();
    popover.connect_closed(move |p| {
        p.unparent();
        POPOVER_SLOT.take(&label_for_close);
    });
}

fn install_edit_commit_handler(label: &CellEditor, col_index: usize, sender: relm4::Sender<GridMsg>) {
    {
        let text = label.entry();
        let label_for_preedit = label.clone();
        let sender_for_preedit = sender.clone();
        text.connect_preedit_changed(move |_t, preedit| {
            let active = !preedit.is_empty();
            PREEDIT_SLOT.set(&label_for_preedit, active);
            if !active && !label_for_preedit.is_editing() {
                commit_cell_edit(&label_for_preedit, col_index, &sender_for_preedit);
            }
        });
    }

    label.connect_editing_notify(move |label| {
        if label.is_editing() {
            let position = POSITION_SLOT.get(label).unwrap_or(0);
            let original = FULL_EDIT_TEXT_SLOT
                .cloned(label)
                .unwrap_or_else(|| label.text().to_string());
            let row_key = ROW_KEY_SLOT.cloned(label).unwrap_or_default();
            SNAPSHOT_SLOT.set(
                label,
                EditSnapshot {
                    position,
                    original,
                    row_key,
                },
            );
            return;
        }
        if PREEDIT_SLOT.get(label).unwrap_or(false) {
            return;
        }
        commit_cell_edit(label, col_index, &sender);
    });
}

fn commit_cell_edit(label: &CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>) {
    let Some(snap) = SNAPSHOT_SLOT.take(label) else {
        return;
    };
    let new_value = label.text().to_string();
    if new_value == snap.original {
        return;
    }
    FULL_EDIT_TEXT_SLOT.set(label, new_value.clone());
    sender
        .send(GridMsg::CellEdited {
            row_position: snap.position,
            col_index,
            new_value,
            row_key: snap.row_key,
        })
        .ok();
}

#[cfg(test)]
mod tests {
    use super::{NumericEditor, numeric_editor};

    #[test]
    fn small_integers_use_the_spin_button() {
        assert_eq!(numeric_editor("42", false), NumericEditor::Spin(42.0));
        assert_eq!(numeric_editor(" -7 ", false), NumericEditor::Spin(-7.0));
        assert_eq!(
            numeric_editor("9007199254740992", false),
            NumericEditor::Spin(9007199254740992.0)
        );
    }

    #[test]
    fn wide_integers_use_exact_text_editing() {
        assert_eq!(numeric_editor("9007199254740993", false), NumericEditor::ExactText);
        assert_eq!(numeric_editor("-9007199254740993", false), NumericEditor::ExactText);
        assert_eq!(numeric_editor("9223372036854775807", false), NumericEditor::ExactText);
        assert_eq!(
            numeric_editor("170141183460469231731687303715884105727", false),
            NumericEditor::ExactText
        );
    }

    #[test]
    fn unreadable_numbers_keep_their_text_instead_of_becoming_zero() {
        assert_eq!(numeric_editor("", false), NumericEditor::ExactText);
        assert_eq!(numeric_editor("NULL", false), NumericEditor::ExactText);
        assert_eq!(numeric_editor("1_000", false), NumericEditor::ExactText);
        assert_eq!(numeric_editor("", true), NumericEditor::ExactText);
        assert_eq!(numeric_editor("nan", true), NumericEditor::ExactText);
        assert_eq!(numeric_editor("inf", true), NumericEditor::ExactText);
    }

    #[test]
    fn floats_use_the_spin_button() {
        assert_eq!(numeric_editor("1.5", true), NumericEditor::Spin(1.5));
        assert_eq!(numeric_editor("-0.25", true), NumericEditor::Spin(-0.25));
    }
}
