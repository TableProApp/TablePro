use thiserror::Error;

use crate::column::IntegerKind;
use crate::value::{DecimalParseError, JsonTextError};

/// Why the text in a cell could not become a value of the column's
/// type.
///
/// Each arm is a message the user can act on, which is the point of
/// parsing in the app rather than sending the text and letting the
/// server complain.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum EditParseError {
    #[error("this column needs a value")]
    Required,
    #[error("enter a whole number")]
    InvalidInteger,
    #[error("this column holds {kind} integers, and this number is outside its range")]
    IntegerOutOfRange { kind: IntegerKind },
    #[error("enter a number")]
    InvalidFloat,
    #[error("enter a number: {0}")]
    InvalidDecimal(#[source] DecimalParseError),
    #[error("this column keeps at most {precision} digits")]
    PrecisionExceeded { precision: u32 },
    #[error("this column keeps at most {scale} decimal places")]
    ScaleExceeded { scale: u32 },
    #[error("enter true or false")]
    InvalidBoolean,
    #[error("enter a UUID")]
    InvalidUuid,
    #[error("enter valid JSON: {0}")]
    InvalidJson(#[source] JsonTextError),
    #[error("enter a date as YYYY-MM-DD")]
    InvalidDate,
    #[error("enter a time as HH:MM:SS")]
    InvalidTime,
    #[error("this time is outside the range the column can hold")]
    TimeOutOfRange,
    #[error("enter a date and time as YYYY-MM-DD HH:MM:SS")]
    InvalidTimestamp,
    #[error("this column needs a time zone offset")]
    OffsetRequired,
    #[error("enter an interval")]
    InvalidInterval,
    #[error("enter a bit string of 0 and 1")]
    InvalidBits,
    #[error("enter bytes as 0x and hex digits")]
    InvalidBytes,
    #[error("this column holds {expected} bits")]
    BitLengthMismatch { expected: u32 },
    #[error("this is not one of the values this column allows")]
    UnknownEnumLabel,
    #[error("this value cannot be edited here")]
    NotEditable(ReadOnlyReason),
}

/// Why a cell cannot be typed into.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadOnlyReason {
    /// Binary, which has no text form to edit.
    Bytes,
    Spatial,
    /// The driver could not read the value, so overwriting it would
    /// replace bytes nothing understood.
    Undecodable,
    Composite,
    Variant,
}

impl EditParseError {
    // Stable across releases, for an app outside Rust that words the error itself.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Required => "edit.required",
            Self::InvalidInteger => "edit.invalid_integer",
            Self::IntegerOutOfRange { .. } => "edit.integer_out_of_range",
            Self::InvalidFloat => "edit.invalid_float",
            Self::InvalidDecimal(_) => "edit.invalid_decimal",
            Self::PrecisionExceeded { .. } => "edit.precision_exceeded",
            Self::ScaleExceeded { .. } => "edit.scale_exceeded",
            Self::InvalidBoolean => "edit.invalid_boolean",
            Self::InvalidUuid => "edit.invalid_uuid",
            Self::InvalidJson(_) => "edit.invalid_json",
            Self::InvalidDate => "edit.invalid_date",
            Self::InvalidTime => "edit.invalid_time",
            Self::TimeOutOfRange => "edit.time_out_of_range",
            Self::InvalidTimestamp => "edit.invalid_timestamp",
            Self::OffsetRequired => "edit.offset_required",
            Self::InvalidInterval => "edit.invalid_interval",
            Self::InvalidBits => "edit.invalid_bits",
            Self::InvalidBytes => "edit.invalid_bytes",
            Self::BitLengthMismatch { .. } => "edit.bit_length_mismatch",
            Self::UnknownEnumLabel => "edit.unknown_enum_label",
            Self::NotEditable(_) => "edit.not_editable",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_code_names_its_variant_under_edit() {
        let codes = [
            EditParseError::Required.code(),
            EditParseError::InvalidInteger.code(),
            EditParseError::IntegerOutOfRange {
                kind: IntegerKind {
                    width: crate::column::IntegerWidth::W32,
                    signed: true,
                },
            }
            .code(),
            EditParseError::UnknownEnumLabel.code(),
            EditParseError::NotEditable(ReadOnlyReason::Bytes).code(),
        ];

        assert_eq!(
            codes,
            [
                "edit.required",
                "edit.invalid_integer",
                "edit.integer_out_of_range",
                "edit.unknown_enum_label",
                "edit.not_editable"
            ]
        );
    }
}
