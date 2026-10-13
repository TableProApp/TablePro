use chrono::Datelike;
use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use sourceview5::prelude::*;

use super::display_text::truncate_for_display;
use super::{GridCell, GridMsg, GridSink};

fn current_text(cell: &GridCell) -> String {
    cell.edit_text().unwrap_or_default()
}

/// Parent the popover to the cell and keep it there until it closes.
fn present(cell: &GridCell, popover: &gtk::Popover) {
    popover.set_parent(cell);
    cell.set_popover(popover);
    // The cell holds the popover in its slot and as its child, so the
    // popover holds the cell weakly and itself not at all.
    let cell_for_close = cell.downgrade();
    popover.connect_closed(move |popover| {
        popover.unparent();
        if let Some(cell) = cell_for_close.upgrade() {
            cell.release_popover(popover);
        }
    });
    popover.popup();
}

/// The popover is closed before the tab hears of the value, so an edit
/// the tab redraws the row for never meets an open popover.
fn commit(cell: &GridCell, popover: &gtk::Popover, input: String, sink: &GridSink) {
    // Drawn now rather than after the tracker's round trip.
    if let Some(editor) = cell.editor() {
        editor.set_text(&truncate_for_display(&input));
    }
    let row = cell.row();
    popover.popdown();
    if let Some(row) = row {
        sink(GridMsg::CellEdited {
            row,
            column: cell.column(),
            input,
        });
    }
}

pub(super) fn show_calendar_popover(cell: &GridCell, sink: &GridSink) {
    let calendar = gtk::Calendar::new();
    if let Ok(parsed) = chrono::NaiveDate::parse_from_str(&current_text(cell), "%Y-%m-%d")
        && let Ok(dt) = glib::DateTime::from_local(parsed.year(), parsed.month() as i32, parsed.day() as i32, 0, 0, 0.0)
    {
        calendar.set_date(&dt);
    }

    let popover = gtk::Popover::builder().child(&calendar).build();
    let cell_for_cal = cell.downgrade();
    let popover_for_cal = popover.downgrade();
    let sink = sink.clone();
    calendar.connect_day_selected(move |c| {
        let (Some(cell), Some(popover)) = (cell_for_cal.upgrade(), popover_for_cal.upgrade()) else {
            return;
        };
        let dt = c.date();
        let formatted = format!("{:04}-{:02}-{:02}", dt.year(), dt.month(), dt.day_of_month());
        commit(&cell, &popover, formatted, &sink);
    });
    present(cell, &popover);
}

pub(super) fn show_spin_button_popover(cell: &GridCell, sink: &GridSink, is_float: bool) {
    let current_text = current_text(cell);
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
    let cell_for_commit = cell.downgrade();
    let popover_for_commit = popover.downgrade();
    let sink = sink.clone();
    spin.connect_activate(move |s| {
        let (Some(cell), Some(popover)) = (cell_for_commit.upgrade(), popover_for_commit.upgrade()) else {
            return;
        };
        // f64's Display claims no more precision than the value has.
        let formatted = if is_float {
            format!("{}", s.value())
        } else {
            format!("{}", s.value() as i64)
        };
        commit(&cell, &popover, formatted, &sink);
    });
    present(cell, &popover);
    spin.grab_focus();
}

pub(super) fn show_json_popover(cell: &GridCell, sink: &GridSink) {
    let buffer = sourceview5::Buffer::new(None);
    if let Some(lang) = sourceview5::LanguageManager::default().language("json") {
        buffer.set_language(Some(&lang));
    }
    buffer.set_text(&current_text(cell));

    let view = sourceview5::View::with_buffer(&buffer);
    view.set_show_line_numbers(true);
    view.set_monospace(true);
    view.set_auto_indent(true);
    view.set_tab_width(2);
    view.set_indent_width(2);
    show_buffer_popover(cell, sink, &view);
}

/// For a text the one-line editor cannot lay out without stalling.
pub(super) fn show_long_text_popover(cell: &GridCell, sink: &GridSink, text: &str) {
    let buffer = sourceview5::Buffer::new(None);
    buffer.set_text(text);
    let view = sourceview5::View::with_buffer(&buffer);
    view.set_wrap_mode(gtk::WrapMode::WordChar);
    show_buffer_popover(cell, sink, &view);
}

/// Saves through a button, since Return inserts a newline in a
/// multi-line buffer.
fn show_buffer_popover(cell: &GridCell, sink: &GridSink, view: &sourceview5::View) {
    let buffer = view.buffer();

    let scrolled = gtk::ScrolledWindow::builder()
        .child(view)
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

    let popover_for_cancel = popover.downgrade();
    cancel_button.connect_clicked(move |_| {
        if let Some(popover) = popover_for_cancel.upgrade() {
            popover.popdown();
        }
    });

    let cell_for_commit = cell.downgrade();
    let popover_for_commit = popover.downgrade();
    let sink = sink.clone();
    let buffer_for_commit = buffer.clone();
    save_button.connect_clicked(move |_| {
        let (Some(cell), Some(popover)) = (cell_for_commit.upgrade(), popover_for_commit.upgrade()) else {
            return;
        };
        let start = buffer_for_commit.start_iter();
        let end = buffer_for_commit.end_iter();
        let text = buffer_for_commit.text(&start, &end, true).to_string();
        // The tab parses the text for its column and refuses, with a
        // toast, a value the column cannot take.
        commit(&cell, &popover, text, &sink);
    });

    present(cell, &popover);
    view.grab_focus();
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use gtk4::{self as gtk, glib};

    use super::{show_calendar_popover, show_json_popover, show_spin_button_popover};
    use crate::ui::grid::{CellEditor, GridCell, GridSink};

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
    fn open_popover(editor: PopoverEditor, cell: &GridCell, sink: &GridSink) -> Option<gtk::Popover> {
        for _ in 0..5 {
            match editor {
                PopoverEditor::Date => show_calendar_popover(cell, sink),
                PopoverEditor::Int => show_spin_button_popover(cell, sink, false),
                PopoverEditor::Json => show_json_popover(cell, sink),
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
            cell.take_popover();
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
            let sink: GridSink = std::rc::Rc::new(|_| {});
            let cell = GridCell::new();
            let text = CellEditor::new();
            text.set_text("x");
            cell.set_content(&text);
            window.set_child(Some(&cell));
            wait_until(timeout, || cell.is_mapped()).expect("the cell is drawn");
            let popover = open_popover(editor, &cell, &sink).expect("the editor popover opens");

            commit_popover(editor, &popover);
            wait_until(timeout, || popover.parent().is_none()).expect("the popover closes");
            assert_ne!(text.text(), "x", "{editor:?} did not commit");
            assert!(!cell.is_editing(), "{editor:?} left its popover in the cell");
            // Only the cell is checked: GTK itself keeps a closed autohide
            // popover alive once a child of it has taken focus.
            let freed = cell.downgrade();
            window.set_child(None::<&gtk::Widget>);
            drop((cell, text, popover));
            crate::test_support::drain_main_context();

            assert!(freed.upgrade().is_none(), "{editor:?} kept its cell alive");
        }
        window.destroy();
    }
}
