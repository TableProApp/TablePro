//! Contains the types related to a `ChangeStream` event.
#[cfg(test)]
use std::convert::TryInto;

#[cfg(test)]
use crate::{bson::Bson, bson_compat::RawError};
use crate::{
    bson::{DateTime, Document, RawBson, RawDocumentBuf, Timestamp},
    cursor::common::CursorSpecification,
    options::ChangeStreamOptions,
};

use serde::{Deserialize, Serialize};
use serde_with::skip_serializing_none;

/// An opaque token used for resuming an interrupted
/// [`ChangeStream`](crate::change_stream::ChangeStream).
///
/// When starting a new change stream,
/// [`crate::action::Watch::start_after`] and
/// [`crate::action::Watch::resume_after`] fields can be specified
/// with instances of `ResumeToken`.
///
/// See the documentation
/// [here](https://www.mongodb.com/docs/manual/changeStreams/#change-stream-resume-token) for more
/// information on resume tokens.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct ResumeToken(pub(crate) RawBson);

impl ResumeToken {
    pub(crate) fn initial(
        options: Option<&ChangeStreamOptions>,
        spec: &CursorSpecification,
    ) -> Option<ResumeToken> {
        match &spec.post_batch_resume_token {
            // Token from initial response from `aggregate`
            Some(token) if spec.is_empty => Some(token.clone()),
            // Token from options passed to `watch`
            _ => options
                .and_then(|o| o.start_after.as_ref().or(o.resume_after.as_ref()))
                .cloned(),
        }
    }

    pub(crate) fn from_raw(doc: Option<RawDocumentBuf>) -> Option<ResumeToken> {
        doc.map(|doc| ResumeToken(RawBson::Document(doc)))
    }

    #[cfg(test)]
    pub(crate) fn parsed(self) -> std::result::Result<Bson, RawError> {
        self.0.try_into()
    }
}

/// A `ChangeStreamEvent` represents a
/// [change event](https://www.mongodb.com/docs/manual/reference/change-events/) in the associated change stream.
#[skip_serializing_none]
#[derive(Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ChangeStreamEvent<T> {
    /// An opaque token for use when resuming an interrupted `ChangeStream`.
    ///
    /// See the documentation
    /// [here](https://www.mongodb.com/docs/manual/changeStreams/#change-stream-resume-token) for
    /// more information on resume tokens.
    ///
    /// Also see the documentation on [resuming a change
    /// stream](https://www.mongodb.com/docs/manual/changeStreams/#resume-a-change-stream).
    #[serde(rename = "_id")]
    pub id: ResumeToken,

    /// Describes the type of operation represented in this change notification.
    pub operation_type: OperationType,

    /// Identifies the collection or database on which the event occurred.
    pub ns: Option<ChangeNamespace>,

    /// The type of the newly created object.  Only included for `OperationType::Create`.
    pub ns_type: Option<ChangeNamespaceType>,

    /// The new name for the `ns` collection.  Only included for `OperationType::Rename`.
    pub to: Option<ChangeNamespace>,

    /// The identifier for the session associated with the transaction.
    /// Only present if the operation is part of a multi-document transaction.
    pub lsid: Option<Document>,

    /// Together with the lsid, a number that helps uniquely identify a transaction.
    /// Only present if the operation is part of a multi-document transaction.
    pub txn_number: Option<i64>,

    /// A `Document` that contains the `_id` of the document created or modified by the `insert`,
    /// `replace`, `delete`, `update` operations (i.e. CRUD operations). For sharded collections,
    /// also displays the full shard key for the document. The `_id` field is not repeated if it is
    /// already a part of the shard key.
    pub document_key: Option<Document>,

    /// A description of the fields that were updated or removed by the update operation.
    /// Only specified if `operation_type` is `OperationType::Update`.
    pub update_description: Option<UpdateDescription>,

    /// The cluster time at which the change occurred.
    pub cluster_time: Option<Timestamp>,

    /// The wall time from the mongod that the change event originated from.
    pub wall_time: Option<DateTime>,

    /// The `Document` created or modified by the `insert`, `replace`, `delete`, `update`
    /// operations (i.e. CRUD operations).
    ///
    /// For `insert` and `replace` operations, this represents the new document created by the
    /// operation.  For `delete` operations, this field is `None`.
    ///
    /// For `update` operations, this field only appears if you configured the change stream with
    /// [`full_document`](crate::action::Watch::full_document) set to
    /// [`UpdateLookup`](crate::options::FullDocumentType::UpdateLookup). This field then
    /// represents the most current majority-committed version of the document modified by the
    /// update operation.
    pub full_document: Option<T>,

    /// Contains the pre-image of the modified or deleted document if the pre-image is available
    /// for the change event and either `Required` or `WhenAvailable` was specified for the
    /// [`full_document_before_change`](
    /// crate::action::Watch::full_document_before_change) option when creating the
    /// change stream. If `WhenAvailable` was specified but the pre-image is unavailable, this
    /// will be explicitly set to `None`.
    pub full_document_before_change: Option<T>,
}

/// Describes which fields have been updated or removed from a document.
#[skip_serializing_none]
#[derive(Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct UpdateDescription {
    /// A `Document` containing key:value pairs of names of the fields that were changed, and the
    /// new value for those fields.
    pub updated_fields: Document,

    /// An array of field names that were removed from the `Document`.
    pub removed_fields: Vec<String>,

    /// Arrays that were truncated in the `Document`.
    pub truncated_arrays: Option<Vec<TruncatedArray>>,

    /// When an update event reports changes involving ambiguous fields, the disambiguatedPaths
    /// document provides the path key with an array listing each path component.
    /// Note: The disambiguatedPaths field is only available on change streams started with the
    /// `show_expanded_events` option.
    pub disambiguated_paths: Option<Document>,
}

/// Describes an array that has been truncated.
#[derive(Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct TruncatedArray {
    /// The field path of the array.
    pub field: String,

    /// The new size of the array.
    pub new_size: i32,
}

/// The operation type represented in a given change notification.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum OperationType {
    /// See [insert-event](https://www.mongodb.com/docs/manual/reference/change-events/#insert-event)
    Insert,

    /// See [update-event](https://www.mongodb.com/docs/manual/reference/change-events/#update-event)
    Update,

    /// See [replace-event](https://www.mongodb.com/docs/manual/reference/change-events/#replace-event)
    Replace,

    /// See [delete-event](https://www.mongodb.com/docs/manual/reference/change-events/#delete-event)
    Delete,

    /// See [drop-event](https://www.mongodb.com/docs/manual/reference/change-events/#drop-event)
    Drop,

    /// See [rename-event](https://www.mongodb.com/docs/manual/reference/change-events/#rename-event)
    Rename,

    /// See [dropdatabase-event](https://www.mongodb.com/docs/manual/reference/change-events/#dropdatabase-event)
    DropDatabase,

    /// See [invalidate-event](https://www.mongodb.com/docs/manual/reference/change-events/#invalidate-event)
    Invalidate,

    /// A catch-all for future event types.
    Other(String),
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum OperationTypeHelper {
    Insert,
    Update,
    Replace,
    Delete,
    Drop,
    Rename,
    DropDatabase,
    Invalidate,
}

#[derive(Serialize, Deserialize)]
#[serde(untagged)]
enum OperationTypeWrapper<'a> {
    Known(OperationTypeHelper),
    Unknown(&'a str),
}

impl<'a> From<&'a OperationType> for OperationTypeWrapper<'a> {
    fn from(src: &'a OperationType) -> Self {
        match src {
            OperationType::Insert => Self::Known(OperationTypeHelper::Insert),
            OperationType::Update => Self::Known(OperationTypeHelper::Update),
            OperationType::Replace => Self::Known(OperationTypeHelper::Replace),
            OperationType::Delete => Self::Known(OperationTypeHelper::Delete),
            OperationType::Drop => Self::Known(OperationTypeHelper::Drop),
            OperationType::Rename => Self::Known(OperationTypeHelper::Rename),
            OperationType::DropDatabase => Self::Known(OperationTypeHelper::DropDatabase),
            OperationType::Invalidate => Self::Known(OperationTypeHelper::Invalidate),
            OperationType::Other(s) => Self::Unknown(s),
        }
    }
}

impl From<OperationTypeWrapper<'_>> for OperationType {
    fn from(src: OperationTypeWrapper) -> Self {
        match src {
            OperationTypeWrapper::Known(h) => match h {
                OperationTypeHelper::Insert => Self::Insert,
                OperationTypeHelper::Update => Self::Update,
                OperationTypeHelper::Replace => Self::Replace,
                OperationTypeHelper::Delete => Self::Delete,
                OperationTypeHelper::Drop => Self::Drop,
                OperationTypeHelper::Rename => Self::Rename,
                OperationTypeHelper::DropDatabase => Self::DropDatabase,
                OperationTypeHelper::Invalidate => Self::Invalidate,
            },
            OperationTypeWrapper::Unknown(s) => Self::Other(s.to_string()),
        }
    }
}

impl<'de> Deserialize<'de> for OperationType {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        OperationTypeWrapper::deserialize(deserializer).map(OperationType::from)
    }
}

impl Serialize for OperationType {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        OperationTypeWrapper::serialize(&self.into(), serializer)
    }
}

/// Identifies the collection or database on which an event occurred.
#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub struct ChangeNamespace {
    /// The name of the database in which the change occurred.
    pub db: String,

    /// The name of the collection in which the change occurred.
    pub coll: Option<String>,
}

/// Identifies the type of object for a `create` event.
#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub enum ChangeNamespaceType {
    /// A collection with no special options set.
    Collection,
    /// A timeseries collection.
    Timeseries,
    /// A view collection.
    View,
    /// Forward compatibility fallthrough.
    #[serde(untagged)]
    Other(String),
}
