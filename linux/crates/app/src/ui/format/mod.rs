//! Numbers as the user reads them.

mod thousands;

#[cfg(test)]
pub(crate) use self::thousands::Thousands;
pub(crate) use self::thousands::{format_decimal, format_thousands};

/// The count gettext picks a plural form by. It takes a u32, and a
/// result past that is rare enough for the largest u32 to stand in.
pub(crate) fn plural_count(n: u64) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}
