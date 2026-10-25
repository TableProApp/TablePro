use chrono::{Datelike, FixedOffset, Local, NaiveDate, NaiveTime, Offset, TimeDelta, TimeZone};
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::column::{ColumnKind, TemporalZone};

use super::RowDetailPane;
use super::value_editor::Commit;
use crate::application::component_matches;

/// The day a value's text starts with, when it starts with one the
/// calendar can show.
pub fn day_of(text: &str) -> Option<NaiveDate> {
    let head = text.get(..10)?;
    NaiveDate::parse_from_str(head, "%Y-%m-%d")
        .ok()
        .filter(|day| (1..=9999).contains(&day.year()))
}

/// The value's text with `day` picked: a date, or a timestamp in `zone`,
/// which keeps the time it had. A new zoned timestamp starts the day at
/// `offset`, as one without an offset is refused.
pub fn with_day(text: &str, day: NaiveDate, zone: Option<&TemporalZone>, offset: FixedOffset) -> String {
    let date = day.format("%Y-%m-%d").to_string();
    match (zone, day_of(text)) {
        (None, _) => date,
        (Some(_), Some(_)) => format!("{date}{}", text.get(10..).unwrap_or_default()),
        (Some(TemporalZone::Offset), None) => format!("{date} 00:00:00{offset}"),
        (Some(_), None) => format!("{date} 00:00:00"),
    }
}

/// The offset `zone` has as `day` starts. Where a clock change skips
/// midnight, the day starts at the change, which is midnight at the
/// offset before it.
pub fn day_start_offset<Tz: TimeZone>(zone: &Tz, day: NaiveDate) -> FixedOffset {
    let midnight = day.and_time(NaiveTime::MIN);
    [midnight, midnight - TimeDelta::hours(1)]
        .iter()
        .find_map(|local| zone.from_local_datetime(local).earliest())
        .map_or_else(
            || zone.offset_from_utc_datetime(&midnight).fix(),
            |at| at.offset().fix(),
        )
}

impl RowDetailPane {
    pub(super) fn connect_calendar(&self) {
        let imp = self.imp();
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
