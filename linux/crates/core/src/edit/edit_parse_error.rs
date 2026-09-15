use thiserror::Error;

use crate::column::IntegerKind;
use crate::value::DecimalParseError;

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
    #[error("this column holds {kind:?} values, and this number is outside its range")]
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
    InvalidJson(String),
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
