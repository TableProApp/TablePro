//! What the workspace keeps between sessions: which tabs were open and
//! what the editor ones held.

mod draft_writer;
mod persist_debouncer;
mod sort_record;
mod tab_record;
mod workspace_file_name;
mod workspace_load;
mod workspace_load_error;
mod workspace_record;
mod workspace_save_error;
mod workspace_store;
mod write_job;

pub use draft_writer::DraftWriter;
pub use persist_debouncer::PersistDebouncer;
pub use sort_record::SortRecord;
pub use tab_record::TabRecord;
pub use workspace_file_name::WorkspaceFileName;
pub use workspace_load::WorkspaceLoad;
pub use workspace_load_error::WorkspaceLoadError;
pub use workspace_record::WorkspaceRecord;
pub use workspace_save_error::WorkspaceSaveError;
pub use workspace_store::WorkspaceStore;
