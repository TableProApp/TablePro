use crate::{
    bson::{doc, Document},
    change_stream::{
        common::{ChangeStreamData, WatchArgs},
        event::ResumeToken,
    },
    cmap::{Command, RawCommandResponse, StreamDescription},
    cursor::common::CursorSpecification,
    error::Result,
    operation::{
        append_options,
        ExecutionContext,
        Operation,
        OperationImpl,
        Wrapped,
        WrappedOperation,
    },
    options::ChangeStreamOptions,
};

use super::Aggregate;

pub(crate) struct ChangeStreamAggregate {
    inner: Aggregate,
    args: WatchArgs,
    resume_data: Option<ChangeStreamData>,
}

impl ChangeStreamAggregate {
    pub(crate) fn new(args: &WatchArgs, resume_data: Option<ChangeStreamData>) -> Result<Self> {
        Ok(Self {
            inner: Self::build_inner(args)?,
            args: args.clone(),
            resume_data,
        })
    }

    fn build_inner(args: &WatchArgs) -> Result<Aggregate> {
        let mut bson_options = Document::new();
        append_options(&mut bson_options, args.options.as_ref())?;

        let mut agg_pipeline = vec![doc! { "$changeStream": bson_options }];
        agg_pipeline.extend(args.pipeline.iter().cloned());
        Ok(Aggregate::new(
            args.target.clone(),
            agg_pipeline,
            args.options.as_ref().map(|o| o.aggregate_options()),
        ))
    }
}

impl WrappedOperation for ChangeStreamAggregate {
    type Wrapped = Aggregate;
    type O = (CursorSpecification, ChangeStreamData);
    const ZERO_COPY: bool = true;

    fn wrapped(&self) -> &Self::Wrapped {
        &self.inner
    }

    fn wrapped_mut(&mut self) -> &mut Self::Wrapped {
        &mut self.inner
    }

    fn build(&mut self, description: &StreamDescription) -> Result<Command> {
        if let Some(data) = &mut self.resume_data {
            let mut new_opts = self.args.options.clone().unwrap_or_default();
            if let Some(token) = data.resume_token.take() {
                if new_opts.start_after.is_some() && !data.document_returned {
                    new_opts.start_after = Some(token);
                    new_opts.start_at_operation_time = None;
                } else {
                    new_opts.resume_after = Some(token);
                    new_opts.start_after = None;
                    new_opts.start_at_operation_time = None;
                }
            } else {
                let saved_time = new_opts
                    .start_at_operation_time
                    .as_ref()
                    .or(data.initial_operation_time.as_ref());
                if saved_time.is_some() && description.max_wire_version.is_some_and(|v| v >= 7) {
                    new_opts.start_at_operation_time = saved_time.cloned();
                }
            }

            self.inner = Self::build_inner(&WatchArgs {
                options: Some(new_opts),
                ..self.args.clone()
            })?;
        }
        self.inner.build(description)
    }

    fn handle_response<'a>(
        &'a self,
        response: std::borrow::Cow<'a, RawCommandResponse>,
        mut context: ExecutionContext<'a>,
    ) -> crate::BoxFuture<'a, Result<Self::O>> {
        use futures_util::FutureExt;
        async move {
            let op_time = response
                .raw_body()
                .get("operationTime")?
                .and_then(crate::bson::RawBsonRef::as_timestamp);

            let inner_context = ExecutionContext {
                connection: context.connection,
                session: context.session.as_deref_mut(),
                effective_criteria: context.effective_criteria,
            };
            let spec = {
                use crate::operation::BaseOperation;
                self.inner.handle_response_cow(response, inner_context)?
            };

            let mut data = ChangeStreamData {
                resume_token: ResumeToken::initial(self.args.options.as_ref(), &spec),
                ..ChangeStreamData::default()
            };
            let has_no_time = |o: &ChangeStreamOptions| {
                o.start_at_operation_time.is_none()
                    && o.resume_after.is_none()
                    && o.start_after.is_none()
            };

            let description = context.connection.stream_description()?;
            if self.args.options.as_ref().is_none_or(has_no_time)
                && description.max_wire_version.is_some_and(|v| v >= 7)
                && spec.is_empty
                && spec.post_batch_resume_token.is_none()
            {
                data.initial_operation_time = op_time;
            }

            Ok((spec, data))
        }
        .boxed()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for ChangeStreamAggregate {
    type Kind = Wrapped;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for ChangeStreamAggregate {}
