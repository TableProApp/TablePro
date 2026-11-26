// Synced records for TablePro Sync and iCloud (0051, 0052, 0054, 0056): kinds, ids, wire schemas, field classes, the
// settings registries, the merge, RFC 7396 patches and the CloudKit projection. No I/O beyond the library's store.
#![expect(
    clippy::disallowed_types,
    reason = "record fields compare as JSON values, as Postgres jsonb does, so member order carries nothing"
)]

pub mod cloudkit;
pub mod cycles;
pub mod envelope;
pub mod kind;
pub mod limits;
pub mod merge;
pub mod merge_patch;
pub mod order;
pub mod record_id;
pub mod schema;
pub mod secret_key;
pub mod settings;

pub use kind::{Kind, KindError, Scope};
