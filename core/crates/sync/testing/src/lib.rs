// Fakes of the parts the sync engine runs against, for every sync lane's tests: an in-memory `/v2/sync` server, a
// CloudKit, a device store, a state file, the key flows and Team Library's control. Each behaves as its ADR says,
// which its tests show.
#![expect(
    clippy::disallowed_types,
    reason = "record fields compare as JSON values, as Postgres jsonb does, so member order carries nothing"
)]

pub mod cloudkit;
pub mod device_store;
pub mod key_flows;
pub mod service;
pub mod state;
pub mod team_library;

pub use cloudkit::FakeCloudKit;
pub use device_store::FakeDeviceStore;
pub use key_flows::{FakeKeyFlows, RecordingHooks};
pub use service::{FakeClient, FakeServer};
pub use state::MemoryStateFiles;
pub use team_library::{FakeTeamLibrary, TeamLibraryCall};
