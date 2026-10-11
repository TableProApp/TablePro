use crate::{bson::rawdoc, Collection};

use crate::{
    bson::Document,
    bson_compat::{cstr, CStr},
    bson_util::to_raw_bson_array_ser,
    cmap::{Command, RawCommandResponse, StreamDescription},
    error::Result,
    index::IndexModel,
    operation::{append_options_to_raw_document, Base, BaseOperation, OperationImpl},
    options::{CreateIndexOptions, WriteConcern},
    results::CreateIndexesResult,
};

use super::ExecutionContext;

#[derive(Debug)]
pub(crate) struct CreateIndexes {
    target: Collection<Document>,
    indexes: Vec<IndexModel>,
    options: Option<CreateIndexOptions>,
}

impl CreateIndexes {
    pub(crate) fn new(
        target: Collection<Document>,
        indexes: Vec<IndexModel>,
        options: Option<CreateIndexOptions>,
    ) -> Self {
        Self {
            target,
            indexes,
            options,
        }
    }
}

impl BaseOperation for CreateIndexes {
    type O = CreateIndexesResult;
    const NAME: &'static CStr = cstr!("createIndexes");

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        self.indexes.iter_mut().for_each(|i| i.update_name()); // Generate names for unnamed indexes.
        let indexes = to_raw_bson_array_ser(&self.indexes)?;
        let mut body = rawdoc! {
            Self::NAME: self.target.name(),
            "indexes": indexes,
        };

        append_options_to_raw_document(&mut body, self.options.as_ref())?;

        Ok(Command::from_operation(self, body))
    }

    fn handle_response<'a>(
        &'a self,
        response: &'a RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        response.validate_single_write()?;
        let index_names = self.indexes.iter().filter_map(|i| i.get_name()).collect();
        Ok(CreateIndexesResult { index_names })
    }

    fn is_backpressure_retryable(&self, options: &crate::options::ClientOptions) -> bool {
        options.retry_writes != Some(false)
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

impl OperationImpl for CreateIndexes {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for CreateIndexes {}
