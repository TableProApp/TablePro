use chrono::{Datelike, FixedOffset, Local, NaiveDate, NaiveDateTime, NaiveTime, Offset, TimeDelta, TimeZone};
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::column::{ColumnKind, TemporalZone};
use tablepro_core::edit::temporal_parts;

use super::RowDetailPane;
use super::value_editor::Commit;
use crate::application::component_matches;

// GtkCalendar shows the years 1 to 9999 only, so it opens on today for any other.
pub fn day_of(text: &str) -> Option<NaiveDate> {
    temporal_parts(text).date.filter(|day| (1..=9999).contains(&day.year()))
}

// Only the day changes, and the era with it, since a picked day is AD. Text with no day takes one
// before its clock, or becomes a new value; a new zoned timestamp starts the day at `offset`.
pub fn with_day(text: &str, day: NaiveDate, zone: Option<&TemporalZone>, offset: FixedOffset) -> String {
    let date = day.format("%Y-%m-%d").to_string();
    let parts = temporal_parts(text);
    let mut text = text.to_owned();
    if let Some(era) = parts.era {
        text.replace_range(era, "");
    }
    match (parts.day, parts.clock, zone) {
        (Some(old), _, _) => {
            text.replace_range(old, &date);
            text
        }
        (None, Some(clock), Some(_)) => {
            text.insert_str(clock.start, &format!("{date} "));
            text
        }
        (None, _, None) => date,
        (None, None, Some(TemporalZone::Offset)) => format!("{date} 00:00:00{offset}"),
        (None, None, Some(_)) => format!("{date} 00:00:00"),
    }
}

pub fn day_start_offset<Tz: TimeZone>(zone: &Tz, day: NaiveDate) -> FixedOffset {
    offset_at(zone, day.and_time(NaiveTime::MIN))
}

// A wall-clock time a clock change skips takes the offset before the change.
pub fn offset_at<Tz: TimeZone>(zone: &Tz, local: NaiveDateTime) -> FixedOffset {
    [local, local - TimeDelta::hours(1)]
        .iter()
        .find_map(|local| zone.from_local_datetime(local).earliest())
        .map_or_else(|| zone.offset_from_utc_datetime(&local).fix(), |at| at.offset().fix())
}

impl RowDetailPane {
    pub(super) fn connect_calendar(&self) {
        let imp = self.imp();
        // Dropped below a button halfway down the pane, the calendar fits
        // neither below nor above it on a short screen and GTK closes it;
        // opened toward the rows, it slides up or down to fit.
        imp.calendar_button.set_direction(self.toward_rows());
        imp.calendar_popover.connect_show(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| pane.calendar_opens()
        ));
        imp.calendar.connect_day_selected(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| {
                if !pane.imp().quiet_calendar.get() {
                    pane.pick_day();
                }
            }
        ));
        // day-selected fires only when the day changes, so a click or
        // Space on the day already selected, today on a NULL or the same
        // day after a month change, would pick nothing.
        let click = gtk::GestureClick::new();
        click.connect_released(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |gesture, _, x, y| {
                let on_a_day = gesture
                    .widget()
                    .and_then(|calendar| calendar.pick(x, y, gtk::PickFlags::DEFAULT))
                    .is_some_and(|label| label.has_css_class("day-number"));
                if on_a_day {
                    pane.pick_day();
                }
            }
        ));
        imp.calendar.add_controller(click);
        let keys = gtk::EventControllerKey::new();
        keys.connect_key_released(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_, keyval, _, state| {
                if component_matches("cell-editor.pick-date", keyval, state) {
                    pane.pick_day();
                }
            }
        ));
        imp.calendar.add_controller(keys);
    }

    pub(super) fn toward_rows(&self) -> gtk::ArrowType {
        match self.direction() {
            gtk::TextDirection::Rtl => gtk::ArrowType::Right,
            _ => gtk::ArrowType::Left,
        }
    }

    /// The calendar opens on the value's day, else on today, for the row
    /// and field shown now.
    fn calendar_opens(&self) {
        let imp = self.imp();
        imp.calendar_target.replace(self.current_pin().zip(imp.field.get()));
        let day = day_of(&self.typed_text())
            .and_then(|day| {
                let month = i32::try_from(day.month()).ok()?;
                let date = i32::try_from(day.day()).ok()?;
                glib::DateTime::from_utc(day.year(), month, date, 0, 0, 0.0).ok()
            })
            .or_else(|| glib::DateTime::now_local().ok());
        if let Some(day) = day {
            // Moving the calendar to the day is no pick.
            imp.quiet_calendar.set(true);
            imp.calendar.set_date(&day);
            imp.quiet_calendar.set(false);
        }
    }

    /// Write the picked day into the value as if typed, and commit it,
    /// while the pane still shows the row and field it opened on.
    fn pick_day(&self) {
        let imp = self.imp();
        let target = imp.calendar_target.take();
        if target.is_none() || target != self.current_pin().zip(imp.field.get()) {
            imp.calendar_popover.popdown();
            return;
        }
        if !imp.value_view.is_editable() {
            return;
        }
        let (year, month, day) = imp.calendar.date().ymd();
        let Some(day) = u32::try_from(month)
            .ok()
            .zip(u32::try_from(day).ok())
            .and_then(|(month, day)| NaiveDate::from_ymd_opt(year, month, day))
        else {
            return;
        };
        let zone = self.field_column().and_then(|column| match &column.value_type().kind {
            ColumnKind::Timestamp { zone, .. } => Some(zone.clone()),
            _ => None,
        });
        let text = with_day(&self.typed_text(), day, zone.as_ref(), day_start_offset(&Local, day));
        imp.calendar_popover.popdown();
        imp.value_buffer.set_text(&text);
        self.commit(Commit::Keep);
    }
}
