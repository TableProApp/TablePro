use futures_util::FutureExt;

#[cfg(feature = "opentelemetry")]
use crate::operation::Operation;
use crate::{
    bson_compat::{cstr, CStr},
    cmap::RawCommandResponse,
    cursor::common::CursorSpecification,
    error::Result,
    operation::{run_command::RunCommand, OperationImpl, Wrapped, WrappedOperation},
    options::RunCursorCommandOptions,
    BoxFuture,
};

use super::ExecutionContext;

#[derive(Debug, Clone)]
pub(crate) struct RunCursorCommand<'conn> {
    run_command: RunCommand<'conn>,
    options: Option<RunCursorCommandOptions>,
}

impl<'conn> RunCursorCommand<'conn> {
    pub(crate) fn new(
        run_command: RunCommand<'conn>,
        options: Option<RunCursorCommandOptions>,
    ) -> Result<Self> {
        Ok(Self {
            run_command,
            options,
        })
    }
}

impl<'conn> WrappedOperation for RunCursorCommand<'conn> {
    type Wrapped = RunCommand<'conn>;
    type O = CursorSpecification;
    const NAME: &'static CStr = cstr!("run_cursor_command");
    const ZERO_COPY: bool = true;

    fn wrapped(&self) -> &Self::Wrapped {
        &self.run_command
    }

    fn wrapped_mut(&mut self) -> &mut Self::Wrapped {
        &mut self.run_command
    }

    fn handle_response<'a>(
        &'a self,
        response: std::borrow::Cow<'a, RawCommandResponse>,
        context: ExecutionContext<'a>,
    ) -> BoxFuture<'a, Result<Self::O>> {
        async move {
            CursorSpecification::new(
                response.into_owned(),
                context
                    .connection
                    .stream_description()?
                    .server_address
                    .clone(),
                self.options.as_ref().and_then(|opts| opts.batch_size),
                self.options.as_ref().and_then(|opts| opts.max_time),
                self.options.as_ref().and_then(|opts| opts.comment.clone()),
            )
        }
        .boxed()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for RunCursorCommand<'_> {
    type Kind = Wrapped;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfo for RunCursorCommand<'_> {
    fn log_name(&self) -> &str {
        self.run_command.otel().log_name()
    }

    fn cursor_id(&self) -> Option<i64> {
        self.run_command.otel().cursor_id()
    }

    fn output_cursor_id(output: &<Self as Operation>::O) -> Option<i64> {
        Some(output.id())
    }
}
