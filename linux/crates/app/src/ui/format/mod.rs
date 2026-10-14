//! Numbers as the user reads them.

mod thousands;

#[cfg(test)]
pub(crate) use self::thousands::Thousands;
pub(crate) use self::thousands::format_thousands;
