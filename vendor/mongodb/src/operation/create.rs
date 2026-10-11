use crate::{bson::rawdoc, Collection};

use crate::{
    bson::Document,
    bson_compat::{cstr, CStr},
    cmap::{Command, RawCommandResponse, StreamDescription},
    error::Result,
    operation::{append_options_to_raw_document, Base, BaseOperation, OperationImpl},
    options::{CreateCollectionOptions, WriteConcern},
};

use super::ExecutionContext;

#[derive(Debug)]
pub(crate) struct Create {
    target: Collection<Document>,
    options: Option<CreateCollectionOptions>,
}

impl Create {
    pub(crate) fn new(
        target: Collection<Document>,
        options: Option<CreateCollectionOptions>,
    ) -> Self {
        Self { target, options }
    }
}

impl BaseOperation for Create {
    type O = ();

    const NAME: &'static CStr = cstr!("create");

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = rawdoc! {
            Self::NAME: self.target.name(),
        };

        append_options_to_raw_document(&mut body, self.options.as_ref())?;

        Ok(Command::from_operation(self, body))
    }

    fn handle_response<'a>(
        &'a self,
        response: &'a RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        response.validate_single_write()
    }

    fn write_concern(&self) -> super::Feature<&WriteConcern> {
        self.options
            .as_ref()
            .and_then(|o| o.write_concern.as_ref())
            .into()
    }

    fn target(&self) -> super::OperationTarget {
        (&self.target).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for Create {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for Create {
    fn log_name(&self) -> &str {
        "createCollection"
    }
}
