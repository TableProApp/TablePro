//! The grid's copy and display logic, shared by every platform's app. None
//! of it words a string or touches a GUI; the app lays out the placeholders
//! and clipboard a payload names.

pub mod clipboard;
pub mod copy;
pub mod date_display;
mod date_format;
pub mod display;
mod hex_dump;
mod thousands;

pub use date_format::DateFormat;
pub use hex_dump::hex_dump;
pub use thousands::Thousands;
