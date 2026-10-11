use crate::{
    bson::{rawdoc, Document, RawDocumentBuf},
    bson_compat::{cstr, CStr},
    cmap::{Command, RawCommandResponse, StreamDescription},
    cursor::common::CursorSpecification,
    error::{Error, Result},
    operation::{Base, BaseOperation, OperationImpl, Retryability},
    options::{ClientOptions, CursorType, FindOptions, SelectionCriteria},
    Collection,
};

use super::{append_options_to_raw_document, ExecutionContext};

#[derive(Debug)]
pub(crate) struct Find {
    target: Collection<Document>,
    filter: Document,
    options: Option<Box<FindOptions>>,
}

impl Find {
    pub(crate) fn new(
        target: Collection<Document>,
        filter: Document,
        options: Option<FindOptions>,
    ) -> Self {
        Self {
            target,
            filter,
            options: options.map(Box::new),
        }
    }
}

impl BaseOperation for Find {
    type O = CursorSpecification;
    const NAME: &'static CStr = cstr!("find");
    const ZERO_COPY: bool = true;

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = rawdoc! {
            Self::NAME: self.target.name(),
        };

        if let Some(ref mut options) = self.options {
            // negative limits should be interpreted as request for single batch as per crud spec.
            if options.limit.map(|limit| limit < 0) == Some(true) {
                body.append(cstr!("singleBatch"), true);
            }

            if let Some(ref mut batch_size) = options.batch_size {
                if i32::try_from(*batch_size).is_err() {
                    return Err(Error::invalid_argument(
                        "the batch size must fit into a signed 32-bit integer",
                    ));
                }
                if let Some(limit) = options.limit.and_then(|limit| u32::try_from(limit).ok()) {
                    if *batch_size == limit {
                        *batch_size += 1;
                    }
                }
            }

            match options.cursor_type {
                Some(CursorType::Tailable) => {
                    body.append(cstr!("tailable"), true);
                }
                Some(CursorType::TailableAwait) => {
                    body.append(cstr!("tailable"), true);
                    body.append(cstr!("awaitData"), true);
                }
                _ => {}
            };
        }

        append_options_to_raw_document(&mut body, self.options.as_ref())?;

        let raw_filter: RawDocumentBuf = (&self.filter).try_into()?;
        body.append(cstr!("filter"), raw_filter);

        Ok(Command::from_operation(self, body))
    }

    fn extract_at_cluster_time(
        &self,
        response: &crate::bson::RawDocument,
    ) -> Result<Option<crate::bson::Timestamp>> {
        super::cursor_get_at_cluster_time(response)
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
            self.options.as_ref().and_then(|opts| opts.max_await_time),
            self.options.as_ref().and_then(|opts| opts.comment.clone()),
        )
    }

    fn read_concern(&self) -> super::Feature<&crate::options::ReadConcern> {
        self.options
            .as_ref()
            .and_then(|opts| opts.read_concern.as_ref())
            .into()
    }

    fn selection_criteria(&self) -> super::Feature<&SelectionCriteria> {
        self.options
            .as_ref()
            .and_then(|opts| opts.selection_criteria.as_ref())
            .into()
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

impl OperationImpl for Find {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for Find {
    fn output_cursor_id(output: &Self::O) -> Option<i64> {
        Some(output.id())
    }
}
