use chrono::Datelike;
use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::edit::CellInput;
use tablepro_core::value::Temporal;
use tablepro_core::{ColumnInfo, Value};

use super::edit_commit::{commit_edit, send_commit};
use super::inline_editor::{InlineEditor, InlineOptions};
use super::{EditSnapshot, GridCell};

/// The day a calendar opens on.
#[derive(Debug, Clone)]
enum CalendarStart {
    On(glib::DateTime),
    /// A NULL the column may keep: the calendar shows today and commits
    /// nothing until a day is picked.
    Today,
}

/// A date column's editor: a calendar for a day it can show, and the
/// one-line field for anything else, such as an infinity.
pub struct CalendarEditor;

impl CalendarEditor {
    /// `text` is the cell's edit text, for the one-line field.
    pub(super) fn open(
        cell: &GridCell,
        snapshot: EditSnapshot,
        column: &ColumnInfo,
        text: String,
        inline: InlineOptions,
    ) {
        let Some(start) = calendar_start(&snapshot.original, column) else {
            InlineEditor::begin(cell, snapshot, &text, inline);
            return;
        };
        cell.cancel_edit();
        let calendar = gtk::Calendar::new();
        // Before the handler: set_date emits day-selected when the day
        // changes, and that is not a pick.
        if let CalendarStart::On(date) = &start {
            calendar.set_date(date);
        }
        let type_value = gtk::Button::with_label(&crate::i18n::gettext("Type a Value"));
        type_value.add_css_class("flat");
        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(6)
            .build();
        content.append(&calendar);
        content.append(&type_value);
        let popover = gtk::Popover::builder().child(&content).build();

        let weak_cell = cell.downgrade();
        calendar.connect_day_selected(move |calendar| {
            let Some(cell) = weak_cell.upgrade() else {
                return;
            };
            let (year, month, day) = calendar.date().ymd();
            pick(&cell, &format!("{year:04}-{month:02}-{day:02}"));
        });
        let weak_cell = cell.downgrade();
        type_value.connect_clicked(move |_| {
            let Some(cell) = weak_cell.upgrade() else {
                return;
            };
            let Some(snapshot) = cell.take_edit() else {
                return;
            };
            if let Some(popover) = cell.take_popover() {
                popover.popdown();
            }
            InlineEditor::begin(&cell, snapshot, &text, inline.clone());
        });

        cell.begin_edit(snapshot);
        cell.present_popover(&popover);
        calendar.grab_focus();
    }
}

/// The popover closes before the tab hears of the day, as every editor's
/// does.
fn pick(cell: &GridCell, day: &str) {
    let Some(snapshot) = cell.take_edit() else {
        return;
    };
    if let Some(popover) = cell.take_popover() {
        popover.popdown();
    }
    let Some(drawing) = cell.drawing() else {
        return;
    };
    let Some(column) = drawing.catalog.as_ref() else {
        return;
    };
    let result = commit_edit(column, &snapshot, day);
    send_commit(cell, snapshot, result);
}

/// `None` for a value the calendar cannot show: an infinity, a year
/// outside 1 to 9999, the server's default or a NULL the column refuses.
fn calendar_start(input: &CellInput, column: &ColumnInfo) -> Option<CalendarStart> {
    match input {
        CellInput::Value(Value::Date(Temporal::Finite(date))) if (1..=9999).contains(&date.year()) => {
            let month = i32::try_from(date.month()).ok()?;
            let day = i32::try_from(date.day()).ok()?;
            glib::DateTime::from_utc(date.year(), month, day, 0, 0, 0.0)
                .ok()
                .map(CalendarStart::On)
        }
        CellInput::Value(Value::Null) if column.nullable => Some(CalendarStart::Today),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use chrono::NaiveDate;
    use tablepro_core::column::{ColumnDefault, ColumnKind, ColumnType};
    use tablepro_core::edit::CellInput;
    use tablepro_core::value::Temporal;
    use tablepro_core::{ColumnInfo, Value};

    use super::{CalendarStart, calendar_start};

    fn date_column(nullable: bool) -> ColumnInfo {
        let mut column_type = ColumnType::untyped_text("date");
        column_type.kind = ColumnKind::Date;
        ColumnInfo {
            name: "day".to_owned(),
            column_type,
            nullable,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn date(year: i32, month: u32, day: u32) -> CellInput {
        CellInput::Value(Value::Date(Temporal::Finite(
            NaiveDate::from_ymd_opt(year, month, day).expect("a date"),
        )))
    }

    #[test]
    fn the_calendar_opens_only_on_a_day_it_can_show() {
        let nullable = date_column(true);

        let Some(CalendarStart::On(start)) = calendar_start(&date(2026, 9, 15), &nullable) else {
            panic!("a date did not open the calendar on its day");
        };
        assert_eq!(start.ymd(), (2026, 9, 15));
        assert!(matches!(
            calendar_start(&CellInput::Value(Value::Null), &nullable),
            Some(CalendarStart::Today)
        ));
        assert!(calendar_start(&CellInput::Value(Value::Null), &date_column(false)).is_none());
        assert!(calendar_start(&CellInput::Default, &nullable).is_none());
        assert!(calendar_start(&date(12_000, 1, 1), &nullable).is_none());
        assert!(calendar_start(&CellInput::Value(Value::Date(Temporal::Infinity)), &nullable).is_none());
    }
}
