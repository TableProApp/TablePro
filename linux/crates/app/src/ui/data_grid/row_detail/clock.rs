use std::ops::Range;

use chrono::{Local, NaiveDate, NaiveTime, TimeZone, Timelike};
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::column::{ColumnKind, TemporalZone, TimeRange};

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

// By the text's own form, as chrono reads it for the commit: SQLite keeps any date or time text in a
// DATE, TIME or DATETIME column, and chrono takes whitespace before a number and one digit for two.
fn clock_span(text: &str) -> Option<Range<usize>> {
    let after_day = day_len(text).map_or(0, |day| day + usize::from(text.as_bytes().get(day) == Some(&b'T')));
    let start = after_day + spaces(text.get(after_day..)?);
    let minute = number(text, literal(text, number(text, start, 2)?, b':')?, 2)?;
    let end = literal(text, minute, b':').and_then(|second| number(text, second, 2));
    Some(start..end.unwrap_or(minute))
}

// A year may run past 9999, as PostgreSQL writes one, and carry a sign.
fn day_len(text: &str) -> Option<usize> {
    let lead = spaces(text);
    let year = lead + usize::from(matches!(text.as_bytes().get(lead), Some(b'-' | b'+')));
    let month = number(text, literal(text, number(text, year, usize::MAX)?, b'-')?, 2)?;
    number(text, literal(text, month, b'-')?, 2)
}

// The end of the number at `at`, past any whitespace before it.
fn number(text: &str, at: usize, most: usize) -> Option<usize> {
    let start = at + spaces(text.get(at..)?);
    let run = text
        .get(start..)?
        .bytes()
        .take(most)
        .take_while(u8::is_ascii_digit)
        .count();
    (run > 0).then_some(start + run)
}

fn literal(text: &str, at: usize, byte: u8) -> Option<usize> {
    (text.as_bytes().get(at) == Some(&byte)).then_some(at + 1)
}

fn spaces(text: &str) -> usize {
    text.len() - text.trim_start().len()
}

pub fn time_of(text: &str) -> Option<NaiveTime> {
    let mut parts = text
        .get(clock_span(text)?)?
        .split(':')
        .map(|part| part.trim().parse::<u32>());
    let (hour, minute) = (parts.next()?.ok()?, parts.next()?.ok()?);
    let second = parts.next().transpose().ok()?.unwrap_or(0);
    NaiveTime::from_hms_opt(hour, minute, second)
}

// Only the clock changes; text with no day or clock, such as NULL or infinity, becomes a new value.
pub fn with_time<Tz: TimeZone>(text: &str, time: NaiveTime, field: ClockField, today: NaiveDate, zone: &Tz) -> String {
    let mut clock = time.format("%H:%M:%S").to_string();
    let mut text = text.to_owned();
    if let Some(span) = clock_span(&text) {
        text.replace_range(span, &clock);
        return text;
    }
    let day_end = day_len(&text);
    let day = day_end
        .and_then(|end| NaiveDate::parse_from_str(text.get(..end)?.trim_start(), "%Y-%m-%d").ok())
        .unwrap_or(today);
    if field.with_offset {
        clock.push_str(&offset_at(zone, day.and_time(time)).to_string());
    }
    match day_end {
        Some(end) => {
            text.insert_str(end, &format!(" {clock}"));
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
