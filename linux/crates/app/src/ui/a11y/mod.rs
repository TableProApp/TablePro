//! Accessibility properties the toolkit cannot set by itself.

mod announce;
mod icon_button;
mod key_shortcuts;
#[cfg(test)]
mod tests;

pub(crate) use announce::announce;
#[cfg(test)]
pub(crate) use announce::said::announced_in;
pub(crate) use icon_button::{announce_key_shortcuts, describe_icon_button};
pub(crate) use key_shortcuts::aria_key_shortcuts;
