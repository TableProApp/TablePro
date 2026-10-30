//! The grid's rules, with no GTK: what a column is, what a cell shows and
//! takes, and what the grid may change.

mod cell_editability;
mod cell_editor_kind;
mod cell_filter;
mod cell_lock;
mod cell_preset;
mod column_layout;
mod column_width;
mod copy_scope;
mod delete_availability;
pub mod display_text;
mod edit_navigation;
mod edit_parse;
mod edit_policy;
mod find_matches;
mod grid_column;
mod grid_row_id;
mod hex_dump;
mod row_key_builder;
mod row_snapshot;
mod selection_summary;
#[cfg(test)]
mod test_columns;
pub mod value_order;

pub use self::cell_editability::cell_editability;
pub use self::cell_editor_kind::{CellEditorKind, EDIT_MAX_BYTES, TextPurpose};
pub use self::cell_filter::cell_filter_rule;
pub use self::cell_lock::CellLock;
pub use self::cell_preset::{CellPreset, CellPresets, cell_presets};
pub use self::column_layout::{ColumnLayout, LayoutSlot, Placement, merge_order};
pub use self::column_width::{
    default_width_chars, number_width_chars, typical_texts, typical_width_chars, widest_text,
};
pub use self::copy_scope::{CopyScope, copy_scope};
pub use self::delete_availability::{DeleteAvailability, delete_availability};
pub use self::display_text::{auto_filled_sentinel, display_text};
pub use self::edit_navigation::{EditDirection, next_edit_target};
pub use self::edit_parse::{CommitResult, EditStart, commit_edit, commit_input, edit_context, empty_placeholder};
pub use self::edit_policy::{EditPolicy, EditRefusal, edit_policy, selection_hint};
pub use self::find_matches::{FindMatch, find_matches};
pub use self::grid_column::{CellDisplay, GridColumn, grid_columns};
pub use self::grid_row_id::GridRowId;
pub use self::hex_dump::hex_dump;
pub use self::row_key_builder::RowKeyBuilder;
pub use self::row_snapshot::RowSnapshot;
pub use self::selection_summary::{SelectionSummary, SummaryRule, summarize};
