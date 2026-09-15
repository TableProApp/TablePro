//! The small versioned JSON files the app keeps beside the user's
//! state: column widths and per-table filters.
//!
//! Each is read once at startup and answered from memory after that, so
//! nothing the user does waits on the disk. A file that cannot be read,
//! or that a newer TablePro wrote, is left exactly as it is.

mod column_width_store;
mod column_widths_document;
mod filter_settings_document;
mod filter_settings_store;
mod state_file;

pub use column_width_store::ColumnWidthStore;
pub use filter_settings_store::FilterSettingsStore;
pub use state_file::StateFile;
