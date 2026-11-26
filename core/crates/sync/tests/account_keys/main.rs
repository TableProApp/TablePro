// K7-1's flows against the fake server and against what a hostile one serves: Genesis, Sign Out, Replace, pins and
// fingerprints, the own account followed up its certificates, and personal envelopes and history entries under
// 0056's Rollback rules. Test data comes from tablepro-keys' G1 vectors where they cover a case.

#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]
#![expect(
    clippy::disallowed_types,
    reason = "the key flows take and give JSON as serde values, which compare as values whatever the member order"
)]

mod genesis;
mod harness;
mod hostile;
mod personal;
mod pins;
mod replace;
mod sign_out;
mod vectors;
