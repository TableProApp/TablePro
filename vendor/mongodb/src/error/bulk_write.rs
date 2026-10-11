use std::collections::HashMap;

use crate::{
    error::{WriteConcernError, WriteError},
    results::{BulkWriteResult, SummaryBulkWriteResult, VerboseBulkWriteResult},
};

/// An error that occurred while executing [`bulk_write`](crate::Client::bulk_write).
///
/// If an additional error occurred that was not the result of an individual write failing or a
/// write concern error, it can be retrieved by calling [`source`](core::error::Error::source) on
/// the [`Error`](struct@crate::error::Error) in which this value is stored.
#[derive(Clone, Debug, Default)]
#[non_exhaustive]
pub struct BulkWriteError {
    /// The write concern errors that occurred.
    pub write_concern_errors: Vec<WriteConcernError>,

    /// The individual write errors that occurred.
    pub write_errors: HashMap<usize, WriteError>,

    /// The results of any successful writes. This value will only be populated if one or more
    /// writes succeeded.
    pub partial_result: Option<PartialBulkWriteResult>,
}

/// The results of a partially-successful [`bulk_write`](crate::Client::bulk_write) operation.
#[derive(Clone, Debug)]
#[cfg_attr(test, derive(serde::Serialize))]
#[cfg_attr(test, serde(untagged))]
pub enum PartialBulkWriteResult {
    /// Summary bulk write results. This variant will be populated if
    /// [`verbose_results`](crate::action::BulkWrite::verbose_results) was not configured in the
    /// call to [`bulk_write`](crate::Client::bulk_write).
    Summary(SummaryBulkWriteResult),

    /// Verbose bulk write results. This variant will be populated if
    /// [`verbose_results`](crate::action::BulkWrite::verbose_results) was configured in the call
    /// to [`bulk_write`](crate::Client::bulk_write).
    Verbose(VerboseBulkWriteResult),
}

impl PartialBulkWriteResult {
    pub(crate) fn merge(&mut self, other: Self) {
        match (self, other) {
            (Self::Summary(this), Self::Summary(other)) => this.merge(other),
            (Self::Verbose(this), Self::Verbose(other)) => this.merge(other),
            // The operation execution path makes this an unreachable state
            _ => unreachable!(),
        }
    }
}

impl BulkWriteError {
    pub(crate) fn merge(&mut self, other: Self) {
        self.write_concern_errors.extend(other.write_concern_errors);
        self.write_errors.extend(other.write_errors);
        if let Some(other_partial_result) = other.partial_result {
            self.merge_partial_results(other_partial_result);
        }
    }

    pub(crate) fn merge_partial_results(&mut self, other_partial_result: PartialBulkWriteResult) {
        if let Some(ref mut partial_result) = self.partial_result {
            partial_result.merge(other_partial_result);
        } else {
            self.partial_result = Some(other_partial_result);
        }
    }
}
