pub(crate) mod options;

use std::{fmt::Debug, marker::PhantomData};

use serde::{de::DeserializeOwned, Deserialize};

use self::options::FindAndModifyOptions;
use crate::{
    bson::{doc, rawdoc, Document, RawBson, RawDocumentBuf},
    bson_compat::{cstr, deserialize_from_slice, CStr},
    bson_util,
    cmap::{Command, RawCommandResponse, StreamDescription},
    coll::options::UpdateModifications,
    error::{Error, Result},
    operation::{
        append_options_to_raw_document,
        find_and_modify::options::Modification,
        Base,
        BaseOperation,
        OperationImpl,
        Retryability,
    },
    options::{ClientOptions, WriteConcern},
    Collection,
};

use super::{ExecutionContext, UpdateOrReplace};

pub(crate) struct FindAndModify<T: DeserializeOwned> {
    target: Collection<Document>,
    query: Document,
    modification: Modification,
    options: Option<FindAndModifyOptions>,
    _phantom: PhantomData<fn() -> T>,
}

impl<T: DeserializeOwned> FindAndModify<T> {
    pub(crate) fn with_modification(
        target: Collection<Document>,
        query: Document,
        modification: Modification,
        options: Option<FindAndModifyOptions>,
    ) -> Result<Self> {
        if let Modification::Update(UpdateOrReplace::UpdateModifications(
            UpdateModifications::Document(d),
        )) = &modification
        {
            bson_util::update_document_check(d)?;
        };
        Ok(Self {
            target,
            query,
            modification,
            options,
            _phantom: PhantomData,
        })
    }
}

impl<T: DeserializeOwned> BaseOperation for FindAndModify<T> {
    type O = Option<T>;
    const NAME: &'static CStr = cstr!("findAndModify");

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = rawdoc! {
            Self::NAME: self.target.name(),
            "query": RawDocumentBuf::try_from(&self.query)?,
        };

        match &self.modification {
            Modification::Delete => body.append(cstr!("remove"), true),
            Modification::Update(update_or_replace) => {
                update_or_replace.append_to_rawdoc(&mut body, cstr!("update"))?
            }
        }

        append_options_to_raw_document(&mut body, self.options.as_ref())?;

        Ok(Command::from_operation(self, body))
    }

    fn handle_response<'a>(
        &'a self,
        response: &'a RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        response.validate_single_write()?;
        #[derive(Debug, Deserialize)]
        struct Response {
            // deserializing directly into Option<T> doesn't report an error if `value` is missing
            value: RawBson,
        }
        let body = response.body::<Response>()?;
        match body.value {
            RawBson::Document(ref doc) => Ok(Some(deserialize_from_slice(doc.as_bytes())?)),
            RawBson::Null => Ok(None),
            ref other => Err(Error::invalid_response(format!(
                "expected document for value field of findAndModify response, but instead got \
                 {other:?}",
            ))),
        }
    }

    fn write_concern(&self) -> super::Feature<&WriteConcern> {
        self.options
            .as_ref()
            .and_then(|o| o.write_concern.as_ref())
            .into()
    }

    fn retryability(&self, options: &ClientOptions) -> Retryability {
        Retryability::write(options)
    }

    fn target(&self) -> super::OperationTarget {
        (&self.target).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl<T: DeserializeOwned> OperationImpl for FindAndModify<T> {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl<T: DeserializeOwned> crate::otel::OtelInfoDefaults for FindAndModify<T> {}
