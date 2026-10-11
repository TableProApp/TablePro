use std::{collections::HashMap, fmt::Debug};

use crate::{
    error::bulk_write::PartialBulkWriteResult,
    results::{DeleteResult, InsertOneResult, UpdateResult},
};

/// Summary results returned from a [`bulk_write`](crate::Client::bulk_write) operation.
#[cfg_attr(test, serde_with::skip_serializing_none)]
#[derive(Clone, Debug, Default)]
#[cfg_attr(test, derive(serde::Serialize))]
#[cfg_attr(test, serde(rename_all = "camelCase"))]
#[non_exhaustive]
pub struct SummaryBulkWriteResult {
    /// The total number of documents inserted across all operations.
    pub inserted_count: i64,

    /// The total number of documents matched across all operations.
    pub matched_count: i64,

    /// The total number of documents modified across all operations.
    pub modified_count: i64,

    /// The total number of documents upserted across all operations.
    pub upserted_count: i64,

    /// The total number of documents deleted across all operations.
    pub deleted_count: i64,
}

/// Verbose results returned from a [`bulk_write`](crate::Client::bulk_write) operation.
#[cfg_attr(test, serde_with::skip_serializing_none)]
#[derive(Clone, Debug, Default)]
#[cfg_attr(test, derive(serde::Serialize))]
#[cfg_attr(test, serde(rename_all = "camelCase"))]
#[non_exhaustive]
pub struct VerboseBulkWriteResult {
    /// The summary results.
    #[cfg_attr(test, serde(flatten))]
    pub summary: SummaryBulkWriteResult,

    /// The results of each insert operation that was successfully performed.
    #[cfg_attr(
        test,
        serde(serialize_with = "crate::serde_util::serialize_indexed_map")
    )]
    pub insert_results: HashMap<usize, InsertOneResult>,

    /// The results of each update operation that was successfully performed.
    #[cfg_attr(
        test,
        serde(serialize_with = "crate::serde_util::serialize_indexed_map")
    )]
    pub update_results: HashMap<usize, UpdateResult>,

    /// The results of each delete operation that was successfully performed.
    #[cfg_attr(
        test,
        serde(serialize_with = "crate::serde_util::serialize_indexed_map")
    )]
    pub delete_results: HashMap<usize, DeleteResult>,
}

mod result_trait {
    use crate::{
        error::bulk_write::PartialBulkWriteResult,
        results::{DeleteResult, InsertOneResult, UpdateResult},
    };

    pub trait BulkWriteResult: Default + Send + Sync {
        fn errors_only() -> bool;

        fn merge(&mut self, other: Self);

        fn into_partial_result(self) -> PartialBulkWriteResult;

        fn populate_summary_info(
            &mut self,
            n_inserted: i64,
            n_matched: i64,
            n_modified: i64,
            n_upserted: i64,
            n_deleted: i64,
        );

        fn add_insert_result(&mut self, _index: usize, _insert_result: InsertOneResult) {}

        fn add_update_result(&mut self, _index: usize, _update_result: UpdateResult) {}

        fn add_delete_result(&mut self, _index: usize, _delete_result: DeleteResult) {}
    }
}

pub(crate) use result_trait::BulkWriteResult;

impl BulkWriteResult for SummaryBulkWriteResult {
    fn errors_only() -> bool {
        true
    }

    fn merge(&mut self, other: Self) {
        let SummaryBulkWriteResult {
            inserted_count: other_inserted_count,
            matched_count: other_matched_count,
            modified_count: other_modified_count,
            upserted_count: other_upserted_count,
            deleted_count: other_deleted_count,
        } = other;

        self.inserted_count += other_inserted_count;
        self.matched_count += other_matched_count;
        self.modified_count += other_modified_count;
        self.upserted_count += other_upserted_count;
        self.deleted_count += other_deleted_count;
    }

    fn into_partial_result(self) -> PartialBulkWriteResult {
        PartialBulkWriteResult::Summary(self)
    }

    fn populate_summary_info(
        &mut self,
        n_inserted: i64,
        n_matched: i64,
        n_modified: i64,
        n_upserted: i64,
        n_deleted: i64,
    ) {
        self.inserted_count += n_inserted;
        self.matched_count += n_matched;
        self.modified_count += n_modified;
        self.upserted_count += n_upserted;
        self.deleted_count += n_deleted;
    }
}

impl BulkWriteResult for VerboseBulkWriteResult {
    fn errors_only() -> bool {
        false
    }

    fn merge(&mut self, other: Self) {
        let VerboseBulkWriteResult {
            summary: other_summary,
            insert_results: other_insert_results,
            update_results: other_update_results,
            delete_results: other_delete_results,
        } = other;

        self.summary.merge(other_summary);
        self.insert_results.extend(other_insert_results);
        self.update_results.extend(other_update_results);
        self.delete_results.extend(other_delete_results);
    }

    fn into_partial_result(self) -> PartialBulkWriteResult {
        PartialBulkWriteResult::Verbose(self)
    }

    fn populate_summary_info(
        &mut self,
        n_inserted: i64,
        n_matched: i64,
        n_modified: i64,
        n_upserted: i64,
        n_deleted: i64,
    ) {
        self.summary
            .populate_summary_info(n_inserted, n_matched, n_modified, n_upserted, n_deleted);
    }

    fn add_insert_result(&mut self, index: usize, insert_result: InsertOneResult) {
        self.insert_results.insert(index, insert_result);
    }

    fn add_update_result(&mut self, index: usize, update_result: UpdateResult) {
        self.update_results.insert(index, update_result);
    }

    fn add_delete_result(&mut self, index: usize, delete_result: DeleteResult) {
        self.delete_results.insert(index, delete_result);
    }
}
