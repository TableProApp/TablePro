//! Contains options for ChangeStreams.
use macro_magic::export_tokens;
use serde::{Deserialize, Serialize};
use serde_with::skip_serializing_none;
use std::time::Duration;
use typed_builder::TypedBuilder;

use crate::{
    bson::{Bson, Timestamp},
    change_stream::event::ResumeToken,
    collation::Collation,
    concern::ReadConcern,
    options::AggregateOptions,
    selection_criteria::SelectionCriteria,
};

/// These are the valid options that can be passed to the `watch` method for creating a
/// [`ChangeStream`](crate::change_stream::ChangeStream).
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, Serialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
#[export_tokens]
pub struct ChangeStreamOptions {
    #[rustfmt::skip]
    /// Configures how the
    /// [`ChangeStreamEvent::full_document`](crate::change_stream::event::ChangeStreamEvent::full_document)
    /// field will be populated. By default, the field will be empty for updates.
    pub full_document: Option<FullDocumentType>,

    /// Configures how the
    /// [`ChangeStreamEvent::full_document_before_change`](
    /// crate::change_stream::event::ChangeStreamEvent::full_document_before_change) field will be
    /// populated.  By default, the field will be empty for updates.
    pub full_document_before_change: Option<FullDocumentBeforeChangeType>,

    /// Specifies the logical starting point for the new change stream. Note that if a watched
    /// collection is dropped and recreated or newly renamed, `start_after` should be set instead.
    /// `resume_after` and `start_after` cannot be set simultaneously.
    ///
    /// For more information on resuming a change stream see the documentation [here](https://www.mongodb.com/docs/manual/changeStreams/#change-stream-resume-after)
    pub resume_after: Option<ResumeToken>,

    /// The change stream will only provide changes that occurred at or after the specified
    /// timestamp. Any command run against the server will return an operation time that can be
    /// used here.
    pub start_at_operation_time: Option<Timestamp>,

    /// Takes a resume token and starts a new change stream returning the first notification after
    /// the token. This will allow users to watch collections that have been dropped and
    /// recreated or newly renamed collections without missing any notifications.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/master/changeStreams/#change-stream-start-after) for more
    /// information.
    pub start_after: Option<ResumeToken>,

    /// If `true`, the change stream will monitor all changes for the given cluster.
    #[builder(setter(skip))]
    pub(crate) all_changes_for_cluster: Option<bool>,

    /// The maximum amount of time for the server to wait on new documents to satisfy a change
    /// stream query.
    #[serde(skip_serializing)]
    pub max_await_time: Option<Duration>,

    /// The number of documents to return per batch.
    #[serde(skip_serializing)]
    pub batch_size: Option<u32>,

    /// Specifies a collation.
    #[serde(skip_serializing)]
    pub collation: Option<Collation>,

    /// The read concern to use for the operation.
    ///
    /// If none is specified, the read concern defined on the object executing this operation will
    /// be used.
    #[serde(skip_serializing)]
    pub read_concern: Option<ReadConcern>,

    /// The criteria used to select a server for this operation.
    ///
    /// If none is specified, the selection criteria defined on the object executing this operation
    /// will be used.
    #[serde(skip_serializing)]
    pub selection_criteria: Option<SelectionCriteria>,

    /// Enables the server to send the 'expanded' list of change stream events.
    pub show_expanded_events: Option<bool>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

impl ChangeStreamOptions {
    pub(crate) fn aggregate_options(&self) -> AggregateOptions {
        AggregateOptions::builder()
            .batch_size(self.batch_size)
            .collation(self.collation.clone())
            .max_await_time(self.max_await_time)
            .read_concern(self.read_concern.clone())
            .selection_criteria(self.selection_criteria.clone())
            .comment(self.comment.clone())
            .build()
    }
}

/// Describes the modes for configuring the
/// [`ChangeStreamEvent::full_document`](
/// crate::change_stream::event::ChangeStreamEvent::full_document) field.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub enum FullDocumentType {
    /// The field will be populated with a copy of the entire document that was updated.
    UpdateLookup,

    /// The field will be populated for replace and update change events if the post-image for this
    /// event is available.
    WhenAvailable,

    /// The same behavior as `WhenAvailable` except that an error is raised if the post-image is
    /// not available.
    Required,

    /// User-defined other types for forward compatibility.
    Other(String),
}

/// Describes the modes for configuring the
/// [`ChangeStreamEvent::full_document_before_change`](
/// crate::change_stream::event::ChangeStreamEvent::full_document_before_change) field.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub enum FullDocumentBeforeChangeType {
    /// The field will be populated for replace, update, and delete change events if the pre-image
    /// for this event is available.
    WhenAvailable,

    /// The same behavior as `WhenAvailable` except that an error is raised if the pre-image is
    /// not available.
    Required,

    /// Do not send a value.
    Off,

    /// User-defined other types for forward compatibility.
    Other(String),
}
