use std::ops::Range;

use chrono::{Local, NaiveDate, NaiveTime, TimeZone, Timelike};
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::column::{ColumnKind, TemporalZone, TimeRange};

use super::RowDetailPane;
use super::calendar::{day_of, offset_at};
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

// By the text's own form: SQLite keeps any date or time text in a DATE, TIME or DATETIME column.
fn clock_span(text: &str) -> Option<Range<usize>> {
    let mut start = text.len() - text.trim_start().len();
    if let Some(day) = day_len(text.as_bytes().get(start..)?) {
        let rest = text.get(start + day..)?;
        start = text.len() - rest.strip_prefix('T').unwrap_or(rest).trim_start().len();
    }
    Some(start..start + clock_len(text.as_bytes().get(start..)?)?)
}

// Each part as chrono reads it: a year of any length and sign, one or two digits for the rest.
fn day_len(bytes: &[u8]) -> Option<usize> {
    let mut at = usize::from(matches!(bytes.first(), Some(b'-' | b'+')));
    for (most, dash) in [(usize::MAX, true), (2, true), (2, false)] {
        let run = digits(bytes.get(at..)?, most);
        at += run + usize::from(dash);
        if run == 0 || (dash && bytes.get(at - 1) != Some(&b'-')) {
            return None;
        }
    }
    Some(at)
}

fn clock_len(bytes: &[u8]) -> Option<usize> {
    let part = |at: usize| bytes.get(at..).map_or(0, |rest| digits(rest, 2));
    let colon = |at: usize| bytes.get(at) == Some(&b':');
    let hour = part(0);
    let minute = part(hour + 1);
    if hour == 0 || !colon(hour) || minute == 0 {
        return None;
    }
    let end = hour + 1 + minute;
    let second = part(end + 1);
    Some(if colon(end) && second > 0 {
        end + 1 + second
    } else {
        end
    })
}

fn digits(bytes: &[u8], most: usize) -> usize {
    bytes.iter().take(most).take_while(|byte| byte.is_ascii_digit()).count()
}

pub fn time_of(text: &str) -> Option<NaiveTime> {
    let mut parts = text.get(clock_span(text)?)?.split(':').map(str::parse::<u32>);
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
    let lead = text.len() - text.trim_start().len();
    let day_end = text.as_bytes().get(lead..).and_then(day_len).map(|len| lead + len);
    let day = day_end.and_then(|end| day_of(text.get(lead..end)?)).unwrap_or(today);
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
