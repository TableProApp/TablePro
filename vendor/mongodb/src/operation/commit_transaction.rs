use std::time::Duration;

use crate::{
    bson::rawdoc,
    bson_compat::{cstr, CStr},
    client::Retry,
    cmap::{Command, RawCommandResponse, StreamDescription},
    error::Result,
    operation::{append_options_to_raw_document, Base, BaseOperation, OperationImpl, Retryability},
    options::{Acknowledgment, ClientOptions, TransactionOptions, WriteConcern},
    Client,
};

use super::ExecutionContext;

pub(crate) struct CommitTransaction {
    options: Option<TransactionOptions>,
    target: Client,
}

impl CommitTransaction {
    pub(crate) fn new(client: &Client, options: Option<TransactionOptions>) -> Self {
        Self {
            options,
            target: client.clone(),
        }
    }
}

impl BaseOperation for CommitTransaction {
    type O = ();

    const NAME: &'static CStr = cstr!("commitTransaction");

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = rawdoc! {
            Self::NAME: 1,
        };

        append_options_to_raw_document(&mut body, self.options.as_ref())?;

        Ok(Command::from_operation(self, body))
    }

    fn handle_response<'a>(
        &'a self,
        response: &RawCommandResponse,
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

    fn retryability(&self, _options: &ClientOptions) -> Retryability {
        // commitTransaction is retryable regardless of the value of retryWrites
        Retryability::Write
    }

    // Updates the write concern to use w: majority and a w_timeout of 10000 if w_timeout is not
    // already set. The write concern on a commitTransaction command should be updated if a
    // commit is being retried internally or by the user.
    fn update_for_retry(&mut self, retry: Option<&Retry>) {
        if !retry.map(|retry| retry.overloaded).unwrap_or(false) {
            let options = self.options.get_or_insert_default();
            match &mut options.write_concern {
                Some(write_concern) => {
                    write_concern.w = Some(Acknowledgment::Majority);
                    if write_concern.w_timeout.is_none() {
                        write_concern.w_timeout = Some(Duration::from_millis(10000));
                    }
                }
                None => {
                    options.write_concern = Some(
                        WriteConcern::builder()
                            .w(Acknowledgment::Majority)
                            .w_timeout(Duration::from_millis(10000))
                            .build(),
                    );
                }
            }
        }
    }

    fn target(&self) -> super::OperationTarget {
        super::OperationTarget::admin(&self.target)
    }

    fn is_after_cluster_time_write(&self) -> bool {
        false
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for CommitTransaction {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for CommitTransaction {}
