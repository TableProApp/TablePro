//! Dameng database wire protocol implementation.
//!
//! This crate implements the binary wire protocol used to communicate
//! with Dameng database servers, based on reverse-engineered protocol captures.

pub mod error;
pub mod frame;
pub mod message;

pub use error::{Error, Result};
pub use frame::Frame;
pub use message::explain::ExplainResponse;
pub use message::response::{Column, ExecResponse, Row};
