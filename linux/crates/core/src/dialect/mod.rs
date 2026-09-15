//! How a value becomes SQL, and what goes wrong when it cannot.
//!
//! The dialect trait itself lands with the per-engine implementations;
//! these are the shapes its callers pass and handle.

mod bind_error;
mod bind_target;
mod dialect_capabilities;
mod keyset_direction;
mod like_form;
mod literal_error;
mod placeholder;

pub use bind_error::BindError;
pub use bind_target::BindTarget;
pub use dialect_capabilities::DialectCapabilities;
pub use keyset_direction::KeysetDirection;
pub use like_form::{LikeCase, LikeForm};
pub use literal_error::LiteralError;
pub use placeholder::Placeholder;
