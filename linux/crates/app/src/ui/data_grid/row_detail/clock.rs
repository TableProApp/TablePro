use chrono::{Local, NaiveDate, NaiveTime, TimeZone, Timelike};
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::column::{ColumnKind, TemporalZone, TimeRange};
use tablepro_core::edit::temporal_parts;

use super::RowDetailPane;
use super::calendar::offset_at;
use super::value_editor::Commit;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClockField {
    pub dated: bool,
    pub with_offset: bool,
}

impl ClockField {
    // A duration such as MySQL's TIME runs past a day, so it gets no clock.
    pub fn of(kind: &ColumnKind) -> Option<Self> {
        match kind {
            ColumnKind::Time {
                with_offset,
                range: TimeRange::TimeOfDay,
                ..
            } => Some(Self {
                dated: false,
                with_offset: *with_offset,
            }),
            ColumnKind::Timestamp { zone, .. } => Some(Self {
                dated: true,
                with_offset: *zone == TemporalZone::Offset,
            }),
            _ => None,
        }
    }
}

pub fn time_of(text: &str) -> Option<NaiveTime> {
    temporal_parts(text).time
}

// Only the clock changes; text with no day or clock, such as NULL or infinity, becomes a new value.
pub fn with_time<Tz: TimeZone>(text: &str, time: NaiveTime, field: ClockField, today: NaiveDate, zone: &Tz) -> String {
    let mut clock = time.format("%H:%M:%S").to_string();
    let parts = temporal_parts(text);
    let mut text = text.to_owned();
    if let Some(span) = parts.clock {
        text.replace_range(span, &clock);
        return text;
    }
    if field.with_offset {
        let day = parts.date.unwrap_or(today);
        clock.push_str(&offset_at(zone, day.and_time(time)).to_string());
    }
    match parts.day {
        Some(day) => {
            text.insert_str(day.end, &format!(" {clock}"));
            text
        }
        None if field.dated => format!("{} {clock}", today.format("%Y-%m-%d")),
        None => clock,
    }
}

impl RowDetailPane {
    pub(super) fn connect_clock(&self) {
        let imp = self.imp();
        // Centred below a button at the window's edge, the clock would run past it.
        imp.clock_button.set_direction(self.toward_rows());
        imp.clock_popover.connect_show(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| pane.clock_opens()
        ));
        imp.clock_set.connect_clicked(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| pane.pick_time()
        ));
        for spin in [imp.hour.get(), imp.minute.get(), imp.second.get()] {
            spin.connect_output(|spin| {
                spin.set_text(&format!("{:02}", spin.value_as_int()));
                glib::Propagation::Stop
            });
        }
    }

    fn clock_field(&self) -> Option<ClockField> {
        self.field_column()
            .and_then(|column| ClockField::of(&column.value_type().kind))
    }

    fn clock_opens(&self) {
        let imp = self.imp();
        imp.clock_target.replace(self.current_pin().zip(imp.field.get()));
        let time = time_of(&self.typed_text()).unwrap_or_else(|| Local::now().time());
        imp.hour.set_value(f64::from(time.hour()));
        imp.minute.set_value(f64::from(time.minute()));
        imp.second.set_value(f64::from(time.second()));
    }

    // Written as if typed, and only into the row and field the clock opened on.
    fn pick_time(&self) {
        let imp = self.imp();
        let target = imp.clock_target.take();
        imp.clock_popover.popdown();
        if target.is_none() || target != self.current_pin().zip(imp.field.get()) || !imp.value_view.is_editable() {
            return;
        }
        let part = |spin: &gtk::SpinButton| u32::try_from(spin.value_as_int()).ok();
        let (Some(field), Some(time)) = (
            self.clock_field(),
            part(&imp.hour)
                .zip(part(&imp.minute))
                .zip(part(&imp.second))
                .and_then(|((hour, minute), second)| NaiveTime::from_hms_opt(hour, minute, second)),
        ) else {
            return;
        };
        let text = with_time(&self.typed_text(), time, field, Local::now().date_naive(), &Local);
        imp.value_buffer.set_text(&text);
        self.commit(Commit::Keep);
    }
}
