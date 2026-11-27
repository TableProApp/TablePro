// The engine's CloudKit side (0054, The CloudKit transport): `fetch` reads the zone into the stores and the state
// file, and merges a save CloudKit refused with `serverRecordChanged`; `modify` sends what the stores changed and runs
// the iCloud pass; `legacy` imports the Swift engine's metadata and writes it back for the previous stable.

mod codes;
pub mod fetch;
mod legacy;
pub mod modify;

pub use legacy::LegacyMarks;
