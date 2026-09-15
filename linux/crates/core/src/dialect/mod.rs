//! What goes wrong turning a value into SQL.
//!
//! The dialect trait itself lands with the per-engine implementations;
//! these are the failures its callers handle.

mod bind_error;
mod literal_error;

pub use bind_error::BindError;
pub use literal_error::LiteralError;
