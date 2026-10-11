use crate::{
    bson::{doc, Document},
    bson_compat::{cstr, CStr},
    cmap::{Command, RawCommandResponse, StreamDescription},
    collation::Collation,
    error::Result,
    operation::{append_options, Base, BaseOperation, OperationImpl, Retryability},
    options::{ClientOptions, DeleteOptions, Hint, WriteConcern},
    results::DeleteResult,
    Collection,
};

use super::ExecutionContext;

#[derive(Debug)]
pub(crate) struct Delete {
    target: Collection<Document>,
    filter: Document,
    limit: u32,
    options: Option<DeleteOptions>,
    collation: Option<Collation>,
    hint: Option<Hint>,
}

impl Delete {
    pub(crate) fn new(
        target: Collection<Document>,
        filter: Document,
        limit: Option<u32>,
        mut options: Option<DeleteOptions>,
    ) -> Self {
        Self {
            target,
            filter,
            limit: limit.unwrap_or(0), // 0 = no limit
            collation: options.as_mut().and_then(|opts| opts.collation.take()),
            hint: options.as_mut().and_then(|opts| opts.hint.take()),
            options,
        }
    }
}

impl BaseOperation for Delete {
    type O = DeleteResult;

    const NAME: &'static CStr = cstr!("delete");

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut delete = doc! {
            "q": self.filter.clone(),
            "limit": self.limit,
        };

        if let Some(ref collation) = self.collation {
            delete.insert(
                "collation",
                crate::bson_compat::serialize_to_bson(&collation)?,
            );
        }

        if let Some(ref hint) = self.hint {
            delete.insert("hint", crate::bson_compat::serialize_to_bson(&hint)?);
        }

        let mut body = doc! {
            crate::bson_compat::cstr_to_str(Self::NAME): self.target.name(),
            "deletes": [delete],
            "ordered": true, // command monitoring tests expect this (SPEC-1130)
        };

        append_options(&mut body, self.options.as_ref())?;

        Ok(Command::from_operation(self, (&body).try_into()?))
    }

    fn handle_response<'a>(
        &'a self,
        response: &'a RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        response.validate_single_write()?;
        Ok(DeleteResult {
            deleted_count: response.extract_n()?,
        })
    }

    fn write_concern(&self) -> super::Feature<&WriteConcern> {
        self.options
            .as_ref()
            .and_then(|opts| opts.write_concern.as_ref())
            .into()
    }

    fn retryability(&self, options: &ClientOptions) -> Retryability {
        if self.limit == 1 {
            Retryability::write(options)
        } else {
            Retryability::None
        }
    }

    fn is_backpressure_retryable(&self, options: &ClientOptions) -> bool {
        options.retry_writes != Some(false)
    }

    fn target(&self) -> super::OperationTarget {
        (&self.target).into()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for Delete {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for Delete {}
