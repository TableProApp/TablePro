pub(crate) mod change_stream;

use crate::{
    bson::{doc, Bson, Document},
    bson_compat::{cstr, CStr},
    bson_util,
    cmap::{Command, RawCommandResponse, StreamDescription},
    cursor::common::CursorSpecification,
    error::Result,
    operation::{append_options, Base, OperationImpl, OperationTarget, Retryability},
    options::{AggregateOptions, ClientOptions, ReadPreference, SelectionCriteria, WriteConcern},
};

use super::{BaseOperation, ExecutionContext};

#[derive(Debug)]
pub(crate) struct Aggregate {
    target: OperationTarget,
    pipeline: Vec<Document>,
    options: Option<AggregateOptions>,
    is_out_or_merge: bool,
}

impl Aggregate {
    pub(crate) fn new(
        target: OperationTarget,
        pipeline: impl IntoIterator<Item = Document>,
        options: Option<AggregateOptions>,
    ) -> Self {
        let pipeline = pipeline.into_iter().collect::<Vec<_>>();
        let is_out_or_merge = pipeline
            .last()
            .map(|stage| {
                let stage = bson_util::first_key(stage);
                stage == Some("$out") || stage == Some("$merge")
            })
            .unwrap_or(false);
        Self {
            target,
            pipeline,
            options,
            is_out_or_merge,
        }
    }
}

// IMPORTANT: If new method implementations are added here, make sure `ChangeStreamAggregate` has
// the equivalent delegations.
impl BaseOperation for Aggregate {
    type O = CursorSpecification;

    const NAME: &'static CStr = cstr!("aggregate");

    const ZERO_COPY: bool = true;

    fn build(&mut self, _description: &StreamDescription) -> Result<Command> {
        let mut body = doc! {
            crate::bson_compat::cstr_to_str(Self::NAME): target_bson(&self.target),
            "pipeline": bson_util::to_bson_array(&self.pipeline),
            "cursor": {}
        };

        append_options(&mut body, self.options.as_ref())?;

        if self.is_out_or_merge {
            if let Ok(cursor_doc) = body.get_document_mut("cursor") {
                cursor_doc.remove("batchSize");
            }
        }

        Ok(Command::from_operation(self, (&body).try_into()?))
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
        if self.is_out_or_merge {
            response.validate_single_write()?;
        };
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

    fn selection_criteria(&self) -> super::Feature<&SelectionCriteria> {
        self.options
            .as_ref()
            .and_then(|opts| opts.selection_criteria.as_ref())
            .into()
    }

    fn read_concern(&self) -> super::Feature<&crate::options::ReadConcern> {
        self.options
            .as_ref()
            .and_then(|opts| opts.read_concern.as_ref())
            .into()
    }

    fn write_concern(&self) -> super::Feature<&WriteConcern> {
        self.options
            .as_ref()
            .and_then(|o| o.write_concern.as_ref())
            .into()
    }

    fn retryability(&self, options: &ClientOptions) -> Retryability {
        if self.is_out_or_merge {
            Retryability::None
        } else {
            Retryability::read(options)
        }
    }

    fn is_backpressure_retryable(&self, options: &ClientOptions) -> bool {
        if self.is_out_or_merge {
            options.retry_writes != Some(false)
        } else {
            options.retry_reads != Some(false)
        }
    }

    fn override_criteria(&self) -> super::OverrideCriteriaFn {
        if !self.is_out_or_merge {
            return |_, _| None;
        }
        |criteria, topology| {
            if criteria == &SelectionCriteria::ReadPreference(ReadPreference::Primary)
                || topology.topology_type() == crate::TopologyType::LoadBalanced
            {
                return None;
            }
            for server in topology.servers.values() {
                if let Ok(Some(v)) = server.max_wire_version() {
                    if v < super::SERVER_5_0_0_WIRE_VERSION {
                        return Some(SelectionCriteria::ReadPreference(ReadPreference::Primary));
                    }
                }
            }
            None
        }
    }

    fn target(&self) -> OperationTarget {
        self.target.clone()
    }

    fn is_after_cluster_time_write(&self) -> bool {
        false
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl OperationImpl for Aggregate {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl crate::otel::OtelInfoDefaults for Aggregate {
    fn output_cursor_id(output: &Self::O) -> Option<i64> {
        Some(output.id())
    }
}

fn target_bson(target: &OperationTarget) -> Bson {
    match target {
        OperationTarget::Database(_) => Bson::Int32(1),
        OperationTarget::Collection(coll) => Bson::String(coll.name().to_owned()),
        OperationTarget::Namespace(ns) => Bson::String(ns.coll.to_owned()),
    }
}
