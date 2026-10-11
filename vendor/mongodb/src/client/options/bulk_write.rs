use std::borrow::Borrow;

use macro_magic::export_tokens;
use serde::{Deserialize, Serialize};
use serde_with::skip_serializing_none;
use typed_builder::TypedBuilder;

use crate::{
    bson::{rawdoc, Array, Bson, Document, RawDocumentBuf},
    bson_compat::{cstr, serialize_to_raw_document_buf},
    bson_util::{
        extend_raw_document_buf,
        get_or_prepend_id_field,
        replacement_document_check,
        update_document_check,
    },
    error::{Error, Result},
    options::{UpdateModifications, WriteConcern},
    serde_util::serialize_bool_or_true,
    Collection,
    Namespace,
};

/// The supported options for [`bulk_write`](crate::Client::bulk_write).
#[skip_serializing_none]
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
#[export_tokens]
pub struct BulkWriteOptions {
    /// Whether the operations should be performed in the order in which they were specified. If
    /// true, no more writes will be performed if a single write fails. If false, writes will
    /// continue to be attempted if a single write fails.
    ///
    /// Defaults to true.
    #[serialize_always]
    #[serde(serialize_with = "serialize_bool_or_true")]
    pub ordered: Option<bool>,

    /// Whether document-level validation should be bypassed.
    ///
    /// Defaults to false.
    pub bypass_document_validation: Option<bool>,

    /// An arbitrary comment to help trace the operation through the database profiler, currentOp
    /// and logs.
    pub comment: Option<Bson>,

    /// A map of parameter names and values to apply to all operations within the bulk write.
    /// Values must be constant or closed expressions that do not reference document fields.
    /// Parameters can then be accessed as variables in an aggregate expression context (e.g.
    /// "$$var").
    #[serde(rename = "let")]
    pub let_vars: Option<Document>,

    /// The write concern to use for this operation.
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,
}

/// A single write to be performed within a [`bulk_write`](crate::Client::bulk_write) operation.
#[skip_serializing_none]
#[derive(Clone, Debug, Serialize)]
#[serde(untagged)]
#[non_exhaustive]
#[allow(missing_docs)]
pub enum WriteModel {
    InsertOne(InsertOneModel),
    UpdateOne(UpdateOneModel),
    UpdateMany(UpdateManyModel),
    ReplaceOne(ReplaceOneModel),
    DeleteOne(DeleteOneModel),
    DeleteMany(DeleteManyModel),
}

/// Inserts a single document.
#[skip_serializing_none]
#[derive(Clone, Debug, Serialize, TypedBuilder)]
#[cfg_attr(test, derive(Deserialize))]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct InsertOneModel {
    /// The namespace on which the insert should be performed.
    #[serde(skip_serializing)]
    #[builder(!default)]
    pub namespace: Namespace,

    /// The document to insert.
    #[builder(!default)]
    pub document: Document,
}

impl From<InsertOneModel> for WriteModel {
    fn from(model: InsertOneModel) -> Self {
        Self::InsertOne(model)
    }
}

/// Updates a single document.
#[skip_serializing_none]
#[derive(Clone, Debug, Serialize, TypedBuilder)]
#[cfg_attr(test, derive(Deserialize))]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct UpdateOneModel {
    /// The namespace on which the update should be performed.
    #[serde(skip_serializing)]
    #[builder(!default)]
    pub namespace: Namespace,

    /// The filter to use. The first document matching this filter will be updated.
    #[builder(!default)]
    pub filter: Document,

    /// The update to perform.
    #[serde(rename(serialize = "updateMods"))]
    #[builder(!default)]
    pub update: UpdateModifications,

    /// A set of filters specifying to which array elements an update should apply.
    pub array_filters: Option<Array>,

    /// The collation to use.
    pub collation: Option<Document>,

    /// The index to use. Specify either the index name as a string or the index key pattern. If
    /// specified, then the query system will only consider plans using the hinted index.
    pub hint: Option<Bson>,

    /// Whether a new document should be created if no document matches the filter.
    ///
    /// Defaults to false.
    pub upsert: Option<bool>,

    /// Specify which document the operation updates if the query matches multiple
    /// documents. The first document matched by the sort order will be updated.
    pub sort: Option<Document>,
}

impl From<UpdateOneModel> for WriteModel {
    fn from(model: UpdateOneModel) -> Self {
        Self::UpdateOne(model)
    }
}

/// Updates multiple documents.
#[skip_serializing_none]
#[derive(Clone, Debug, Serialize, TypedBuilder)]
#[cfg_attr(test, derive(Deserialize))]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct UpdateManyModel {
    /// The namespace on which the update should be performed.
    #[serde(skip_serializing)]
    #[builder(!default)]
    pub namespace: Namespace,

    /// The filter to use. All documents matching this filter will be updated.
    #[builder(!default)]
    pub filter: Document,

    /// The update to perform.
    #[serde(rename(serialize = "updateMods"))]
    #[builder(!default)]
    pub update: UpdateModifications,

    /// A set of filters specifying to which array elements an update should apply.
    pub array_filters: Option<Array>,

    /// The collation to use.
    pub collation: Option<Document>,

    /// The index to use. Specify either the index name as a string or the index key pattern. If
    /// specified, then the query system will only consider plans using the hinted index.
    pub hint: Option<Bson>,

    /// Whether a new document should be created if no document matches the filter.
    ///
    /// Defaults to false.
    pub upsert: Option<bool>,
}

impl From<UpdateManyModel> for WriteModel {
    fn from(model: UpdateManyModel) -> Self {
        Self::UpdateMany(model)
    }
}

/// Replaces a single document.
#[skip_serializing_none]
#[derive(Clone, Debug, Serialize, TypedBuilder)]
#[cfg_attr(test, derive(Deserialize))]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct ReplaceOneModel {
    /// The namespace on which the replace should be performed.
    #[serde(skip_serializing)]
    #[builder(!default)]
    pub namespace: Namespace,

    /// The filter to use.
    #[builder(!default)]
    pub filter: Document,

    /// The replacement document.
    #[serde(rename(serialize = "updateMods"))]
    #[builder(!default)]
    pub replacement: Document,

    /// The collation to use.
    pub collation: Option<Document>,

    /// The index to use. Specify either the index name as a string or the index key pattern. If
    /// specified, then the query system will only consider plans using the hinted index.
    pub hint: Option<Bson>,

    /// Whether a new document should be created if no document matches the filter.
    ///
    /// Defaults to false.
    pub upsert: Option<bool>,

    /// Specify which document the operation replaces if the query matches multiple
    /// documents. The first document matched by the sort order will be replaced.
    pub sort: Option<Document>,
}

impl From<ReplaceOneModel> for WriteModel {
    fn from(model: ReplaceOneModel) -> Self {
        Self::ReplaceOne(model)
    }
}

/// Deletes a single document.
#[skip_serializing_none]
#[derive(Clone, Debug, Serialize, TypedBuilder)]
#[cfg_attr(test, derive(Deserialize))]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct DeleteOneModel {
    /// The namespace on which the delete should be performed.
    #[serde(skip_serializing)]
    #[builder(!default)]
    pub namespace: Namespace,

    /// The filter to use. The first document matching this filter will be deleted.
    #[builder(!default)]
    pub filter: Document,

    /// The collation to use.
    pub collation: Option<Document>,

    /// The index to use. Specify either the index name as a string or the index key pattern. If
    /// specified, then the query system will only consider plans using the hinted index.
    pub hint: Option<Bson>,
}

impl From<DeleteOneModel> for WriteModel {
    fn from(model: DeleteOneModel) -> Self {
        Self::DeleteOne(model)
    }
}

/// Deletes multiple documents.
#[skip_serializing_none]
#[derive(Clone, Debug, Serialize, TypedBuilder)]
#[cfg_attr(test, derive(Deserialize))]
#[serde(rename_all = "camelCase")]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct DeleteManyModel {
    /// The namespace on which the delete should be performed.
    #[serde(skip_serializing)]
    #[builder(!default)]
    pub namespace: Namespace,

    /// The filter to use. All documents matching this filter will be deleted.
    pub filter: Document,

    /// The collation to use.
    pub collation: Option<Document>,

    /// The index to use. Specify either the index name as a string or the index key pattern. If
    /// specified, then the query system will only consider plans using the hinted index.
    pub hint: Option<Bson>,
}

impl From<DeleteManyModel> for WriteModel {
    fn from(model: DeleteManyModel) -> Self {
        Self::DeleteMany(model)
    }
}

impl<T> Collection<T>
where
    T: Send + Sync + Serialize,
{
    /// Constructs an [`InsertOneModel`] with this collection's namespace by serializing the
    /// provided value into a [`Document`]. Returns an error if serialization fails.
    ///
    /// Note that the returned value must be provided to [`bulk_write`](crate::Client::bulk_write)
    /// for the insert to be performed.
    pub fn insert_one_model(&self, document: impl Borrow<T>) -> Result<InsertOneModel> {
        let document = crate::bson_compat::serialize_to_document(document.borrow())?;
        Ok(InsertOneModel::builder()
            .namespace(self.namespace())
            .document(document)
            .build())
    }

    /// Constructs a [`ReplaceOneModel`] with this collection's namespace by serializing the
    /// provided value into a [`Document`]. Returns an error if serialization fails.
    ///
    /// Note that the returned value must be provided to [`bulk_write`](crate::Client::bulk_write)
    /// for the replace to be performed.
    pub fn replace_one_model(
        &self,
        filter: Document,
        replacement: impl Borrow<T>,
    ) -> Result<ReplaceOneModel> {
        let replacement = crate::bson_compat::serialize_to_document(replacement.borrow())?;
        Ok(ReplaceOneModel::builder()
            .namespace(self.namespace())
            .filter(filter)
            .replacement(replacement)
            .build())
    }
}

pub(crate) enum OperationType {
    Insert,
    Update,
    Delete,
}

impl WriteModel {
    pub(crate) fn namespace(&self) -> &Namespace {
        match self {
            Self::InsertOne(model) => &model.namespace,
            Self::UpdateOne(model) => &model.namespace,
            Self::UpdateMany(model) => &model.namespace,
            Self::ReplaceOne(model) => &model.namespace,
            Self::DeleteOne(model) => &model.namespace,
            Self::DeleteMany(model) => &model.namespace,
        }
    }

    pub(crate) fn operation_type(&self) -> OperationType {
        match self {
            Self::InsertOne(_) => OperationType::Insert,
            Self::UpdateOne(_) | Self::UpdateMany(_) | Self::ReplaceOne(_) => OperationType::Update,
            Self::DeleteOne(_) | Self::DeleteMany(_) => OperationType::Delete,
        }
    }

    /// Whether this operation should apply to all documents that match the filter. Returns None if
    /// the operation does not use a filter.
    pub(crate) fn multi(&self) -> Option<bool> {
        match self {
            Self::UpdateMany(_) | Self::DeleteMany(_) => Some(true),
            Self::UpdateOne(_) | Self::ReplaceOne(_) | Self::DeleteOne(_) => Some(false),
            Self::InsertOne(_) => None,
        }
    }

    pub(crate) fn operation_name(&self) -> &'static crate::bson_compat::CStr {
        use crate::bson_compat::cstr;
        match self.operation_type() {
            OperationType::Insert => cstr!("insert"),
            OperationType::Update => cstr!("update"),
            OperationType::Delete => cstr!("delete"),
        }
    }

    /// Constructs the ops document for this write model given the nsInfo array index.
    pub(crate) fn get_ops_document(
        &self,
        ns_info_index: usize,
    ) -> Result<(RawDocumentBuf, Option<Bson>)> {
        // The maximum number of namespaces allowed in a bulkWrite command is much lower than
        // i32::MAX, so this should never fail.
        let index = i32::try_from(ns_info_index)
            .map_err(|_| Error::internal("nsInfo index exceeds i32::MAX"))?;
        let mut ops_document = rawdoc! { self.operation_name(): index };

        if let Self::UpdateOne(UpdateOneModel { update, .. })
        | Self::UpdateMany(UpdateManyModel { update, .. }) = self
        {
            if let UpdateModifications::Document(update_document) = update {
                update_document_check(update_document)?;
            }
        } else if let Self::ReplaceOne(ReplaceOneModel { replacement, .. }) = self {
            replacement_document_check(replacement)?;
        }

        if let Some(multi) = self.multi() {
            ops_document.append(cstr!("multi"), multi);
        }

        if let Self::InsertOne(model) = self {
            let mut insert_document = RawDocumentBuf::try_from(&model.document)?;
            let inserted_id = get_or_prepend_id_field(&mut insert_document)?;
            ops_document.append(cstr!("document"), insert_document);
            Ok((ops_document, Some(inserted_id)))
        } else {
            let model = serialize_to_raw_document_buf(&self)?;
            extend_raw_document_buf(&mut ops_document, model)?;
            Ok((ops_document, None))
        }
    }
}
