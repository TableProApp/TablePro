use std::time::Duration;

use crate::bson::doc;
use macro_magic::export_tokens;
use serde::{Deserialize, Serialize};
use serde_with::skip_serializing_none;
use typed_builder::TypedBuilder;

use crate::{
    bson::{Bson, Document},
    concern::{ReadConcern, WriteConcern},
    options::{Collation, CursorType},
    selection_criteria::SelectionCriteria,
    serde_util,
};

/// These are the valid options for creating a [`Database`](../struct.Database.html) with
/// [`Client::database_with_options`](../struct.Client.html#method.database_with_options).
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct DatabaseOptions {
    /// The default read preference for operations.
    pub selection_criteria: Option<SelectionCriteria>,

    /// The default read concern for operations.
    pub read_concern: Option<ReadConcern>,

    /// The default write concern for operations.
    pub write_concern: Option<WriteConcern>,
}

/// These are the valid options for creating a collection with
/// [`Database::create_collection`](../struct.Database.html#method.create_collection).
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct CreateCollectionOptions {
    /// Whether the collection should be capped. If true, `size` must also be set.
    pub capped: Option<bool>,

    /// The maximum size (in bytes) for a capped collection. This option is ignored if `capped` is
    /// not set to true.
    #[serde(
        serialize_with = "serde_util::serialize_u64_option_as_i64",
        deserialize_with = "serde_util::deserialize_option_u64_from_bson_number",
        default
    )]
    pub size: Option<u64>,

    /// The maximum number of documents in a capped collection. The `size` limit takes precedence
    /// over this option. If a capped collection reaches the size limit before it reaches the
    /// maximum number of documents, MongoDB removes old documents.
    #[serde(serialize_with = "serde_util::serialize_u64_option_as_i64")]
    pub max: Option<u64>,

    /// The storage engine that the collection should use. The value should take the following
    /// form:
    ///
    /// `{ <storage-engine-name>: <options> }`
    pub storage_engine: Option<Document>,

    /// Specifies a validator to restrict the schema of documents which can exist in the
    /// collection. Expressions can be specified using any query operators except `$near`,
    /// `$nearSphere`, `$text`, and `$where`.
    pub validator: Option<Document>,

    /// Specifies how strictly the database should apply the validation rules to existing documents
    /// during an update.
    pub validation_level: Option<ValidationLevel>,

    /// Specifies whether the database should return an error or simply raise a warning if inserted
    /// documents do not pass the validation.
    pub validation_action: Option<ValidationAction>,

    /// The name of the source collection or view to base this view on. If specified, this will
    /// cause a view to be created rather than a collection.
    pub view_on: Option<String>,

    /// An array that consists of the aggregation pipeline stages to run against `view_on` to
    /// determine the contents of the view.
    pub pipeline: Option<Vec<Document>>,

    /// The default collation for the collection or view.
    pub collation: Option<Collation>,

    /// The write concern for the operation.
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// The default configuration for indexes created on this collection, including the _id index.
    pub index_option_defaults: Option<IndexOptionDefaults>,

    /// An object containing options for creating time series collections. See the [`create`
    /// command documentation](https://www.mongodb.com/docs/manual/reference/command/create/) for
    /// supported options, and the [Time Series Collections documentation](
    /// https://www.mongodb.com/docs/manual/core/timeseries-collections/) for more information.
    ///
    /// This feature is only available on server versions 5.0 and above.
    pub timeseries: Option<TimeseriesOptions>,

    /// Used to automatically delete documents in time series collections. See the [`create`
    /// command documentation](https://www.mongodb.com/docs/manual/reference/command/create/) for more
    /// information.
    #[serde(default, with = "serde_util::duration_option_as_int_seconds")]
    pub expire_after_seconds: Option<Duration>,

    /// Options for supporting change stream pre- and post-images.
    pub change_stream_pre_and_post_images: Option<ChangeStreamPreAndPostImages>,

    /// Options for clustered collections. This option is only available on server versions 5.3+.
    #[serde(default, deserialize_with = "ClusteredIndex::deserialize_self_or_true")]
    pub clustered_index: Option<ClusteredIndex>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,

    /// Map of encrypted fields for the created collection.
    #[cfg(feature = "in-use-encryption")]
    pub encrypted_fields: Option<Document>,
}

/// Specifies how strictly the database should apply validation rules to existing documents during
/// an update.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub enum ValidationLevel {
    /// Perform no validation for inserts and updates.
    Off,
    /// Perform validation on all inserts and updates.
    Strict,
    /// Perform validation on inserts as well as updates on existing valid documents, but do not
    /// perform validations on updates on existing invalid documents.
    Moderate,
}

/// Specifies whether the database should return an error or simply raise a warning if inserted
/// documents do not pass the validation.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub enum ValidationAction {
    /// Return an error if inserted documents do not pass the validation.
    Error,
    /// Raise a warning if inserted documents do not pass the validation.
    Warn,
}

/// Specifies options for a clustered collection.  Some fields have required values; the `Default`
/// impl uses those values.
#[skip_serializing_none]
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ClusteredIndex {
    /// Key pattern; currently required to be `{_id: 1}`.
    pub key: Document,

    /// Currently required to be `true`.
    pub unique: bool,

    /// Optional; will be automatically generated if not provided.
    pub name: Option<String>,

    /// Optional; currently must be `2` if provided.
    pub v: Option<i32>,
}

impl Default for ClusteredIndex {
    fn default() -> Self {
        Self {
            key: doc! { "_id": 1 },
            unique: true,
            name: None,
            v: None,
        }
    }
}

impl ClusteredIndex {
    /// When creating a time-series collection on MongoDB Atlas the `clusteredIndex` field of the
    /// collection options is given as `true` instead of as an object that deserializes to
    /// `ClusteredIndex`. This custom deserializer handles that case by using the default value for
    /// `ClusteredIndex`.
    fn deserialize_self_or_true<'de, D>(deserializer: D) -> Result<Option<ClusteredIndex>, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Debug, Deserialize)]
        #[serde(untagged)]
        enum ValueUnion {
            Bool(bool),
            ClusteredIndex(ClusteredIndex),
        }

        let value_option: Option<ValueUnion> = Deserialize::deserialize(deserializer)?;
        value_option
            .map(|value| match value {
                ValueUnion::Bool(true) => Ok(ClusteredIndex::default()),
                ValueUnion::Bool(false) => Err(serde::de::Error::custom(
                    "if clusteredIndex is a boolean it must be `true`",
                )),
                ValueUnion::ClusteredIndex(value) => Ok(value),
            })
            .transpose()
    }
}

/// Specifies default configuration for indexes created on a collection, including the _id index.
#[derive(Clone, Debug, TypedBuilder, PartialEq, Serialize, Deserialize)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct IndexOptionDefaults {
    /// The `storageEngine` document should be in the following form:
    ///
    /// `{ <storage-engine-name>: <options> }`
    pub storage_engine: Document,
}

/// Specifies options for creating a timeseries collection.
#[skip_serializing_none]
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, TypedBuilder)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct TimeseriesOptions {
    /// Name of the top-level field to be used for time. Inserted documents must have this field,
    /// and the field must be of the BSON UTC datetime type.
    pub time_field: String,

    /// Name of the top-level field describing the series. This field is used to group related data
    /// and may be of any BSON type, except for array. This name may not be the same as the
    /// timeField or _id.
    pub meta_field: Option<String>,

    /// The units you'd use to describe the expected interval between subsequent measurements for a
    /// time-series.  Defaults to `TimeseriesGranularity::Seconds` if unset.
    pub granularity: Option<TimeseriesGranularity>,

    /// The maximum time between timestamps in the same bucket. This value must be between 1 and
    /// 31,536,000 seconds. If this value is set, the same value should be set for
    /// `bucket_rounding` and `granularity` should not be set.
    ///
    /// This option is only available on MongoDB 6.3+.
    #[serde(
        default,
        with = "serde_util::duration_option_as_int_seconds",
        rename = "bucketMaxSpanSeconds"
    )]
    pub bucket_max_span: Option<Duration>,

    /// The time interval that determines the starting timestamp for a new bucket. When a document
    /// requires a new bucket, MongoDB rounds down the document's timestamp value by this interval
    /// to set the minimum time for the bucket.  If this value is set, the same value should be set
    /// for `bucket_max_span` and `granularity` should not be set.
    ///
    /// This option is only available on MongoDB 6.3+.
    #[serde(
        default,
        with = "serde_util::duration_option_as_int_seconds",
        rename = "bucketRoundingSeconds"
    )]
    pub bucket_rounding: Option<Duration>,
}

/// The units you'd use to describe the expected interval between subsequent measurements for a
/// time-series.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub enum TimeseriesGranularity {
    /// The expected interval between subsequent measurements is in seconds.
    Seconds,
    /// The expected interval between subsequent measurements is in minutes.
    Minutes,
    /// The expected interval between subsequent measurements is in hours.
    Hours,
}

/// Specifies the options to a [`Database::drop`](crate::Database::drop) operation.
#[derive(Clone, Debug, Default, TypedBuilder, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct DropDatabaseOptions {
    /// The write concern for the operation.
    #[serde(skip)]
    pub write_concern: Option<WriteConcern>,
}

/// Specifies the options to a
/// [`Database::list_collections`](../struct.Database.html#method.list_collections) operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct ListCollectionsOptions {
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

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,

    /// Filters the list operation.
    pub filter: Option<Document>,

    /// When `true` and used with
    /// [`list_collection_names`](crate::Database::list_collection_names), the command returns
    /// only those collections for which the user has privileges.  When used with
    /// [`list_collections`](crate::Database::list_collections) this option has no effect.
    pub authorized_collections: Option<bool>,
}

/// Specifies the options to a [`Client::list_databases`](crate::Client::list_databases) operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct ListDatabasesOptions {
    /// Determines which databases to return based on the user's access privileges. This option is
    /// only supported on server versions 4.0.5+.
    pub authorized_databases: Option<bool>,

    /// Tags the query with an arbitrary [`Bson`] value to help trace the operation through the
    /// database profiler, currentOp and logs.
    pub comment: Option<Bson>,

    /// Filters the query.
    pub filter: Option<Document>,
}

/// Specifies how change stream pre- and post-images should be supported.
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder, Serialize)]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct ChangeStreamPreAndPostImages {
    /// If `true`, change streams will be able to include pre- and post-images.
    pub enabled: bool,
}

/// Specifies the options to a
/// [`Database::run_command`](crate::Database::run_command) operation.
#[derive(Clone, Debug, Default, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
#[export_tokens]
pub struct RunCommandOptions {
    /// The default read preference for operations.
    pub selection_criteria: Option<SelectionCriteria>,
}

/// Specifies the options to a
/// [`Database::run_cursor_command`](crate::Database::run_cursor_command) operation.
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[serde(default)]
#[non_exhaustive]
#[export_tokens]
pub struct RunCursorCommandOptions {
    /// The default read preference for operations.
    pub selection_criteria: Option<SelectionCriteria>,
    /// The type of cursor to return.
    pub cursor_type: Option<CursorType>,
    /// Number of documents to return per batch.
    pub batch_size: Option<u32>,
    #[serde(rename = "maxtime", alias = "maxTimeMS")]
    #[serde(deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis")]
    /// Optional non-negative integer value. Use this value to configure the maxTimeMS option sent
    /// on subsequent getMore commands.
    pub max_time: Option<Duration>,
    /// Optional BSON value. Use this value to configure the comment option sent on subsequent
    /// getMore commands.
    pub comment: Option<Bson>,
}
