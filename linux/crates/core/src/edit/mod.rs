//! What the grid hands back when the user edits a row, and how the
//! text they typed becomes a value.

mod cell_input;
mod edit_parse_error;
mod parse_literal_text;

pub use cell_input::CellInput;
pub use edit_parse_error::{EditParseError, ReadOnlyReason};
pub use parse_literal_text::{
    parse_filter_text, parse_literal_text, parse_time_with_offset, parse_timestamp_with_offset,
};
