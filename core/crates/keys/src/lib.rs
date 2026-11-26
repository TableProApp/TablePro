// End-to-end keys for TablePro Sync, suite `tp1` (core ADR 0056): the encodings, the key objects
// and their checks, wraps, envelopes, history entries, the device approval transcript, fingerprints
// and DPoP proofs. No I/O: the flows, the state file and the transport build on it.

pub mod b64;
pub mod base32;
pub mod body;
pub mod cert;
pub mod check;
mod crypto;
pub mod dpop;
pub mod encoding;
pub mod envelope;
mod error;
pub mod fingerprint;
pub mod json;
pub mod keys;
pub mod padding;
pub mod record_id;
pub mod recovery;
pub mod sas;
pub mod scope_key;
pub mod state_mac;
pub mod trust;
#[cfg(test)]
mod vectors;
pub mod words;
pub mod wrap;

pub use error::KeysError;
pub use secrecy;
