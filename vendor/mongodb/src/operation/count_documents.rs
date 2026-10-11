use std::convert::TryInto;

use serde::Deserialize;

use crate::{
    bson::{doc, Document},
    cmap::RawCommandResponse,
    error::{Error, ErrorKind, Result},
    operation::{aggregate::Aggregate, OperationImpl, Wrapped, WrappedOperation},
    options::{AggregateOptions, ClientOptions, CountOptions},
};

use super::{ExecutionContext, Retryability, SingleCursorResult};

pub(crate) struct CountDocuments {
    aggregate: Aggregate,
}

impl CountDocuments {
    pub(crate) fn new(
        coll: &crate::Collection<Document>,
        filter: Document,
        options: Option<CountOptions>,
    ) -> Result<Self> {
        let mut pipeline = vec![doc! {
            "$match": filter,
        }];

        if let Some(skip) = options.as_ref().and_then(|opts| opts.skip) {
            let s: i64 = skip.try_into().map_err(|_| {
                Error::from(ErrorKind::InvalidArgument {
                    message: format!("skip exceeds range of i64: {skip}"),
                })
            })?;
            pipeline.push(doc! {
                "$skip": s
            });
        }

        if let Some(limit) = options.as_ref().and_then(|opts| opts.limit) {
            let l: i64 = limit.try_into().map_err(|_| {
                Error::from(ErrorKind::InvalidArgument {
                    message: format!("limit exceeds range of i64: {limit}"),
                })
            })?;
            pipeline.push(doc! {
                "$limit": l
            });
        }

        pipeline.push(doc! {
            "$group": {
                "_id": 1,
                "n": { "$sum": 1 },
            }
        });

        let aggregate_options = options.map(|opts| {
            AggregateOptions::builder()
                .hint(opts.hint)
                .max_time(opts.max_time)
                .collation(opts.collation)
                .selection_criteria(opts.selection_criteria)
                .read_concern(opts.read_concern)
                .comment(opts.comment)
                .build()
        });

        Ok(Self {
            aggregate: Aggregate::new(coll.into(), pipeline, aggregate_options),
        })
    }
}

impl WrappedOperation for CountDocuments {
    type Wrapped = Aggregate;
    type O = u64;
    const ZERO_COPY: bool = false;

    fn wrapped(&self) -> &Self::Wrapped {
        &self.aggregate
    }

    fn wrapped_mut(&mut self) -> &mut Self::Wrapped {
        &mut self.aggregate
    }

    fn handle_response<'a>(
        &'a self,
        response: std::borrow::Cow<'a, RawCommandResponse>,
        _context: ExecutionContext<'a>,
    ) -> crate::BoxFuture<'a, Result<Self::O>> {
        use futures_util::FutureExt;
        async move {
            let response: SingleCursorResult<Body> = response.body()?;
            Ok(response.0.map(|r| r.n).unwrap_or(0))
        }
        .boxed()
    }

    fn retryability(&self, options: &ClientOptions) -> Retryability {
        Retryability::read(options)
    }

    fn is_backpressure_retryable(&self, options: &ClientOptions) -> bool {
        options.retry_reads != Some(false)
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for CountDocuments {
    type Kind = Wrapped;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for CountDocuments {}

#[derive(Debug, Deserialize)]
struct Body {
    n: u64,
}
