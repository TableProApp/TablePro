//! The small versioned JSON files the app keeps beside the user's
//! state: column layouts, per-table filters and highlight rules.
//!
//! Each is read once at startup and answered from memory after that, so
//! nothing the user does waits on the disk. A file that cannot be read,
//! or that a newer TablePro wrote, is left exactly as it is.

mod column_layout_store;
mod column_layouts_document;
mod filter_settings_document;
mod filter_settings_store;
mod highlight_rules_document;
mod highlight_rules_store;
mod state_file;

pub use column_layout_store::ColumnLayoutStore;
pub use filter_settings_store::FilterSettingsStore;
pub use highlight_rules_store::HighlightRulesStore;
pub use state_file::StateFile;
