//! Accessibility properties the toolkit cannot set by itself.

mod icon_button;
mod key_shortcuts;

pub(crate) use icon_button::{announce_key_shortcuts, describe_icon_button};
pub(crate) use key_shortcuts::aria_key_shortcuts;
