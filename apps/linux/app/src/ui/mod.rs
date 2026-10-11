mod activity_dialog;
mod app;
mod browse_tab;
mod catalog_dialog;
mod cell_editor;
mod connect_dialog;
pub(crate) mod connection_bundle;
mod connection_row;
mod editor;
pub(crate) mod error_text;
mod explain_dialog;
mod export_dialog;
mod filter_strip;
mod grid;
mod history_dialog;
mod import_dialog;
mod mcp_preferences;
mod parameters_dialog;
mod preferences;
mod quick_switcher_dialog;
mod row_inspector;
mod row_object;
mod row_store;
mod saved_queries_dialog;
pub(crate) mod shortcut;
mod sidebar_row;
mod ssh_prompt;
mod ssh_section;
mod structure_tab;
mod structure_tab_dialogs;
mod welcome_view;

pub use app::{App, AppInit};
pub(crate) use ssh_prompt::GtkPrompter;

#[cfg(test)]
pub(crate) use editor::SchemaIndex;
