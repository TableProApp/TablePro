//! What a key-value engine's connection reads in place of a catalogue
//! and pages: the keys of its database, and one key's value a window at
//! a time.

mod database_number;
mod key_listing;
mod key_page;
mod key_window;

pub use database_number::database_number;
pub use key_listing::{KeyListing, KeyScan, glob_escape};
pub use key_page::{KeyPage, KeyTtl};
pub use key_window::{KeyCursor, KeyWindow};
