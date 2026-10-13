use chrono::Datelike;
use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use sourceview5::prelude::*;

use super::GridMsg;
use super::cell_editor::CellEditor;
use super::widget_slot::{POPOVER_SLOT, POSITION_SLOT};

pub(super) fn show_calendar_popover(label: &CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>) {
    let calendar = gtk::Calendar::new();
    if let Ok(parsed) = chrono::NaiveDate::parse_from_str(label.text().as_str(), "%Y-%m-%d")
        && let Ok(dt) = glib::DateTime::from_local(parsed.year(), parsed.month() as i32, parsed.day() as i32, 0, 0, 0.0)
    {
        calendar.set_date(&dt);
    }

    let popover = gtk::Popover::builder().child(&calendar).build();
    popover.set_parent(label);
    POPOVER_SLOT.set(label, popover.clone());

    let label_for_cal = label.downgrade();
    let popover_for_cal = popover.downgrade();
    let sender_for_cal = sender.clone();
    calendar.connect_day_selected(move |c| {
        let (Some(label_for_cal), Some(popover_for_cal)) = (label_for_cal.upgrade(), popover_for_cal.upgrade()) else {
            return;
        };
        let dt = c.date();
        let formatted = format!("{:04}-{:02}-{:02}", dt.year(), dt.month(), dt.day_of_month());
        let position = POSITION_SLOT.get(&label_for_cal).unwrap_or(0);
        // Drawn now rather than after the tracker's round trip.
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

pub(super) fn show_spin_button_popover(
    label: &CellEditor,
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

    let label_for_commit = label.downgrade();
    let popover_for_commit = popover.downgrade();
    let sender_for_commit = sender.clone();
    spin.connect_activate(move |s| {
        let (Some(label_for_commit), Some(popover_for_commit)) =
            (label_for_commit.upgrade(), popover_for_commit.upgrade())
        else {
            return;
        };
        // f64's Display claims no more precision than the value has.
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

/// Saves through a button, since Return inserts a newline in a
/// multi-line buffer.
pub(super) fn show_json_popover(label: &CellEditor, col_index: usize, sender: &relm4::Sender<GridMsg>) {
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

    let save_button = gtk::Button::with_label(&crate::i18n::gettext("Save"));
    save_button.add_css_class("suggested-action");

    let cancel_button = gtk::Button::with_label(&crate::i18n::gettext("Cancel"));

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

    let popover_for_cancel = popover.downgrade();
    cancel_button.connect_clicked(move |_| {
        if let Some(popover) = popover_for_cancel.upgrade() {
            popover.popdown();
        }
    });

    let label_for_commit = label.downgrade();
    let popover_for_commit = popover.downgrade();
    let sender_for_commit = sender.clone();
    let buffer_for_commit = buffer.clone();
    save_button.connect_clicked(move |_| {
        let (Some(label_for_commit), Some(popover_for_commit)) =
            (label_for_commit.upgrade(), popover_for_commit.upgrade())
        else {
            return;
        };
        let start = buffer_for_commit.start_iter();
        let end = buffer_for_commit.end_iter();
        let text = buffer_for_commit.text(&start, &end, true).to_string();
        let position = POSITION_SLOT.get(&label_for_commit).unwrap_or(0);
        // The tab validates the JSON and refuses a malformed value with
        // a toast.
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

fn install_popover_close_cleanup(label: &CellEditor, popover: &gtk::Popover) {
    // The cell holds the popover in its slot and as its child, so the
    // popover holds the cell weakly and itself not at all.
    let label_for_close = label.downgrade();
    popover.connect_closed(move |p| {
        p.unparent();
        if let Some(label) = label_for_close.upgrade() {
            POPOVER_SLOT.take(&label);
        }
    });
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use gtk4::{self as gtk, glib};

    use super::{
        CellEditor, GridMsg, POPOVER_SLOT, show_calendar_popover, show_json_popover, show_spin_button_popover,
    };

    #[gtk4::test]
    fn calendar_selects_cell_date() {
        let calendar = gtk::Calendar::new();
        let date = glib::DateTime::from_local(2026, 9, 15, 0, 0, 0.0).unwrap();

        calendar.set_date(&date);

        assert_eq!(calendar.date().year(), 2026);
        assert_eq!(calendar.date().month(), 9);
        assert_eq!(calendar.date().day_of_month(), 15);
    }

    #[derive(Clone, Copy, Debug)]
    enum PopoverEditor {
        Date,
        Int,
        Json,
    }

    /// Commit through the editor's own control, which also closes it.
    fn commit_popover(editor: PopoverEditor, popover: &gtk::Popover) {
        use crate::test_support::first_descendant_of_type;
        match editor {
            PopoverEditor::Date => first_descendant_of_type::<gtk::Calendar>(popover)
                .expect("the calendar")
                .emit_by_name::<()>("day-selected", &[]),
            PopoverEditor::Int => {
                let spin = first_descendant_of_type::<gtk::SpinButton>(popover).expect("the spin button");
                spin.set_value(42.0);
                spin.emit_by_name::<()>("activate", &[]);
            }
            PopoverEditor::Json => {
                first_descendant_of_type::<sourceview5::View>(popover)
                    .expect("the JSON view")
                    .buffer()
                    .set_text("[1]");
                crate::test_support::descendants(popover)
                    .into_iter()
                    .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
                    .find(|button| button.has_css_class("suggested-action"))
                    .expect("the Save button")
                    .emit_clicked();
            }
        }
    }

    /// Another test's window can take the focus and close an autohide
    /// popover before it opens, so a dismissed one is shown again.
    fn open_popover(editor: PopoverEditor, cell: &CellEditor, sender: &relm4::Sender<GridMsg>) -> Option<gtk::Popover> {
        for _ in 0..5 {
            match editor {
                PopoverEditor::Date => show_calendar_popover(cell, 0, sender),
                PopoverEditor::Int => show_spin_button_popover(cell, 0, sender, false),
                PopoverEditor::Json => show_json_popover(cell, 0, sender),
            }
            let popover = crate::test_support::first_descendant_of_type::<gtk::Popover>(cell)?;
            let settled = crate::test_support::wait_until(std::time::Duration::from_secs(5), || {
                popover.is_mapped() || !popover.is_visible()
            });
            if settled.is_ok() && popover.is_mapped() {
                return Some(popover);
            }
            if popover.parent().is_some() {
                popover.unparent();
            }
            POPOVER_SLOT.take(cell);
        }
        None
    }

    #[gtk4::test]
    fn a_closed_popover_editor_frees_its_cell() {
        use crate::test_support::wait_until;
        let timeout = std::time::Duration::from_secs(5);
        let window = gtk::Window::new();
        window.present();
        for editor in [PopoverEditor::Date, PopoverEditor::Int, PopoverEditor::Json] {
            let (sender, _receiver) = relm4::channel::<GridMsg>();
            let cell = CellEditor::new();
            cell.set_text("x");
            window.set_child(Some(&cell));
            wait_until(timeout, || cell.is_mapped()).expect("the cell is drawn");
            let popover = open_popover(editor, &cell, &sender).expect("the editor popover opens");

            commit_popover(editor, &popover);
            wait_until(timeout, || popover.parent().is_none()).expect("the popover closes");
            assert_ne!(cell.text(), "x", "{editor:?} did not commit");
            assert!(
                POPOVER_SLOT.take(&cell).is_none(),
                "{editor:?} left its popover in the cell"
            );
            // Only the cell is checked: GTK itself keeps a closed autohide
            // popover alive once a child of it has taken focus.
            let freed = cell.downgrade();
            window.set_child(None::<&gtk::Widget>);
            drop((cell, popover));
            crate::test_support::drain_main_context();

            assert!(freed.upgrade().is_none(), "{editor:?} kept its cell alive");
        }
        window.destroy();
    }
}
