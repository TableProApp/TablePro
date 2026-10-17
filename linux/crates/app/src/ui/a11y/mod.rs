//! Accessibility properties the toolkit cannot set by itself.

mod announce;
mod focus;
mod icon_button;
mod invalid;
mod key_shortcuts;
#[cfg(test)]
mod tests;

pub(crate) use announce::announce;
#[cfg(test)]
pub(crate) use announce::said::announced_in;
pub(crate) use focus::{holds_focus, pass_focus};
pub(crate) use icon_button::{announce_key_shortcuts, describe_icon_button};
pub(crate) use invalid::show_invalid;
pub(crate) use key_shortcuts::aria_key_shortcuts;
