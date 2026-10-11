use crate::{
    bson::rawdoc,
    bson_compat::{cstr, CStr},
    client::{session::TransactionPin, Retry},
    cmap::{conn::PinnedConnectionHandle, Command, RawCommandResponse, StreamDescription},
    error::Result,
    operation::{Base, OperationImpl, Retryability},
    options::{ClientOptions, SelectionCriteria, WriteConcern},
    Client,
};

use super::{BaseOperation, ExecutionContext};

pub(crate) struct AbortTransaction {
    write_concern: Option<WriteConcern>,
    pinned: Option<TransactionPin>,
    target: Client,
}

impl AbortTransaction {
    pub(crate) fn new(
        client: &Client,
        write_concern: Option<WriteConcern>,
        pinned: Option<TransactionPin>,
    ) -> Self {
        Self {
            write_concern,
            pinned,
            target: client.clone(),
        }
    }
}

impl BaseOperation for AbortTransaction {
    type O = ();

    const NAME: &'static CStr = cstr!("abortTransaction");

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let body = rawdoc! {
            Self::NAME: 1,
        };

        Ok(Command::from_operation(self, body))
    }

    fn handle_response<'a>(
        &'a self,
        response: &RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        response.validate_single_write()
    }

    fn selection_criteria(&self) -> super::Feature<&SelectionCriteria> {
        match &self.pinned {
            Some(TransactionPin::Mongos(s)) => super::Feature::Set(s),
            _ => super::Feature::NotSupported,
        }
    }

    fn pinned_connection(&self) -> Option<&PinnedConnectionHandle> {
        match &self.pinned {
            Some(TransactionPin::Connection(h)) => Some(h),
            _ => None,
        }
    }

    fn write_concern(&self) -> super::Feature<&WriteConcern> {
        self.write_concern.as_ref().into()
    }

    fn retryability(&self, _options: &ClientOptions) -> Retryability {
        // abortTransaction is retryable regardless of the value of retryWrites
        Retryability::Write
    }

    fn update_for_retry(&mut self, _retry: Option<&Retry>) {
        // The session must be "unpinned" before server selection for a retry.
        self.pinned = None;
    }

    fn target(&self) -> super::OperationTarget {
        crate::operation::OperationTarget::admin(&self.target)
    }

    fn is_after_cluster_time_write(&self) -> bool {
        false
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for AbortTransaction {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for AbortTransaction {}
