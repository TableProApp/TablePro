use crate::{
    bson::{rawdoc, Document},
    bson_compat::{cstr, CStr},
    checked::Checked,
    cmap::{Command, RawCommandResponse, StreamDescription},
    cursor::common::CursorSpecification,
    error::Result,
    operation::{Base, BaseOperation, OperationImpl},
    options::{ClientOptions, ListIndexesOptions},
    selection_criteria::{ReadPreference, SelectionCriteria},
    Collection,
};

use super::{append_options_to_raw_document, ExecutionContext, Retryability};

pub(crate) struct ListIndexes {
    target: Collection<Document>,
    options: Option<ListIndexesOptions>,
}

impl ListIndexes {
    pub(crate) fn new(target: Collection<Document>, options: Option<ListIndexesOptions>) -> Self {
        ListIndexes { target, options }
    }
}

impl BaseOperation for ListIndexes {
    type O = CursorSpecification;

    const NAME: &'static CStr = cstr!("listIndexes");

    const ZERO_COPY: bool = true;

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = rawdoc! {
            Self::NAME: self.target.name(),
        };
        if let Some(size) = self.options.as_ref().and_then(|o| o.batch_size) {
            let size = Checked::from(size).try_into::<i32>()?;
            body.append(cstr!("cursor"), rawdoc! { "batchSize": size });
        }
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
            self.options.as_ref().and_then(|o| o.batch_size),
            self.options.as_ref().and_then(|o| o.max_time),
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
        (&self.target).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for ListIndexes {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for ListIndexes {
    fn output_cursor_id(output: &Self::O) -> Option<i64> {
        Some(output.id())
    }
}
