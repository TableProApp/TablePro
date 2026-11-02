//! Editor text, kept in its own file per tab.
//!
//! The workspace file used to carry the query text inline and truncate
//! it at 256 KiB, which silently cut a long migration script in half.
//! A draft is written whole, beside the workspace that references it.

mod draft_id;
mod draft_scope;
mod draft_store;

pub use draft_id::DraftId;
pub use draft_scope::DraftScope;
pub use draft_store::DraftStore;
