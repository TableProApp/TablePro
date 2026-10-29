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
    let lead = text.len() - text.trim_start().len();
    let start = match day_len(text.get(lead..)?) {
        Some(day) => {
            let rest = text.get(lead + day..)?;
            let gap = match rest.strip_prefix('T') {
                Some(_) => 1,
                None => rest.len() - rest.trim_start().len(),
            };
            (gap > 0).then_some(lead + day + gap)?
        }
        None => lead,
    };
    let digits = |at: usize| {
        text.get(start + at..start + at + 2)
            .is_some_and(|pair| pair.bytes().all(|byte| byte.is_ascii_digit()))
    };
    let colon = |at: usize| text.as_bytes().get(start + at) == Some(&b':');
    if !(digits(0) && colon(2) && digits(3)) {
        return None;
    }
    let len = if colon(5) && digits(6) { 8 } else { 5 };
    Some(start..start + len)
}

// A year can run past 9999, as PostgreSQL writes one, and carry a sign, as chrono reads one.
fn day_len(text: &str) -> Option<usize> {
    let sign = usize::from(matches!(text.as_bytes().first(), Some(b'-' | b'+')));
    let year = text.bytes().skip(sign).take_while(u8::is_ascii_digit).count();
    let dated = matches!(
        text.get(sign + year..sign + year + 6)?.as_bytes(),
        [b'-', m1, m2, b'-', d1, d2] if [m1, m2, d1, d2].iter().all(|byte| byte.is_ascii_digit())
    );
    (year >= 4 && dated).then_some(sign + year + 6)
}

pub fn time_of(text: &str) -> Option<NaiveTime> {
    let clock = text.get(clock_span(text)?)?;
    NaiveTime::parse_from_str(clock, "%H:%M:%S")
        .or_else(|_| NaiveTime::parse_from_str(clock, "%H:%M"))
        .ok()
}

// A value with no clock yet takes `today` for a missing day and `zone`'s offset then.
pub fn with_time<Tz: TimeZone>(text: &str, time: NaiveTime, field: ClockField, today: NaiveDate, zone: &Tz) -> String {
    let clock = time.format("%H:%M:%S").to_string();
    if let Some(span) = clock_span(text) {
        let mut text = text.to_owned();
        text.replace_range(span, &clock);
        return text;
    }
    let day = day_of(text.trim_start()).filter(|_| field.dated).unwrap_or(today);
    let offset = field
        .with_offset
        .then(|| offset_at(zone, day.and_time(time)).to_string())
        .unwrap_or_default();
    match field.dated {
        true => format!("{} {clock}{offset}", day.format("%Y-%m-%d")),
        false => format!("{clock}{offset}"),
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
