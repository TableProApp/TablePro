// K7-2's flows against the fake server: device approval with the SAS session and its trust merge, rotation with the
// removal review, recovery with R, and reset. Each refusal is checked by its code.

#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]
#![expect(
    clippy::disallowed_types,
    reason = "pulled records carry their fields as serde values, which compare as values whatever the member order"
)]

mod approval;
mod harness;
mod reset;
mod rotation;
