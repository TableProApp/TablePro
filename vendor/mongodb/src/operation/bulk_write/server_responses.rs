use serde::Deserialize;

use crate::{bson::Bson, error::WriteError};

/// The summary information contained within the top-level response to the bulkWrite command.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct SummaryInfo {
    pub(super) n_errors: i64,
    pub(super) n_inserted: i64,
    pub(super) n_matched: i64,
    pub(super) n_modified: i64,
    pub(super) n_upserted: i64,
    pub(super) n_deleted: i64,
}

/// The structure of the response for a single operation within the results cursor.
#[derive(Debug, Deserialize)]
pub(super) struct SingleOperationResponse {
    #[serde(rename = "idx")]
    pub(super) index: usize,
    #[serde(flatten)]
    pub(super) result: SingleOperationResult,
}

/// The structure of the non-index fields for a single operation within the results cursor.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub(super) enum SingleOperationResult {
    // This variant must be listed first for proper deserialization.
    Error(WriteError),
    #[serde(rename_all = "camelCase")]
    Success {
        n: u64,
        n_modified: Option<u64>,
        upserted: Option<UpsertedId>,
    },
}

/// The structure of the inserted ID for an upserted document.
#[derive(Debug, Deserialize)]
pub(super) struct UpsertedId {
    #[serde(rename = "_id")]
    pub(super) id: Bson,
}
