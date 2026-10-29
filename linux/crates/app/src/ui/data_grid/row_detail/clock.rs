use chrono::{FixedOffset, Local, NaiveDate, NaiveTime, Offset, Timelike};
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::column::{ColumnKind, TemporalZone, TimeRange};

use super::RowDetailPane;
use super::calendar::{day_of, day_start_offset};
use super::value_editor::Commit;

/// `HH:MM:SS`, the part of a value's text the clock sets.
const CLOCK_LEN: usize = 8;
/// Where the time starts in a timestamp's text: after `YYYY-MM-DD `.
const TIMESTAMP_TIME_AT: usize = 11;

/// What the clock edits in a column's text.
#[derive(Debug, Clone, PartialEq)]
pub enum ClockField {
    /// A time of day, with an offset after it when `with_offset`.
    Time { with_offset: bool },
    /// The time of a timestamp, after its day.
    Timestamp { zone: TemporalZone },
}

impl ClockField {
    /// A time of day or a timestamp. A duration such as MySQL's TIME,
    /// which runs past 24 hours, is typed.
    pub fn of(kind: &ColumnKind) -> Option<Self> {
        match kind {
            ColumnKind::Time {
                with_offset,
                range: TimeRange::TimeOfDay,
                ..
            } => Some(Self::Time {
                with_offset: *with_offset,
            }),
            ColumnKind::Timestamp { zone, .. } => Some(Self::Timestamp { zone: zone.clone() }),
            _ => None,
        }
    }

    fn time_at(&self) -> usize {
        match self {
            Self::Time { .. } => 0,
            Self::Timestamp { .. } => TIMESTAMP_TIME_AT,
        }
    }
}

/// The time a value's text holds, to the second.
pub fn time_of(text: &str, field: &ClockField) -> Option<NaiveTime> {
    let at = field.time_at();
    if matches!(field, ClockField::Timestamp { .. }) && day_of(text).is_none() {
        return None;
    }
    let clock = text.get(at..at + CLOCK_LEN)?;
    NaiveTime::parse_from_str(clock, "%H:%M:%S").ok()
}

/// The value's text with its time set to `time`, keeping its day, its
/// fraction of a second and its offset. A value with no time yet takes
/// `today` for a timestamp's day, and `offset` where the column needs
/// one.
pub fn with_time(text: &str, time: NaiveTime, field: &ClockField, today: NaiveDate, offset: FixedOffset) -> String {
    let clock = time.format("%H:%M:%S").to_string();
    let at = field.time_at();
    if time_of(text, field).is_some() {
        let (head, rest) = text.split_at(at);
        return format!("{head}{clock}{}", &rest[CLOCK_LEN..]);
    }
    match field {
        ClockField::Time { with_offset: true } => format!("{clock}{offset}"),
        ClockField::Time { with_offset: false } => clock,
        ClockField::Timestamp { zone } => {
            let day = day_of(text).unwrap_or(today).format("%Y-%m-%d");
            match zone {
                TemporalZone::Offset => format!("{day} {clock}{offset}"),
                _ => format!("{day} {clock}"),
            }
        }
    }
}

impl RowDetailPane {
    pub(super) fn connect_clock(&self) {
        let imp = self.imp();
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
        // Enter in a field sets the time, as Set does.
        for spin in [&imp.hour.get(), &imp.minute.get(), &imp.second.get()] {
            spin.connect_activate(glib::clone!(
                #[weak(rename_to = pane)]
                self,
                move |spin| {
                    spin.update();
                    pane.pick_time();
                }
            ));
        }
    }

    fn clock_field(&self) -> Option<ClockField> {
        self.field_column()
            .and_then(|column| ClockField::of(&column.value_type().kind))
    }

    /// The clock opens on the value's time, else on now, for the row and
    /// field shown now.
    fn clock_opens(&self) {
        let imp = self.imp();
        imp.clock_target.replace(self.current_pin().zip(imp.field.get()));
        let time = self
            .clock_field()
            .and_then(|field| time_of(&self.typed_text(), &field))
            .unwrap_or_else(|| Local::now().time());
        imp.hour.set_value(f64::from(time.hour()));
        imp.minute.set_value(f64::from(time.minute()));
        imp.second.set_value(f64::from(time.second()));
        imp.hour.grab_focus();
    }

    /// Write the time into the value as if typed, and commit it, while
    /// the pane still shows the row and field it opened on.
    fn pick_time(&self) {
        let imp = self.imp();
        let target = imp.clock_target.take();
        if target.is_none() || target != self.current_pin().zip(imp.field.get()) {
            imp.clock_popover.popdown();
            return;
        }
        let Some(field) = self.clock_field().filter(|_| imp.value_view.is_editable()) else {
            return;
        };
        let part = |spin: &gtk4::SpinButton| u32::try_from(spin.value_as_int()).unwrap_or(0);
        let Some(time) = NaiveTime::from_hms_opt(part(&imp.hour), part(&imp.minute), part(&imp.second)) else {
            return;
        };
        let today = Local::now().date_naive();
        let offset = match &field {
            ClockField::Timestamp { .. } => day_start_offset(&Local, today),
            ClockField::Time { .. } => Local::now().offset().fix(),
        };
        let text = with_time(&self.typed_text(), time, &field, today, offset);
        imp.clock_popover.popdown();
        imp.value_buffer.set_text(&text);
        self.commit(Commit::Keep);
    }
}

#[cfg(test)]
mod tests {
    use chrono::{FixedOffset, NaiveDate, NaiveTime};
    use tablepro_core::column::{ColumnKind, TemporalZone, TimeRange};

    use super::{ClockField, time_of, with_time};

    fn at(h: u32, m: u32, s: u32) -> NaiveTime {
        NaiveTime::from_hms_opt(h, m, s).expect("a time")
    }

    fn today() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, 29).expect("a day")
    }

    fn plus_two() -> FixedOffset {
        FixedOffset::east_opt(2 * 3600).expect("an offset")
    }

    const LOCAL: ClockField = ClockField::Timestamp {
        zone: TemporalZone::Naive,
    };

    #[test]
    fn a_timestamp_keeps_its_day_fraction_and_offset() {
        let zoned = ClockField::Timestamp {
            zone: TemporalZone::Offset,
        };
        let set = |text: &str, field: &ClockField| with_time(text, at(9, 5, 0), field, today(), plus_two());

        assert_eq!(set("2024-02-29 23:59:58", &LOCAL), "2024-02-29 09:05:00");
        assert_eq!(set("2024-02-29 23:59:58.125", &LOCAL), "2024-02-29 09:05:00.125");
        assert_eq!(set("2024-02-29 23:59:58+05:30", &zoned), "2024-02-29 09:05:00+05:30");
        assert_eq!(time_of("2024-02-29 23:59:58.125", &LOCAL), Some(at(23, 59, 58)));
    }

    #[test]
    fn a_value_with_no_time_takes_today_and_the_offset_it_needs() {
        let zoned = ClockField::Timestamp {
            zone: TemporalZone::Offset,
        };
        let set = |text: &str, field: &ClockField| with_time(text, at(9, 5, 0), field, today(), plus_two());

        assert_eq!(set("", &LOCAL), "2026-10-29 09:05:00");
        assert_eq!(set("", &zoned), "2026-10-29 09:05:00+02:00");
        assert_eq!(
            set("2024-02-29", &LOCAL),
            "2024-02-29 09:05:00",
            "a day with no time keeps it"
        );
        assert_eq!(set("", &ClockField::Time { with_offset: false }), "09:05:00");
        assert_eq!(set("", &ClockField::Time { with_offset: true }), "09:05:00+02:00");
    }

    #[test]
    fn a_time_keeps_its_fraction_and_offset() {
        let field = ClockField::Time { with_offset: true };

        assert_eq!(
            with_time("13:45:07.5+01", at(8, 0, 0), &field, today(), plus_two()),
            "08:00:00.5+01"
        );
        assert_eq!(time_of("13:45:07.5+01", &field), Some(at(13, 45, 7)));
        assert_eq!(time_of("not a time", &field), None);
    }

    #[test]
    fn only_a_time_of_day_and_a_timestamp_get_the_clock() {
        let time = |range| ColumnKind::Time {
            fractional_digits: None,
            with_offset: false,
            range,
        };

        assert!(ClockField::of(&time(TimeRange::TimeOfDay)).is_some());
        assert!(
            ClockField::of(&time(TimeRange::Duration)).is_none(),
            "MySQL TIME runs past a day"
        );
        assert!(ClockField::of(&ColumnKind::Date).is_none());
    }
}
