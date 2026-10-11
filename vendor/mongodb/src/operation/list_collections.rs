use crate::{
    bson::rawdoc,
    bson_compat::{cstr, CStr},
    cmap::{Command, RawCommandResponse, StreamDescription},
    cursor::common::CursorSpecification,
    error::Result,
    operation::{Base, BaseOperation, OperationImpl, Retryability},
    options::{ClientOptions, ListCollectionsOptions, ReadPreference, SelectionCriteria},
    Database,
};

use super::{append_options_to_raw_document, ExecutionContext};

#[derive(Debug)]
pub(crate) struct ListCollections {
    db: Database,
    name_only: bool,
    options: Option<ListCollectionsOptions>,
}

impl ListCollections {
    pub(crate) fn new(
        db: Database,
        name_only: bool,
        options: Option<ListCollectionsOptions>,
    ) -> Self {
        Self {
            db,
            name_only,
            options,
        }
    }
}

impl BaseOperation for ListCollections {
    type O = CursorSpecification;

    const NAME: &'static CStr = cstr!("listCollections");

    const ZERO_COPY: bool = true;

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = rawdoc! {
            Self::NAME: 1,
        };

        let mut name_only = self.name_only;
        if let Some(filter) = self.options.as_ref().and_then(|o| o.filter.as_ref()) {
            if name_only && filter.keys().any(|k| k != "name") {
                name_only = false;
            }
        }
        body.append(cstr!("nameOnly"), name_only);

        append_options_to_raw_document(&mut body, self.options.as_ref())?;

        Ok(Command::from_operation(self, body))
    }

    fn handle_response_cow<'a>(
        &'a self,
        response: std::borrow::Cow<'a, RawCommandResponse>,
        context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        CursorSpecification::new(
            response.into_owned(),
            context
                .connection
                .stream_description()?
                .server_address
                .clone(),
            self.options.as_ref().and_then(|opts| opts.batch_size),
            None,
            None,
        )
    }

    fn selection_criteria(&self) -> super::Feature<&SelectionCriteria> {
        super::Feature::Set(&SelectionCriteria::ReadPreference(ReadPreference::Primary))
    }

    fn retryability(&self, options: &ClientOptions) -> Retryability {
        Retryability::read(options)
    }

    fn target(&self) -> super::OperationTarget {
        (&self.db).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for ListCollections {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for ListCollections {
    fn output_cursor_id(output: &Self::O) -> Option<i64> {
        Some(output.id())
    }
}
