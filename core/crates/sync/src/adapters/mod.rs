// The record adapters (0054, Adapters) and the rules every provider applies through them: the members a store has no
// place for ride on the base, approval-required members wait for the person, and a team's contested records wait for
// Keep Mine or Keep Theirs.
#![expect(
    clippy::disallowed_types,
    clippy::disallowed_methods,
    reason = "record fields compare as JSON values, as Postgres jsonb does, so member order carries nothing"
)]

pub mod approval;
pub mod carry;
pub mod categories;
pub mod conflict;
pub mod fields;
pub mod settings;
pub mod team_library;

use std::collections::BTreeSet;

use serde_json::Value;
use tablepro_records::Kind;

use crate::api::error::AdapterError;
use crate::api::ids::ScopeName;

// The stores' calls block on files and SQLite, so they run off the runtime's workers.
pub(crate) async fn blocking<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> Result<T, AdapterError> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|error| AdapterError::Store {
            store: "blocking task".to_owned(),
            detail: error.to_string(),
        })
}

// A store's copy as it goes up and as a merge reads the device's side: the members the store cannot hold put back
// from the base, and the base's value in each member the device keeps to itself or that waits for the person.
pub fn local_view(
    kind: Kind,
    scope: ScopeName,
    stored: &Value,
    base: Option<&Value>,
    held: &BTreeSet<String>,
) -> Value {
    let carried = carry::carried(kind, stored, base);
    fields::with_members_of(kind, scope, &carried, base, held)
}
