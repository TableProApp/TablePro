pub use tablepro_app_services::workspace_state::{
    ConnectionWorkspaceState, PersistedTableMode, RestoredWorkspaceTab, WorkspaceStore, WorkspaceTabRecord,
    restored_workspace_tab,
};

pub fn create_store() -> WorkspaceStore {
    WorkspaceStore::new(
        super::config_io::xdg_config_path("workspace_state.json"),
        glib::user_data_dir()
            .join(crate::config::storage_dir_name())
            .join("drafts"),
    )
}
