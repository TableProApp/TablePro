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
pub use values::{SensitiveKind, column_value_kind, is_text_like};

use super::{ColumnMasks, MaskingStyle};
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

// One per column, from the rows to be shared. A column `ruled` masks gets none, and a name beats what the values show.
pub fn suggest_masks<R: AsRef<[Value]>>(
    columns: &[ResultColumn],
    rows: &[R],
    ruled: &ColumnMasks,
) -> Vec<Option<MaskSuggestion>> {
    columns
        .iter()
        .enumerate()
        .map(|(index, column)| {
            if ruled.is_masked(index) {
                return None;
            }
            if let Some(hit) = column_name_hit(&column.name) {
                return Some(MaskSuggestion {
                    style: hit.style,
                    reason: SuggestionReason::ColumnName { term: hit.term },
                });
            }
            let values = rows.iter().filter_map(|row| row.as_ref().get(index));
            column_value_kind(&column.column_type, values).map(|kind| MaskSuggestion {
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
    fn a_name_beats_the_values_and_a_ruled_column_gets_nothing() {
        let columns = [
            ResultColumn::new("phone", ColumnType::untyped_text("text")),
            ResultColumn::new("notes", ColumnType::untyped_text("text")),
            ResultColumn::new("email", ColumnType::untyped_text("text")),
            ResultColumn::new("id", ColumnType::untyped_text("int")),
        ];
        let rows = vec![vec![
            text("ann@example.com"),
            text("4111 1111 1111 1111"),
            text("x"),
            Value::Int(1),
        ]];
        let ruled = ColumnMasks::new(vec![None, None, Some(MaskingStyle::Full), None]);

        let suggested = suggest_masks(&columns, &rows, &ruled);

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
                None,
            ]
        );
    }
}
