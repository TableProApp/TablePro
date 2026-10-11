use serde::Deserialize;

#[cfg(feature = "bson-3")]
use crate::bson_compat::RawDocumentBufExt as _;
use crate::{
    bson::{doc, rawdoc, Document, RawArrayBuf, RawBson, RawDocumentBuf},
    bson_compat::{cstr, CStr},
    bson_util,
    cmap::{Command, RawCommandResponse, StreamDescription},
    error::Result,
    operation::{Base, BaseOperation, OperationImpl, Retryability},
    options::{ClientOptions, UpdateModifications, UpdateOptions, WriteConcern},
    results::UpdateResult,
    Collection,
};

use super::ExecutionContext;

#[derive(Clone, Debug)]
pub(crate) enum UpdateOrReplace {
    UpdateModifications(UpdateModifications),
    Replacement(RawDocumentBuf),
}

impl UpdateOrReplace {
    pub(crate) fn append_to_rawdoc(&self, doc: &mut RawDocumentBuf, key: &CStr) -> Result<()> {
        match self {
            Self::UpdateModifications(update_modifications) => match update_modifications {
                UpdateModifications::Document(document) => {
                    let raw = RawDocumentBuf::try_from(document)?;
                    doc.append(key, raw);
                }
                UpdateModifications::Pipeline(pipeline) => {
                    let raw = bson_util::to_raw_bson_array(pipeline)?;
                    doc.append(key, raw);
                }
            },
            Self::Replacement(replacement_doc) => {
                bson_util::replacement_raw_document_check(replacement_doc)?;
                doc.append_ref(key, replacement_doc);
            }
        }

        Ok(())
    }
}

impl From<UpdateModifications> for UpdateOrReplace {
    fn from(update_modifications: UpdateModifications) -> Self {
        Self::UpdateModifications(update_modifications)
    }
}

#[derive(Debug)]
pub(crate) struct Update {
    target: Collection<Document>,
    filter: Document,
    update: UpdateOrReplace,
    multi: Option<bool>,
    options: Option<UpdateOptions>,
}

impl Update {
    pub(crate) fn with_update(
        target: Collection<Document>,
        filter: Document,
        update: UpdateModifications,
        multi: bool,
        options: Option<UpdateOptions>,
    ) -> Self {
        Self {
            target,
            filter,
            update: update.into(),
            multi: multi.then_some(true),
            options,
        }
    }

    pub(crate) fn with_replace_raw(
        target: Collection<Document>,
        filter: Document,
        update: RawDocumentBuf,
        multi: bool,
        options: Option<UpdateOptions>,
    ) -> Result<Self> {
        Ok(Self {
            target,
            filter,
            update: UpdateOrReplace::Replacement(update),
            multi: multi.then_some(true),
            options,
        })
    }
}

impl BaseOperation for Update {
    type O = UpdateResult;

    const NAME: &'static CStr = cstr!("update");

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = rawdoc! {
            Self::NAME: self.target.name(),
        };

        let mut update = rawdoc! {
            "q": RawDocumentBuf::try_from(&self.filter)?,
        };
        self.update.append_to_rawdoc(&mut update, cstr!("u"))?;

        if let Some(ref options) = self.options {
            if let Some(upsert) = options.upsert {
                update.append(cstr!("upsert"), upsert);
            }

            if let Some(ref array_filters) = options.array_filters {
                update.append(
                    cstr!("arrayFilters"),
                    bson_util::to_raw_bson_array(array_filters)?,
                );
            }

            if let Some(ref hint) = options.hint {
                update.append(cstr!("hint"), hint.to_raw_bson()?);
            }

            if let Some(ref collation) = options.collation {
                update.append(
                    cstr!("collation"),
                    crate::bson_compat::serialize_to_raw_document_buf(&collation)?,
                );
            }

            if let Some(bypass_doc_validation) = options.bypass_document_validation {
                body.append(cstr!("bypassDocumentValidation"), bypass_doc_validation);
            }

            if let Some(ref let_vars) = options.let_vars {
                body.append(cstr!("let"), RawDocumentBuf::try_from(let_vars)?);
            }

            if let Some(ref comment) = options.comment {
                body.append(cstr!("comment"), RawBson::try_from(comment.clone())?);
            }

            if let Some(ref sort) = options.sort {
                update.append(cstr!("sort"), RawDocumentBuf::try_from(sort)?);
            }
        };

        if let Some(multi) = self.multi {
            update.append(cstr!("multi"), multi);
        }

        let mut updates = RawArrayBuf::new();
        updates.push(update);
        body.append(cstr!("updates"), updates);
        body.append(cstr!("ordered"), true); // command monitoring tests expect this (SPEC-1130)

        Ok(Command::from_operation(self, body))
    }

    fn handle_response<'a>(
        &'a self,
        response: &'a RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        response.validate_single_write()?;
        let response: UpdateBody = response.body()?;

        let modified_count = response.n_modified;
        let upserted_id = response
            .upserted
            .as_ref()
            .and_then(|v| v.first())
            .and_then(|doc| doc.get("_id"))
            .cloned();

        let matched_count = if upserted_id.is_some() { 0 } else { response.n };

        Ok(UpdateResult {
            matched_count,
            modified_count,
            upserted_id,
        })
    }

    fn write_concern(&self) -> super::Feature<&WriteConcern> {
        self.options
            .as_ref()
            .and_then(|opts| opts.write_concern.as_ref())
            .into()
    }

    fn retryability(&self, options: &ClientOptions) -> Retryability {
        if self.multi != Some(true) {
            Retryability::write(options)
        } else {
            Retryability::None
        }
    }

    fn is_backpressure_retryable(&self, options: &crate::options::ClientOptions) -> bool {
        options.retry_writes != Some(false)
    }

    fn target(&self) -> super::OperationTarget {
        (&self.target).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for Update {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for Update {}

#[derive(Deserialize)]
pub(crate) struct UpdateBody {
    n: u64,
    #[serde(rename = "nModified")]
    n_modified: u64,
    upserted: Option<Vec<Document>>,
}
