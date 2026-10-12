//! How one engine spells SQL, and what goes wrong when a value cannot
//! become SQL. Each driver crate implements `SqlDialect` for its engine.

mod bind_error;
mod bind_target;
mod dialect_capabilities;
mod keyset_direction;
mod like_form;
mod literal_error;
mod placeholder;
mod sql_dialect;
#[cfg(test)]
mod test_dialect;

pub use bind_error::BindError;
pub use bind_target::BindTarget;
pub use dialect_capabilities::DialectCapabilities;
pub use keyset_direction::KeysetDirection;
pub use like_form::{LikeCase, LikeForm};
pub use literal_error::LiteralError;
pub use placeholder::Placeholder;
pub use sql_dialect::SqlDialect;
#[cfg(test)]
pub(crate) use test_dialect::{RecordedTarget, TestDialect, TestMarkers};
