/// Module for defining the TCP settings and behavior.
pub mod tcp;

#[cfg(feature = "aio")]
mod dns;

#[cfg(feature = "aio")]
pub use dns::AsyncDNSResolver;
