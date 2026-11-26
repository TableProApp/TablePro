// One sync engine for TablePro Sync and iCloud (core ADR 0054), with the end-to-end flows of 0056. `api` holds the
// contracts every part builds against: the transports, the state file, the device store, the record adapters, the
// key flows and the control surface the FFI wraps.

pub mod adapters;
pub mod api;
pub mod cloudkit;
pub mod engine;
pub mod keys;
pub mod service;
pub mod state;

pub use api::SyncError;
