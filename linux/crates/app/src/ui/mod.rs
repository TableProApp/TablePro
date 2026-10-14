mod app;
mod browse_tab;
mod connect_dialog;
mod connection_list;
mod connection_list_banner;
mod connection_row;
pub(crate) mod credential_prompt;
mod editor;
mod editor_font_provider;
pub(crate) mod error_text;
mod export_dialog;
mod file_read;
mod file_write;
mod filter_strip;
mod grid;
mod handler_guard;
mod history_dialog;
pub(crate) mod icons;
mod import_dialog;
mod preferences_dialog;
mod saved_queries_dialog;
mod sidebar_row;
mod ssh_inputs;
mod ssh_section;
mod structure_tab;
mod structure_tab_dialogs;
mod style_scheme_grid;
mod style_scheme_resolver;
mod welcome_view;
mod window_geometry;

#[cfg(test)]
pub(crate) use app::install_window_shortcuts;
pub use app::{App, AppInit, AppMsg};
#[cfg(test)]
pub(crate) use browse_tab::BrowseTab;
#[cfg(test)]
pub(crate) use editor::{SqlEditor, SqlEditorInit};
pub(crate) use preferences_dialog::PreferencesDialog;
