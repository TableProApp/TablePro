use crate::{bson::rawdoc, options::ClientOptions, Client};
use serde::Deserialize;

use crate::{
    bson::{doc, RawDocumentBuf},
    bson_compat::{cstr, CStr},
    cmap::{Command, RawCommandResponse, StreamDescription},
    db::options::ListDatabasesOptions,
    error::Result,
    operation::{Base, BaseOperation, OperationImpl, Retryability},
    selection_criteria::{ReadPreference, SelectionCriteria},
};

use super::{append_options_to_raw_document, ExecutionContext};

#[derive(Debug)]
pub(crate) struct ListDatabases {
    client: Client,
    name_only: bool,
    options: Option<ListDatabasesOptions>,
}

impl ListDatabases {
    pub fn new(client: Client, name_only: bool, options: Option<ListDatabasesOptions>) -> Self {
        ListDatabases {
            client,
            name_only,
            options,
        }
    }
}

impl BaseOperation for ListDatabases {
    type O = Vec<RawDocumentBuf>;

    const NAME: &'static CStr = cstr!("listDatabases");

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = rawdoc! {
            Self::NAME: 1,
            "nameOnly": self.name_only
        };

        append_options_to_raw_document(&mut body, self.options.as_ref())?;

        Ok(Command::from_operation(self, body))
    }

    fn handle_response<'a>(
        &'a self,
        response: &'a RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        let response: Response = response.body()?;
        Ok(response.databases)
    }

    fn selection_criteria(&self) -> super::Feature<&SelectionCriteria> {
        super::Feature::Set(&SelectionCriteria::ReadPreference(ReadPreference::Primary))
    }

    fn retryability(&self, options: &ClientOptions) -> Retryability {
        Retryability::read(options)
    }

    fn target(&self) -> super::OperationTarget {
        super::OperationTarget::admin(&self.client)
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for ListDatabases {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for ListDatabases {}

#[derive(Debug, Deserialize)]
pub(crate) struct Response {
    databases: Vec<RawDocumentBuf>,
}
