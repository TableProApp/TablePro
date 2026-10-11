use serde::Deserialize;

use crate::{
    bson::{doc, rawdoc, Document, RawDocumentBuf},
    bson_compat::{cstr, CStr},
    bson_util::to_raw_bson_array_ser,
    cmap::{Command, RawCommandResponse},
    error::Result,
    Collection,
    SearchIndexModel,
};

use super::{Base, BaseOperation, ExecutionContext, OperationImpl};

#[derive(Debug)]
pub(crate) struct CreateSearchIndexes {
    target: Collection<Document>,
    indexes: Vec<SearchIndexModel>,
}

impl CreateSearchIndexes {
    pub(crate) fn new(target: Collection<Document>, indexes: Vec<SearchIndexModel>) -> Self {
        Self { target, indexes }
    }
}

impl BaseOperation for CreateSearchIndexes {
    type O = Vec<String>;
    const NAME: &'static CStr = cstr!("createSearchIndexes");

    fn build(&mut self, _description: &crate::cmap::StreamDescription) -> Result<Command> {
        Ok(Command::from_operation(
            self,
            rawdoc! {
                Self::NAME: self.target.name(),
                "indexes": to_raw_bson_array_ser(&self.indexes)?,
            },
        ))
    }

    fn handle_response<'a>(
        &'a self,
        response: &'a RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        #[derive(Debug, Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Response {
            indexes_created: Vec<CreatedIndex>,
        }

        #[derive(Debug, Deserialize)]
        struct CreatedIndex {
            #[allow(unused)]
            id: String,
            name: String,
        }

        let response: Response = response.body()?;
        Ok(response
            .indexes_created
            .into_iter()
            .map(|ci| ci.name)
            .collect())
    }

    fn supports_sessions(&self) -> bool {
        false
    }

    fn target(&self) -> super::OperationTarget {
        (&self.target).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for CreateSearchIndexes {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for CreateSearchIndexes {}

#[derive(Debug)]
pub(crate) struct UpdateSearchIndex {
    target: Collection<Document>,
    name: String,
    definition: Document,
}

impl UpdateSearchIndex {
    pub(crate) fn new(target: Collection<Document>, name: String, definition: Document) -> Self {
        Self {
            target,
            name,
            definition,
        }
    }
}

impl BaseOperation for UpdateSearchIndex {
    type O = ();
    const NAME: &'static CStr = cstr!("updateSearchIndex");

    fn build(
        &mut self,
        _description: &crate::cmap::StreamDescription,
    ) -> crate::error::Result<crate::cmap::Command> {
        let raw_def: RawDocumentBuf = (&self.definition).try_into()?;
        Ok(Command::from_operation(
            self,
            rawdoc! {
                Self::NAME: self.target.name(),
                "name": self.name.as_str(),
                "definition": raw_def,
            },
        ))
    }

    fn handle_response<'a>(
        &'a self,
        _response: &'a RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        Ok(())
    }

    fn supports_sessions(&self) -> bool {
        false
    }

    fn target(&self) -> super::OperationTarget {
        (&self.target).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for UpdateSearchIndex {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for UpdateSearchIndex {}

#[derive(Debug)]
pub(crate) struct DropSearchIndex {
    target: Collection<Document>,
    name: String,
}

impl DropSearchIndex {
    pub(crate) fn new(target: Collection<Document>, name: String) -> Self {
        Self { target, name }
    }
}

impl BaseOperation for DropSearchIndex {
    type O = ();
    const NAME: &'static CStr = cstr!("dropSearchIndex");

    fn build(&mut self, _description: &crate::cmap::StreamDescription) -> Result<Command> {
        Ok(Command::from_operation(
            self,
            rawdoc! {
                Self::NAME: self.target.name(),
                "name": self.name.as_str(),
            },
        ))
    }

    fn handle_response<'a>(
        &'a self,
        _response: &'a RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        Ok(())
    }

    fn handle_error(&self, error: crate::error::Error) -> Result<Self::O> {
        if error.is_ns_not_found() {
            Ok(())
        } else {
            Err(error)
        }
    }

    fn supports_sessions(&self) -> bool {
        false
    }

    fn target(&self) -> super::OperationTarget {
        (&self.target).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for DropSearchIndex {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for DropSearchIndex {}
