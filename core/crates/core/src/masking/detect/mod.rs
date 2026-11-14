// What a share masks before the user asks: columns named or holding personal data, and such data in the SQL. The
// lists, thresholds and rules are PLAN-MASKING 8.3 and 8.3.1, which the macOS app follows too; the shared fixtures
// in `fixtures.rs` pin them.

mod names;
mod sql;
mod values;

#[cfg(test)]
mod fixtures;

pub use names::{NameHit, column_name_hit, name_words};
pub(crate) use names::{Term, longest_term};
pub use sql::{PersonalDataHit, scan_sql_personal_data};
pub use values::{Seen, SensitiveKind, ValueTally, column_value_kind, is_text_like};

use super::MaskingStyle;
use crate::column::ResultColumn;
use crate::value::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MaskSuggestion {
    pub style: MaskingStyle,
    pub reason: SuggestionReason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SuggestionReason {
    // The term as its words join, such as "apikey".
    ColumnName { term: &'static str },
    Values { kind: SensitiveKind },
}

// One per column, from the rows to be shared. A name beats what the values show.
pub fn suggest_masks<R: AsRef<[Value]>>(columns: &[ResultColumn], rows: &[R]) -> Vec<Option<MaskSuggestion>> {
    let tallies: Vec<ValueTally> = columns
        .iter()
        .enumerate()
        .map(|(index, column)| {
            let mut tally = ValueTally::default();
            if is_text_like(&column.column_type) {
                for value in rows.iter().filter_map(|row| row.as_ref().get(index)) {
                    tally.record(Seen::of(&column.column_type, value));
                }
            }
            tally
        })
        .collect();
    suggest_from_tallies(columns, &[tallies])
}

// From a tally per column for each window of rows: a column any window flags is flagged, each window by its own
// thresholds, and the first kind in table order wins.
pub fn suggest_from_tallies<T: AsRef<[ValueTally]>>(
    columns: &[ResultColumn],
    windows: &[T],
) -> Vec<Option<MaskSuggestion>> {
    columns
        .iter()
        .enumerate()
        .map(|(index, column)| {
            if let Some(hit) = column_name_hit(&column.name) {
                return Some(MaskSuggestion {
                    style: hit.style,
                    reason: SuggestionReason::ColumnName { term: hit.term },
                });
            }
            windows
                .iter()
                .filter_map(|tallies| tallies.as_ref().get(index)?.kind())
                .min()
                .map(|kind| MaskSuggestion {
                    style: kind.style(),
                    reason: SuggestionReason::Values { kind },
                })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::ColumnType;

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    #[test]
    fn a_name_beats_the_values() {
        let columns = [
            ResultColumn::new("phone", ColumnType::untyped_text("text")),
            ResultColumn::new("notes", ColumnType::untyped_text("text")),
            ResultColumn::new("id", ColumnType::untyped_text("int")),
        ];
        let rows = vec![vec![
            text("ann@example.com"),
            text("4111 1111 1111 1111"),
            Value::Int(1),
        ]];

        let suggested = suggest_masks(&columns, &rows);

        assert_eq!(
            suggested,
            [
                Some(MaskSuggestion {
                    style: MaskingStyle::LastFour,
                    reason: SuggestionReason::ColumnName { term: "phone" },
                }),
                Some(MaskSuggestion {
                    style: MaskingStyle::LastFour,
                    reason: SuggestionReason::Values {
                        kind: SensitiveKind::Card
                    },
                }),
                None,
            ]
        );
    }

    #[test]
    fn a_column_two_windows_flag_differently_takes_the_first_kind_in_table_order() {
        let columns = [ResultColumn::new("contact", ColumnType::untyped_text("text"))];
        let emails = vec![vec![text("ann@example.com")]];
        let cards = vec![
            vec![text("4111 1111 1111 1111")],
            vec![text("ann@example.com")],
            vec![text("x")],
        ];

        let tally = |rows: &[Vec<Value>]| {
            let mut tally = ValueTally::default();
            for row in rows {
                tally.record(Seen::of(&columns[0].column_type, &row[0]));
            }
            vec![tally]
        };

        let suggested = suggest_from_tallies(&columns, &[tally(&emails), tally(&cards)]);

        assert_eq!(
            suggested[0].map(|found| found.reason),
            Some(SuggestionReason::Values {
                kind: SensitiveKind::Card
            })
        );
    }
}
