//! Editor text, kept in its own file per tab and written whole, beside
//! the workspace that references it, so a script of any length survives.

mod draft_id;
mod draft_scope;
mod draft_store;

pub use draft_id::DraftId;
pub use draft_scope::DraftScope;
pub use draft_store::DraftStore;
