//! What the grid hands back when the user edits a row, and how the
//! text they typed becomes a value.

mod cell_input;
mod edit_context;
mod edit_parse_error;
mod edit_text;
mod empty_input_meaning;
mod is_unchanged;
mod parse_edit_text;
mod parse_literal_text;

pub use cell_input::CellInput;
pub use edit_context::EditContext;
pub use edit_parse_error::{EditParseError, ReadOnlyReason};
pub use edit_text::{EditText, edit_text};
pub use empty_input_meaning::{EmptyInputMeaning, empty_input_meaning};
pub use is_unchanged::is_unchanged;
pub use parse_edit_text::parse_edit_text;
pub use parse_literal_text::{
    parse_filter_text, parse_literal_text, parse_time_with_offset, parse_timestamp_with_offset,
};
