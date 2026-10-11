use std::time::Duration;

use macro_magic::export_tokens;
use serde::{de::Error, Deserialize, Deserializer, Serialize, Serializer};
use serde_with::skip_serializing_none;
use typed_builder::TypedBuilder;

use crate::{
    bson::{doc, Bson, Document, RawBson, RawDocumentBuf},
    concern::{ReadConcern, WriteConcern},
    error::Result,
    options::Collation,
    selection_criteria::SelectionCriteria,
    serde_util,
};

/// These are the valid options for creating a [`Collection`](crate::Collection) with
/// [`Database::collection_with_options`](crate::Database::collection_with_options).
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct CollectionOptions {
    /// The default read preference for operations.
    pub selection_criteria: Option<SelectionCriteria>,

    /// The default read concern for operations.
    pub read_concern: Option<ReadConcern>,

    /// The default write concern for operations.
    pub write_concern: Option<WriteConcern>,
}

/// Specifies whether a
/// [`Collection::find_one_and_replace`](../struct.Collection.html#method.find_one_and_replace) and
/// [`Collection::find_one_and_update`](../struct.Collection.html#method.find_one_and_update)
/// operation should return the document before or after modification.
#[derive(Clone, Debug)]
#[non_exhaustive]
pub enum ReturnDocument {
    /// Return the document after modification.
    After,
    /// Return the document before modification.
    Before,
}

impl ReturnDocument {
    pub(crate) fn as_bool(&self) -> bool {
        match self {
            ReturnDocument::After => true,
            ReturnDocument::Before => false,
        }
    }
}

impl<'de> Deserialize<'de> for ReturnDocument {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        match s.to_lowercase().as_str() {
            "after" => Ok(ReturnDocument::After),
            "before" => Ok(ReturnDocument::Before),
            other => Err(D::Error::custom(format!(
                "Unknown return document value: {other}"
            ))),
        }
    }
}

/// Specifies the index to use for an operation.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(untagged)]
#[non_exhaustive]
pub enum Hint {
    /// Specifies the keys of the index to use.
    Keys(Document),
    /// Specifies the name of the index to use.
    Name(String),
}

impl Hint {
    pub(crate) fn to_raw_bson(&self) -> Result<RawBson> {
        Ok(match self {
            Hint::Keys(ref d) => RawBson::Document(RawDocumentBuf::try_from(d)?),
            Hint::Name(ref s) => RawBson::String(s.clone()),
        })
    }
}

/// Specifies the type of cursor to return from a find operation.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub enum CursorType {
    /// Default; close the cursor after the last document is received from the server.
    NonTailable,

    /// Do not close the cursor after the last document is received from the server. If more
    /// results become available later, the cursor will return them.
    Tailable,

    /// Similar to `Tailable`, except that the cursor should block on receiving more results if
    /// none are available.
    TailableAwait,
}

/// Specifies the options to a
/// [`Collection::insert_one`](../struct.Collection.html#method.insert_one) operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct InsertOneOptions {
    /// Opt out of document-level validation.
    pub bypass_document_validation: Option<bool>,

    /// The write concern for the operation.
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

/// Specifies the options to a
/// [`Collection::insert_many`](../struct.Collection.html#method.insert_many) operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, TypedBuilder, Serialize, Deserialize)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
#[export_tokens]
pub struct InsertManyOptions {
    /// Opt out of document-level validation.
    pub bypass_document_validation: Option<bool>,

    /// If true, when an insert fails, return without performing the remaining writes. If false,
    /// when a write fails, continue with the remaining writes, if any.
    ///
    /// Defaults to true.
    pub ordered: Option<bool>,

    /// The write concern for the operation.
    #[serde(skip)]
    pub write_concern: Option<WriteConcern>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

impl InsertManyOptions {
    pub(crate) fn from_insert_one_options(options: InsertOneOptions) -> Self {
        Self {
            bypass_document_validation: options.bypass_document_validation,
            ordered: None,
            write_concern: options.write_concern,
            comment: options.comment,
        }
    }
}

/// Enum modeling the modifications to apply during an update.
/// For details, see the official MongoDB
/// [documentation](https://www.mongodb.com/docs/manual/reference/command/update/#update-command-behaviors)
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(untagged)]
#[non_exhaustive]
pub enum UpdateModifications {
    /// A document that contains only update operator expressions.
    Document(Document),

    /// An aggregation pipeline.
    Pipeline(Vec<Document>),
}

impl From<Document> for UpdateModifications {
    fn from(item: Document) -> Self {
        UpdateModifications::Document(item)
    }
}

impl From<Vec<Document>> for UpdateModifications {
    fn from(item: Vec<Document>) -> Self {
        UpdateModifications::Pipeline(item)
    }
}

/// Specifies the options to a
/// [`Collection::update_one`](../struct.Collection.html#method.update_one) or
/// [`Collection::update_many`](../struct.Collection.html#method.update_many) operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct UpdateOptions {
    /// A set of filters specifying to which array elements an update should apply.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/reference/command/update/) for
    /// more information on array filters.
    pub array_filters: Option<Vec<Document>>,

    /// Opt out of document-level validation.
    pub bypass_document_validation: Option<bool>,

    /// If true, insert a document if no matching document is found.
    pub upsert: Option<bool>,

    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// A document or string that specifies the index to use to support the query predicate.
    ///
    /// See the official MongoDB
    /// [documentation](https://www.mongodb.com/docs/manual/reference/command/update/#ex-update-command-hint) for examples.
    pub hint: Option<Hint>,

    /// The write concern for the operation.
    pub write_concern: Option<WriteConcern>,

    /// Map of parameter names and values. Values must be constant or closed
    /// expressions that do not reference document fields. Parameters can then be
    /// accessed as variables in an aggregate expression context (e.g. "$$var").
    ///
    /// Only available in MongoDB 5.0+.
    #[serde(rename = "let")]
    pub let_vars: Option<Document>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,

    /// Specify which document the operation updates if the query matches multiple
    /// documents. The first document matched by the sort order will be updated.
    ///
    /// Only available in MongoDB 8.0+.
    pub sort: Option<Document>,
}

impl UpdateOptions {
    pub(crate) fn from_replace_options(options: ReplaceOptions) -> Self {
        Self {
            bypass_document_validation: options.bypass_document_validation,
            upsert: options.upsert,
            hint: options.hint,
            write_concern: options.write_concern,
            collation: options.collation,
            let_vars: options.let_vars,
            comment: options.comment,
            sort: options.sort,
            ..Default::default()
        }
    }
}

/// Specifies the options to a
/// [`Collection::replace_one`](../struct.Collection.html#method.replace_one) operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct ReplaceOptions {
    /// Opt out of document-level validation.
    pub bypass_document_validation: Option<bool>,

    /// If true, insert a document if no matching document is found.
    pub upsert: Option<bool>,

    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// A document or string that specifies the index to use to support the query predicate.
    ///
    /// See the official MongoDB
    /// [documentation](https://www.mongodb.com/docs/manual/reference/command/update/#ex-update-command-hint) for examples.
    pub hint: Option<Hint>,

    /// The write concern for the operation.
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// Map of parameter names and values. Values must be constant or closed
    /// expressions that do not reference document fields. Parameters can then be
    /// accessed as variables in an aggregate expression context (e.g. "$$var").
    ///
    /// Only available in MongoDB 5.0+.
    #[serde(rename = "let")]
    pub let_vars: Option<Document>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,

    /// Specify which document the operation replaces if the query matches multiple
    /// documents. The first document matched by the sort order will be replaced.
    ///
    /// Only available in MongoDB 8.0+.
    pub sort: Option<Document>,
}

/// Specifies the options to a
/// [`Collection::delete_one`](../struct.Collection.html#method.delete_one) or
/// [`Collection::delete_many`](../struct.Collection.html#method.delete_many) operation.
#[serde_with::skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct DeleteOptions {
    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// The write concern for the operation.
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// The index to use for the operation.
    pub hint: Option<Hint>,

    /// Map of parameter names and values. Values must be constant or closed
    /// expressions that do not reference document fields. Parameters can then be
    /// accessed as variables in an aggregate expression context (e.g. "$$var").
    ///
    /// Only available in MongoDB 5.0+.
    #[serde(rename = "let")]
    pub let_vars: Option<Document>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

/// Specifies the options to a
/// [`Collection::find_one_and_delete`](../struct.Collection.html#method.find_one_and_delete)
/// operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct FindOneAndDeleteOptions {
    /// The maximum amount of time to allow the query to run.
    ///
    /// This options maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    pub max_time: Option<Duration>,

    /// Limits the fields of the document being returned.
    pub projection: Option<Document>,

    /// The order of the documents for the purposes of the operation.
    pub sort: Option<Document>,

    /// The level of the write concern
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// The index to use for the operation.
    pub hint: Option<Hint>,

    /// Map of parameter names and values. Values must be constant or closed
    /// expressions that do not reference document fields. Parameters can then be
    /// accessed as variables in an aggregate expression context (e.g. "$$var").
    ///
    /// Only available in MongoDB 5.0+.
    #[serde(rename = "let")]
    pub let_vars: Option<Document>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

/// Specifies the options to a
/// [`Collection::find_one_and_replace`](../struct.Collection.html#method.find_one_and_replace)
/// operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
#[export_tokens]
pub struct FindOneAndReplaceOptions {
    /// Opt out of document-level validation.
    pub bypass_document_validation: Option<bool>,

    /// The maximum amount of time to allow the query to run.
    ///
    /// This options maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    pub max_time: Option<Duration>,

    /// Limits the fields of the document being returned.
    pub projection: Option<Document>,

    /// Whether the operation should return the document before or after modification.
    pub return_document: Option<ReturnDocument>,

    /// The order of the documents for the purposes of the operation.
    pub sort: Option<Document>,

    /// If true, insert a document if no matching document is found.
    pub upsert: Option<bool>,

    /// The level of the write concern
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// The index to use for the operation.
    pub hint: Option<Hint>,

    /// Map of parameter names and values. Values must be constant or closed
    /// expressions that do not reference document fields. Parameters can then be
    /// accessed as variables in an aggregate expression context (e.g. "$$var").
    ///
    /// Only available in MongoDB 5.0+.
    #[serde(rename = "let")]
    pub let_vars: Option<Document>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

/// Specifies the options to a
/// [`Collection::find_one_and_update`](../struct.Collection.html#method.find_one_and_update)
/// operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct FindOneAndUpdateOptions {
    /// A set of filters specifying to which array elements an update should apply.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/reference/command/update/) for
    /// more information on array filters.
    pub array_filters: Option<Vec<Document>>,

    /// Opt out of document-level validation.
    pub bypass_document_validation: Option<bool>,

    /// The maximum amount of time to allow the query to run.
    ///
    /// This options maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    pub max_time: Option<Duration>,

    /// Limits the fields of the document being returned.
    pub projection: Option<Document>,

    /// Whether the operation should return the document before or after modification.
    pub return_document: Option<ReturnDocument>,

    /// The order of the documents for the purposes of the operation.
    pub sort: Option<Document>,

    /// If true, insert a document if no matching document is found.
    pub upsert: Option<bool>,

    /// The level of the write concern
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// The index to use for the operation.
    pub hint: Option<Hint>,

    /// Map of parameter names and values. Values must be constant or closed
    /// expressions that do not reference document fields. Parameters can then be
    /// accessed as variables in an aggregate expression context (e.g. "$$var").
    ///
    /// Only available in MongoDB 5.0+.
    #[serde(rename = "let")]
    pub let_vars: Option<Document>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

/// Specifies the options to a [`Collection::aggregate`](../struct.Collection.html#method.aggregate)
/// operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct AggregateOptions {
    /// Enables writing to temporary files. When set to true, aggregation stages can write data to
    /// the _tmp subdirectory in the dbPath directory.
    pub allow_disk_use: Option<bool>,

    /// The number of documents the server should return per cursor batch.
    ///
    /// Note that this does not have any affect on the documents that are returned by a cursor,
    /// only the number of documents kept in memory at a given time (and by extension, the
    /// number of round trips needed to return the entire set of documents returned by the
    /// query).
    #[serde(
        serialize_with = "serde_util::serialize_u32_option_as_batch_size",
        rename(serialize = "cursor")
    )]
    pub batch_size: Option<u32>,

    /// Opt out of document-level validation.
    pub bypass_document_validation: Option<bool>,

    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,

    /// The index to use for the operation.
    pub hint: Option<Hint>,

    /// The maximum amount of time for the server to wait on new documents to satisfy a tailable
    /// await cursor query.
    ///
    /// This option will have no effect on non-tailable cursors that result from this operation.
    #[serde(
        skip_serializing,
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis",
        default
    )]
    pub max_await_time: Option<Duration>,

    /// The maximum amount of time to allow the query to run.
    ///
    /// This options maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    #[serde(
        serialize_with = "serde_util::serialize_duration_option_as_int_millis",
        rename = "maxTimeMS",
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis",
        default
    )]
    pub max_time: Option<Duration>,

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
    #[serde(rename = "readPreference")]
    pub selection_criteria: Option<SelectionCriteria>,

    /// The write concern to use for the operation.
    ///
    /// If none is specified, the write concern defined on the object executing this operation will
    /// be used.
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// A document with any amount of parameter names, each followed by definitions of constants in
    /// the MQL Aggregate Expression language.  Each parameter name is then usable to access the
    /// value of the corresponding MQL Expression with the "$$" syntax within Aggregate Expression
    /// contexts.
    ///
    /// This feature is only available on server versions 5.0 and above.
    #[serde(rename = "let")]
    pub let_vars: Option<Document>,
}

/// Specifies the options to a
/// [`Collection::count_documents`](../struct.Collection.html#method.count_documents) operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct CountOptions {
    /// The index to use for the operation.
    pub hint: Option<Hint>,

    /// The maximum number of documents to count.
    pub limit: Option<u64>,

    /// The maximum amount of time to allow the query to run.
    ///
    /// This options maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    #[serde(
        default,
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis"
    )]
    pub max_time: Option<Duration>,

    /// The number of documents to skip before counting.
    pub skip: Option<u64>,

    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// The criteria used to select a server for this operation.
    ///
    /// If none specified, the default set on the collection will be used.
    pub selection_criteria: Option<SelectionCriteria>,

    /// The level of the read concern.
    #[serde(skip_serializing)]
    pub read_concern: Option<ReadConcern>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

// rustfmt tries to split the link up when it's all on one line, which breaks the link, so we wrap
// the link contents in whitespace to get it to render correctly.
//
/// Specifies the options to a
/// [
///  `Collection::estimated_document_count`
/// ](../struct.Collection.html#method.estimated_document_count) operation.
#[serde_with::skip_serializing_none]
#[derive(Debug, Default, Deserialize, TypedBuilder, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct EstimatedDocumentCountOptions {
    /// The maximum amount of time to allow the query to run.
    ///
    /// This options maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    #[serde(
        default,
        serialize_with = "serde_util::serialize_duration_option_as_int_millis",
        rename = "maxTimeMS",
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis"
    )]
    pub max_time: Option<Duration>,

    /// The criteria used to select a server for this operation.
    ///
    /// If none specified, the default set on the collection will be used.
    #[serde(skip_serializing)]
    pub selection_criteria: Option<SelectionCriteria>,

    /// The level of the read concern.
    #[serde(skip_serializing)]
    pub read_concern: Option<ReadConcern>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    ///
    /// On server versions between 4.4.0 and 4.4.14, only [`Bson::String`] values are supported.
    pub comment: Option<Bson>,
}

/// Specifies the options to a [`Collection::distinct`](../struct.Collection.html#method.distinct)
/// operation.
#[serde_with::skip_serializing_none]
#[derive(Debug, Default, Deserialize, TypedBuilder, Serialize, Clone)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
#[export_tokens]
pub struct DistinctOptions {
    /// The maximum amount of time to allow the query to run.
    ///
    /// This options maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    #[serde(
        default,
        serialize_with = "serde_util::serialize_duration_option_as_int_millis",
        rename = "maxTimeMS",
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis"
    )]
    pub max_time: Option<Duration>,

    /// The criteria used to select a server for this operation.
    ///
    /// If none specified, the default set on the collection will be used.
    #[serde(skip_serializing)]
    pub selection_criteria: Option<SelectionCriteria>,

    /// The level of the read concern.
    #[serde(skip_serializing)]
    pub read_concern: Option<ReadConcern>,

    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,

    /// A document or string that specifies the index to use to support the query predicate.
    /// Available on server versions 7.1+.
    pub hint: Option<Hint>,
}

/// Specifies the options to a [`Collection::find`](../struct.Collection.html#method.find)
/// operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
#[export_tokens]
pub struct FindOptions {
    /// Enables writing to temporary files by the server. When set to true, the find operation can
    /// write data to the _tmp subdirectory in the dbPath directory.
    pub allow_disk_use: Option<bool>,

    /// If true, partial results will be returned from a mongos rather than an error being
    /// returned if one or more shards is down.
    pub allow_partial_results: Option<bool>,

    /// The number of documents the server should return per cursor batch.
    ///
    /// Note that this does not have any affect on the documents that are returned by a cursor,
    /// only the number of documents kept in memory at a given time (and by extension, the
    /// number of round trips needed to return the entire set of documents returned by the
    /// query.
    #[serde(serialize_with = "serde_util::serialize_u32_option_as_i32")]
    pub batch_size: Option<u32>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,

    /// The type of cursor to return.
    #[serde(skip)]
    pub cursor_type: Option<CursorType>,

    /// The index to use for the operation.
    pub hint: Option<Hint>,

    /// The maximum number of documents to query.
    /// If a negative number is specified, the documents will be returned in a single batch limited
    /// in number by the positive value of the specified limit.
    #[serde(serialize_with = "serialize_absolute_value")]
    pub limit: Option<i64>,

    /// The exclusive upper bound for a specific index.
    pub max: Option<Document>,

    /// The maximum amount of time for the server to wait on new documents to satisfy a tailable
    /// cursor query. If the cursor is not tailable, this option is ignored.
    #[serde(skip)]
    pub max_await_time: Option<Duration>,

    /// Maximum number of documents or index keys to scan when executing the query.
    #[deprecated = "This option is not supported by any MongoDB server version compatible with \
                    the driver. Use the `max_time` option instead."]
    #[serde(serialize_with = "serde_util::serialize_u64_option_as_i64")]
    pub max_scan: Option<u64>,

    /// The maximum amount of time to allow the query to run.
    ///
    /// This options maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    #[serde(
        rename = "maxTimeMS",
        serialize_with = "serde_util::serialize_duration_option_as_int_millis"
    )]
    pub max_time: Option<Duration>,

    /// The inclusive lower bound for a specific index.
    pub min: Option<Document>,

    /// Whether the server should close the cursor after a period of inactivity.
    pub no_cursor_timeout: Option<bool>,

    /// The [projection document](https://www.mongodb.com/docs/manual/reference/method/db.collection.find/#projection)
    /// to determine which fields to include in the returned document.
    ///
    /// Specifying this option may cause deserialization errors if the returned fields do not fit
    /// the schema of the collection's generic type. The
    /// [`clone_with_type`](crate::Collection::clone_with_type) method can be used to retrieve a
    /// handle to the collection with a different generic type configured.
    pub projection: Option<Document>,

    /// The read concern to use for this find query.
    ///
    /// If none specified, the default set on the collection will be used.
    #[serde(skip_serializing)]
    pub read_concern: Option<ReadConcern>,

    /// Whether to return only the index keys in the documents.
    pub return_key: Option<bool>,

    /// The criteria used to select a server for this find query.
    ///
    /// If none specified, the default set on the collection will be used.
    #[serde(skip)]
    pub selection_criteria: Option<SelectionCriteria>,

    /// Whether to return the record identifier for each document. If true, adds a `$recordId`
    /// field to the returned documents.
    ///
    /// Defaults to false.
    pub show_record_id: Option<bool>,

    /// The number of documents to skip before counting.
    #[serde(serialize_with = "serde_util::serialize_u64_option_as_i64")]
    pub skip: Option<u64>,

    /// The order of the documents for the purposes of the operation.
    pub sort: Option<Document>,

    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// Map of parameter names and values. Values must be constant or closed
    /// expressions that do not reference document fields. Parameters can then be
    /// accessed as variables in an aggregate expression context (e.g. "$$var").
    ///
    /// Only available in MongoDB 5.0+.
    #[serde(rename = "let")]
    pub let_vars: Option<Document>,
}

impl From<FindOneOptions> for FindOptions {
    fn from(options: FindOneOptions) -> Self {
        FindOptions {
            allow_disk_use: None,
            allow_partial_results: options.allow_partial_results,
            collation: options.collation,
            comment: options.comment,
            hint: options.hint,
            max: options.max,
            #[allow(deprecated)]
            max_scan: options.max_scan,
            max_time: options.max_time,
            min: options.min,
            projection: options.projection,
            read_concern: options.read_concern,
            return_key: options.return_key,
            selection_criteria: options.selection_criteria,
            show_record_id: options.show_record_id,
            skip: options.skip,
            batch_size: None,
            cursor_type: None,
            limit: Some(-1),
            max_await_time: None,
            no_cursor_timeout: None,
            sort: options.sort,
            let_vars: options.let_vars,
        }
    }
}

/// Custom serializer used to serialize limit as its absolute value.
fn serialize_absolute_value<S>(
    val: &Option<i64>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error>
where
    S: Serializer,
{
    match val {
        Some(v) => serializer.serialize_i64(v.abs()),
        None => serializer.serialize_none(),
    }
}

/// Specifies the options to a [`Collection::find_one`](../struct.Collection.html#method.find_one)
/// operation.
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct FindOneOptions {
    /// If true, partial results will be returned from a mongos rather than an error being
    /// returned if one or more shards is down.
    pub allow_partial_results: Option<bool>,

    /// The collation to use for the operation.
    ///
    /// See the [documentation](https://www.mongodb.com/docs/manual/reference/collation/) for more
    /// information on how to use this option.
    pub collation: Option<Collation>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,

    /// The index to use for the operation.
    pub hint: Option<Hint>,

    /// The exclusive upper bound for a specific index.
    pub max: Option<Document>,

    /// Maximum number of documents or index keys to scan when executing the query.
    #[deprecated = "This option is not supported by any MongoDB server version compatible with \
                    the driver. Use the `max_time` option instead."]
    #[serde(serialize_with = "bson_util::serialize_u64_option_as_i64")]
    pub max_scan: Option<u64>,

    /// The maximum amount of time to allow the query to run.
    ///
    /// This options maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    #[serde(
        default,
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis"
    )]
    pub max_time: Option<Duration>,

    /// The inclusive lower bound for a specific index.
    pub min: Option<Document>,

    /// Limits the fields of the document being returned.
    pub projection: Option<Document>,

    /// The read concern to use for this find query.
    ///
    /// If none specified, the default set on the collection will be used.
    #[serde(skip_serializing)]
    pub read_concern: Option<ReadConcern>,

    /// Whether to return only the index keys in the documents.
    pub return_key: Option<bool>,

    /// The criteria used to select a server for this find query.
    ///
    /// If none specified, the default set on the collection will be used.
    pub selection_criteria: Option<SelectionCriteria>,

    /// Whether to return the record identifier for each document.
    pub show_record_id: Option<bool>,

    /// The number of documents to skip before counting.
    #[serde(serialize_with = "bson_util::serialize_u64_option_as_i64")]
    pub skip: Option<u64>,

    /// The order of the documents for the purposes of the operation.
    pub sort: Option<Document>,

    /// Map of parameter names and values. Values must be constant or closed
    /// expressions that do not reference document fields. Parameters can then be
    /// accessed as variables in an aggregate expression context (e.g. "$$var").
    ///
    /// Only available in MongoDB 5.0+.
    #[serde(rename = "let")]
    pub let_vars: Option<Document>,
}

/// Specifies the options to a
/// [`Collection::create_index`](../struct.Collection.html#method.create_index) or [`Collection::
/// create_indexes`](../struct.Collection.html#method.create_indexes) operation.
///
/// For more information, see [`createIndexes`](https://www.mongodb.com/docs/manual/reference/command/createIndexes/).
#[serde_with::skip_serializing_none]
#[derive(Clone, Debug, Default, TypedBuilder, Serialize)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[non_exhaustive]
#[export_tokens]
pub struct CreateIndexOptions {
    /// Specify the commit quorum needed to mark an `index` as ready.
    pub commit_quorum: Option<CommitQuorum>,

    /// The maximum amount of time to allow the index to build.
    ///
    /// This option maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    #[serde(
        rename = "maxTimeMS",
        default,
        serialize_with = "serde_util::serialize_duration_option_as_int_millis",
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis"
    )]
    pub max_time: Option<Duration>,

    /// The write concern for the operation.
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

/// Specifies the options to a [`Collection::drop`](../struct.Collection.html#method.drop)
/// operation.
#[serde_with::skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct DropCollectionOptions {
    /// The write concern for the operation.
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// Map of encrypted fields for the collection.
    // Serialization is skipped because the server doesn't accept this option; it's needed for
    // preprocessing.  Deserialization needs to remain because it's used in test files.
    #[cfg(feature = "in-use-encryption")]
    #[serde(skip_serializing)]
    pub encrypted_fields: Option<Document>,
}

/// Specifies the options to a
/// [`Collection::drop_index`](../struct.Collection.html#method.drop_index) or
/// [`Collection::drop_indexes`](../struct.Collection.html#method.drop_indexes) operation.
#[serde_with::skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct DropIndexOptions {
    /// The maximum amount of time to allow the index to drop.
    ///
    /// This option maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    #[serde(
        rename = "maxTimeMS",
        default,
        serialize_with = "serde_util::serialize_duration_option_as_int_millis",
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis"
    )]
    pub max_time: Option<Duration>,

    /// The write concern for the operation.
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

/// Specifies the options to a
/// [`Collection::list_indexes`](../struct.Collection.html#method.list_indexes) operation.
#[serde_with::skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct ListIndexesOptions {
    /// The maximum amount of time to search for the index.
    ///
    /// This option maps to the `maxTimeMS` MongoDB query option, so the duration will be sent
    /// across the wire as an integer number of milliseconds.
    #[serde(
        rename = "maxTimeMS",
        default,
        serialize_with = "serde_util::serialize_duration_option_as_int_millis",
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis"
    )]
    pub max_time: Option<Duration>,

    /// The number of indexes the server should return per cursor batch.
    #[serde(default, skip_serializing)]
    pub batch_size: Option<u32>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,
}

/// The minimum number of data-bearing voting replica set members (i.e. commit quorum), including
/// the primary, that must report a successful index build before the primary marks the indexes as
/// ready.
///
/// For more information, see the [documentation](https://www.mongodb.com/docs/manual/reference/command/createIndexes/#definition)
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub enum CommitQuorum {
    /// A specific number of voting replica set members. When set to 0, disables quorum voting.
    Nodes(u32),

    /// All data-bearing voting replica set members (default).
    VotingMembers,

    /// A simple majority of voting members.
    Majority,

    /// A replica set tag name.
    Custom(String),
}

impl Serialize for CommitQuorum {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            CommitQuorum::Nodes(n) => serde_util::serialize_u32_as_i32(n, serializer),
            CommitQuorum::VotingMembers => serializer.serialize_str("votingMembers"),
            CommitQuorum::Majority => serializer.serialize_str("majority"),
            CommitQuorum::Custom(s) => serializer.serialize_str(s),
        }
    }
}

impl<'de> Deserialize<'de> for CommitQuorum {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum IntOrString {
            Int(u32),
            String(String),
        }
        match IntOrString::deserialize(deserializer)? {
            IntOrString::String(s) => {
                if s == "votingMembers" {
                    Ok(CommitQuorum::VotingMembers)
                } else if s == "majority" {
                    Ok(CommitQuorum::Majority)
                } else {
                    Ok(CommitQuorum::Custom(s))
                }
            }
            IntOrString::Int(i) => Ok(CommitQuorum::Nodes(i)),
        }
    }
}
