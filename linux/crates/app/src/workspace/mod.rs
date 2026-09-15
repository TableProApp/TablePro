//! What the workspace keeps between sessions: which tabs were open and
//! what the editor ones held.

mod draft_writer;
mod persist_debouncer;

pub use draft_writer::DraftWriter;
pub use persist_debouncer::PersistDebouncer;
