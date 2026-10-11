use futures_util::FutureExt;

use crate::{
    cmap::RawCommandResponse,
    error::Result,
    operation::{OperationImpl, Wrapped, WrappedOperation},
    BoxFuture,
};

use super::{ExecutionContext, Operation};

/// Forwards all implementation to the wrapped `Operation`, but returns the response unparsed and
/// unvalidated as a `RawCommandResponse`.
#[derive(Clone)]
pub(crate) struct RawOutput<Op>(pub(crate) Op);

impl<Op: Operation + Sync + Send> WrappedOperation for RawOutput<Op> {
    type Wrapped = Op;
    type O = RawCommandResponse;
    const ZERO_COPY: bool = true;

    fn wrapped(&self) -> &Self::Wrapped {
        &self.0
    }

    fn wrapped_mut(&mut self) -> &mut Self::Wrapped {
        &mut self.0
    }

    fn handle_response<'a>(
        &'a self,
        response: std::borrow::Cow<'a, RawCommandResponse>,
        _context: ExecutionContext<'a>,
    ) -> BoxFuture<'a, Result<Self::O>> {
        async move { Ok(response.into_owned()) }.boxed()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl<Op> OperationImpl for RawOutput<Op> {
    type Kind = Wrapped;
}

#[cfg(feature = "opentelemetry")]
impl<Op: Operation + Sync + Send> crate::otel::OtelInfo for RawOutput<Op> {
    fn log_name(&self) -> &str {
        self.0.otel().log_name()
    }

    fn cursor_id(&self) -> Option<i64> {
        self.0.otel().cursor_id()
    }

    fn output_cursor_id(_output: &<Self as Operation>::O) -> Option<i64> {
        None
    }
}
