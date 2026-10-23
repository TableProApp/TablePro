use tablepro_core::column::IntegerKind;
use tablepro_core::edit::{EditParseError, ReadOnlyReason};
use tablepro_core::import::CsvRowError;
use tablepro_core::value::JsonTextError;

use crate::i18n::{gettext, gettext_f, ngettext_f};

/// What to tell the user about text a cell would not take. Every
/// variant has its own branch, so a new one fails to compile here
/// rather than reaching a widget as its log text.
pub fn edit_parse_message(error: &EditParseError) -> String {
    match error {
        EditParseError::Required => gettext("This column needs a value"),
        EditParseError::InvalidInteger => gettext("Enter a whole number"),
        EditParseError::IntegerOutOfRange { kind } => {
            let (min, max) = integer_range(*kind);
            gettext_f(
                "Enter a whole number from {min} to {max}",
                &[("min", &min), ("max", &max)],
            )
        }
        EditParseError::InvalidFloat => gettext("Enter a number"),
        EditParseError::InvalidDecimal(_) => gettext("Enter a decimal number, such as 12.50"),
        EditParseError::PrecisionExceeded { precision } => ngettext_f(
            "This column keeps at most {n} digit",
            "This column keeps at most {n} digits",
            *precision,
            &[("n", &precision.to_string())],
        ),
        EditParseError::ScaleExceeded { scale } => ngettext_f(
            "This column keeps at most {n} decimal place",
            "This column keeps at most {n} decimal places",
            *scale,
            &[("n", &scale.to_string())],
        ),
        EditParseError::InvalidBoolean => gettext("Enter true or false"),
        EditParseError::InvalidUuid => gettext("Enter a UUID"),
        EditParseError::InvalidJson(JsonTextError::Incomplete) => gettext("Enter valid JSON: it ends too early"),
        EditParseError::InvalidJson(JsonTextError::Invalid { line, column }) => gettext_f(
            "Enter valid JSON: check line {line}, column {column}",
            &[("line", &line.to_string()), ("column", &column.to_string())],
        ),
        EditParseError::InvalidDate => gettext("Enter a date as YYYY-MM-DD"),
        EditParseError::InvalidTime => gettext("Enter a time as HH:MM:SS"),
        EditParseError::TimeOutOfRange => gettext("This time is outside the range the column can hold"),
        EditParseError::InvalidTimestamp => gettext("Enter a date and time as YYYY-MM-DD HH:MM:SS"),
        EditParseError::OffsetRequired => gettext("Add a time zone offset, such as +02:00"),
        EditParseError::InvalidInterval => gettext("Enter an interval, such as 1 day 02:00:00"),
        EditParseError::InvalidBits => gettext("Enter bits as 0 and 1"),
        EditParseError::InvalidBytes => gettext("Enter bytes as 0x and hex digits, such as 0x1f2e"),
        EditParseError::BitLengthMismatch { expected } => ngettext_f(
            "Enter exactly {n} bit",
            "Enter exactly {n} bits",
            *expected,
            &[("n", &expected.to_string())],
        ),
        EditParseError::UnknownEnumLabel => gettext("Enter one of the values this column allows"),
        EditParseError::NotEditable(reason) => not_editable_message(*reason),
    }
}

/// How much of a refused value an alert quotes: enough to find it in
/// the source, never a whole document laid out in a dialog.
const QUOTED_VALUE_CHARS: usize = 80;

/// Where an imported or pasted row holds a value its column refused,
/// and why.
pub fn row_error_message(error: &CsvRowError) -> String {
    let text = match error.text.char_indices().nth(QUOTED_VALUE_CHARS) {
        Some((end, _)) => format!("{}…", &error.text[..end]),
        None => error.text.clone(),
    };
    gettext_f(
        "Line {line}, column {column}: {reason} (the value was “{text}”)",
        &[
            ("line", &error.line.to_string()),
            ("column", &error.column),
            ("reason", &edit_parse_message(&error.reason)),
            ("text", &text),
        ],
    )
}

fn not_editable_message(reason: ReadOnlyReason) -> String {
    match reason {
        ReadOnlyReason::Bytes => gettext("Binary values can't be edited here"),
        ReadOnlyReason::Spatial => gettext("Spatial values can't be edited here"),
        ReadOnlyReason::Undecodable => gettext("This value couldn't be read, so it can't be edited"),
        ReadOnlyReason::Composite => gettext("Arrays and composite values can't be edited here"),
        ReadOnlyReason::Variant => gettext("Values whose type changes by row can't be edited here"),
    }
}

/// The smallest and largest value of an integer column, written out.
fn integer_range(kind: IntegerKind) -> (String, String) {
    let bits = kind.width.bits();
    match (kind.signed, bits) {
        (true, 256) => ("-2^255".to_owned(), "2^255 - 1".to_owned()),
        (false, 256) => ("0".to_owned(), "2^256 - 1".to_owned()),
        (true, 128) => (i128::MIN.to_string(), i128::MAX.to_string()),
        (false, 128) => ("0".to_owned(), u128::MAX.to_string()),
        (true, bits) => {
            let half = 1i128 << (bits - 1);
            ((-half).to_string(), (half - 1).to_string())
        }
        (false, bits) => ("0".to_owned(), ((1u128 << bits) - 1).to_string()),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use tablepro_core::column::{IntegerKind, IntegerWidth};
    use tablepro_core::edit::{EditParseError, ReadOnlyReason};
    use tablepro_core::value::{DecimalParseError, JsonTextError};

    use tablepro_core::import::CsvRowError;

    use super::{QUOTED_VALUE_CHARS, edit_parse_message, integer_range, row_error_message};

    #[test]
    fn every_edit_parse_error_variant_has_a_distinct_message() {
        let kind = IntegerKind {
            width: IntegerWidth::W16,
            signed: true,
        };
        let errors = [
            EditParseError::Required,
            EditParseError::InvalidInteger,
            EditParseError::IntegerOutOfRange { kind },
            EditParseError::InvalidFloat,
            EditParseError::InvalidDecimal(DecimalParseError::InvalidSyntax),
            EditParseError::PrecisionExceeded { precision: 5 },
            EditParseError::ScaleExceeded { scale: 2 },
            EditParseError::InvalidBoolean,
            EditParseError::InvalidUuid,
            EditParseError::InvalidJson(JsonTextError::Incomplete),
            EditParseError::InvalidJson(JsonTextError::Invalid { line: 2, column: 7 }),
            EditParseError::InvalidDate,
            EditParseError::InvalidTime,
            EditParseError::TimeOutOfRange,
            EditParseError::InvalidTimestamp,
            EditParseError::OffsetRequired,
            EditParseError::InvalidInterval,
            EditParseError::InvalidBits,
            EditParseError::InvalidBytes,
            EditParseError::BitLengthMismatch { expected: 8 },
            EditParseError::UnknownEnumLabel,
            EditParseError::NotEditable(ReadOnlyReason::Bytes),
        ];

        let messages: Vec<String> = errors.iter().map(edit_parse_message).collect();

        assert!(messages.iter().all(|message| !message.is_empty()), "{messages:?}");
        let distinct: HashSet<&String> = messages.iter().collect();
        assert_eq!(distinct.len(), messages.len(), "{messages:?}");
        assert_eq!(messages[2], "Enter a whole number from -32768 to 32767");
        assert_eq!(messages[10], "Enter valid JSON: check line 2, column 7");
    }

    #[test]
    fn every_read_only_reason_says_its_own_thing() {
        let reasons = [
            ReadOnlyReason::Bytes,
            ReadOnlyReason::Spatial,
            ReadOnlyReason::Undecodable,
            ReadOnlyReason::Composite,
            ReadOnlyReason::Variant,
        ];

        let messages: HashSet<String> = reasons
            .iter()
            .map(|reason| edit_parse_message(&EditParseError::NotEditable(*reason)))
            .collect();

        assert_eq!(messages.len(), reasons.len());
    }

    #[test]
    fn a_refused_value_is_quoted_short() {
        let error = |text: String| CsvRowError {
            line: 3,
            column: "age".to_owned(),
            text,
            reason: EditParseError::InvalidInteger,
        };

        let short = row_error_message(&error("forty".to_owned()));
        let long = row_error_message(&error("é".repeat(10_000)));

        assert_eq!(
            short,
            "Line 3, column age: Enter a whole number (the value was “forty”)"
        );
        assert!(
            long.contains(&format!("“{}…”", "é".repeat(QUOTED_VALUE_CHARS))),
            "{long}"
        );
        assert!(long.chars().count() < 200, "{long}");
    }

    #[test]
    fn integer_ranges_follow_width_and_sign() {
        let range = |width, signed| integer_range(IntegerKind { width, signed });

        assert_eq!(range(IntegerWidth::W8, false), ("0".to_owned(), "255".to_owned()));
        assert_eq!(
            range(IntegerWidth::W24, true),
            ("-8388608".to_owned(), "8388607".to_owned())
        );
        assert_eq!(
            range(IntegerWidth::W64, true),
            (i64::MIN.to_string(), i64::MAX.to_string())
        );
        assert_eq!(range(IntegerWidth::W128, false).1, u128::MAX.to_string());
        assert_eq!(range(IntegerWidth::W256, true).0, "-2^255");
    }
}
