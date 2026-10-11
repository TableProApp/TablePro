use crate::{bson::rawdoc, Database};

use crate::{
    bson_compat::{cstr, CStr},
    cmap::{Command, RawCommandResponse, StreamDescription},
    db::options::DropDatabaseOptions,
    error::Result,
    operation::{append_options_to_raw_document, Base, BaseOperation, OperationImpl},
    options::WriteConcern,
};

use super::ExecutionContext;

#[derive(Debug)]
pub(crate) struct DropDatabase {
    target_db: Database,
    options: Option<DropDatabaseOptions>,
}

impl DropDatabase {
    pub(crate) fn new(target_db: Database, options: Option<DropDatabaseOptions>) -> Self {
        Self { target_db, options }
    }
}

impl BaseOperation for DropDatabase {
    type O = ();

    const NAME: &'static CStr = cstr!("dropDatabase");

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = rawdoc! {
            Self::NAME: 1,
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
            .and_then(|opts| opts.write_concern.as_ref())
            .into()
    }

    fn target(&self) -> super::OperationTarget {
        (&self.target_db).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for DropDatabase {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for DropDatabase {}
