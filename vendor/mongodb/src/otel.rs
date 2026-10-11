//! Support for OpenTelemetry.

use std::{
    future::Future,
    sync::{Arc, LazyLock},
};

use derive_where::derive_where;

use opentelemetry::{
    global::{BoxedTracer, ObjectSafeTracerProvider},
    trace::{SpanKind, TraceContextExt, Tracer, TracerProvider},
    Context,
    KeyValue,
};

use crate::{
    bson::Bson,
    cmap::{conn::wire::Message, Command, ConnectionInfo, StreamDescription},
    error::{ErrorKind, Result},
    operation::{Operation, OperationTarget},
    options::{ClientOptions, ServerAddress, DEFAULT_PORT},
    Client,
    ClientSession,
};

#[cfg(test)]
pub(crate) mod testing;

/// Configuration for OpenTelemetry.
#[derive(Clone, serde::Deserialize, typed_builder::TypedBuilder)]
#[derive_where(Debug, PartialEq)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct OpentelemetryOptions {
    /// Enables or disables OpenTelemtry for this client instance.  If unset, will use the value of
    /// the `OTEL_RUST_INSTRUMENTATION_MONGODB_ENABLED` environment variable.
    pub enabled: Option<bool>,
    /// Maximum length of the `db.query.text` attribute of command spans.  If unset, will use the
    /// value of the `OTEL_RUST_INSTRUMENTATION_MONGODB_QUERY_TEXT_MAX_LENGTH` environment
    /// variable.
    pub query_text_max_length: Option<usize>,
    /// Tracer provider to use.  If unset, will use the global instance.
    #[serde(skip)]
    #[derive_where(skip)]
    #[builder(
        setter(
            fn transform<S, T, P>(provider: P) -> Option<Arc<dyn ObjectSafeTracerProvider + Send + Sync>>
                where
                    S: opentelemetry::trace::Span + Send + Sync + 'static,
                    T: Tracer<Span = S> + Send + Sync + 'static,
                    P: TracerProvider<Tracer = T> + Send + Sync + 'static,
            {
                Some(Arc::new(provider))
            },
        )
    )]
    pub tracer_provider: Option<Arc<dyn ObjectSafeTracerProvider + Send + Sync>>,
}

impl ClientOptions {
    pub(crate) fn tracer(&self) -> BoxedTracer {
        let provider: &dyn ObjectSafeTracerProvider = match self
            .tracing
            .as_ref()
            .and_then(|t| t.tracer_provider.as_ref())
        {
            Some(provider) => &**provider,
            None => &opentelemetry::global::tracer_provider(),
        };
        BoxedTracer::new(
            provider.boxed_tracer(
                opentelemetry::InstrumentationScope::builder("mongodb")
                    .with_version(env!("CARGO_PKG_VERSION"))
                    .build(),
            ),
        )
    }

    fn otel_enabled(&self) -> bool {
        static ENABLED_ENV: LazyLock<bool> = LazyLock::new(|| {
            match std::env::var("OTEL_RUST_INSTRUMENTATION_MONGODB_ENABLED").as_deref() {
                Ok("1" | "true" | "yes") => true,
                _ => false,
            }
        });

        self.tracing
            .as_ref()
            .and_then(|t| t.enabled)
            .unwrap_or_else(|| *ENABLED_ENV)
    }

    fn otel_query_text_max_length(&self) -> usize {
        static MAX_LENGTH_ENV: LazyLock<usize> = LazyLock::new(|| {
            std::env::var("OTEL_RUST_INSTRUMENTATION_MONGODB_QUERY_TEXT_MAX_LENGTH")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0)
        });

        self.tracing
            .as_ref()
            .and_then(|t| t.query_text_max_length)
            .unwrap_or_else(|| *MAX_LENGTH_ENV)
    }
}

impl Client {
    pub(crate) fn start_operation_span(
        &self,
        op: &impl Operation,
        session: Option<&ClientSession>,
    ) -> OpSpan {
        let op = op.otel();
        if !self.options().otel_enabled() {
            return OpSpan {
                context: Context::current(),
                enabled: false,
            };
        }
        let span_name = format!("{} {}", op.log_name(), op_target(op));
        let mut attrs = common_attrs(op);
        attrs.extend([
            KeyValue::new("db.operation.name", op.log_name().to_owned()),
            KeyValue::new("db.operation.summary", span_name.clone()),
        ]);
        let builder = self
            .tracer()
            .span_builder(span_name)
            .with_kind(SpanKind::Client)
            .with_attributes(attrs);
        let context = if let Some(TxnSpan(txn_ctx)) =
            session.and_then(|s| s.transaction.otel_span.as_ref())
        {
            txn_ctx.with_span(builder.start_with_context(self.tracer(), txn_ctx))
        } else {
            Context::current_with_span(builder.start(self.tracer()))
        };
        OpSpan {
            context,
            enabled: true,
        }
    }

    pub(crate) fn start_command_span(
        &self,
        op: &impl Operation,
        conn_info: &ConnectionInfo,
        stream_desc: &StreamDescription,
        message: &Message,
        cmd_attrs: CommandAttributes,
    ) -> CmdSpan {
        let op = op.otel();
        if !self.options().otel_enabled() || cmd_attrs.should_redact {
            return CmdSpan {
                context: Context::current(),
                enabled: false,
            };
        }
        let otel_driver_conn_id: i64 = conn_info.id.into();
        let mut attrs = common_attrs(op);
        attrs.extend(cmd_attrs.attrs);
        attrs.extend([
            KeyValue::new(
                "db.query.summary",
                format!("{} {}", cmd_attrs.name, op_target(op)),
            ),
            KeyValue::new("db.mongodb.driver_connection_id", otel_driver_conn_id),
            KeyValue::new("server.type", stream_desc.initial_server_type.to_string()),
        ]);
        match &conn_info.address {
            ServerAddress::Tcp { host, port } => {
                let otel_port: i64 = port.unwrap_or(DEFAULT_PORT).into();
                attrs.extend([
                    KeyValue::new("server.port", otel_port),
                    KeyValue::new("server.address", host.clone()),
                    KeyValue::new("network.transport", "tcp"),
                ]);
            }
            #[cfg(unix)]
            ServerAddress::Unix { path } => {
                attrs.extend([
                    KeyValue::new("server.address", path.to_string_lossy().into_owned()),
                    KeyValue::new("network.transport", "unix"),
                ]);
            }
        }
        if let Some(server_id) = &conn_info.server_id {
            attrs.push(KeyValue::new("db.mongodb.server_connection_id", *server_id));
        }
        let text_max_len = self.options().otel_query_text_max_length();
        if text_max_len > 0 {
            let doc = message.get_raw_command_document();

            attrs.push(KeyValue::new(
                "db.query.text",
                crate::bson_util::rawdoc_to_json_str_otel(&doc, text_max_len)
                    .unwrap_or_else(crate::bson_util::doc_err),
            ));
        }
        if let Some(cursor_id) = op.cursor_id() {
            attrs.push(KeyValue::new("db.mongodb.cursor_id", cursor_id));
        }
        let span = self
            .tracer()
            .span_builder(cmd_attrs.name)
            .with_kind(SpanKind::Client)
            .with_attributes(attrs)
            .start(self.tracer());
        CmdSpan {
            context: Context::current_with_span(span),
            enabled: true,
        }
    }

    pub(crate) fn start_transaction_span(&self) -> TxnSpan {
        if !self.options().otel_enabled() {
            return TxnSpan(Context::current());
        }
        let span = self
            .tracer()
            .span_builder("transaction")
            .with_kind(SpanKind::Client)
            .with_attributes([
                KeyValue::new("db.system", "mongodb"),
                KeyValue::new("db.system.name", "mongodb"),
            ])
            .start(self.tracer());
        TxnSpan(Context::current_with_span(span))
    }
}

pub(crate) struct OpSpan {
    context: Context,
    enabled: bool,
}

impl OpSpan {
    pub(crate) fn record_error<T>(&self, result: &Result<T>) {
        if !self.enabled {
            return;
        }
        record_error(&self.context, result);
    }
}

pub(crate) struct CmdSpan {
    context: Context,
    enabled: bool,
}

impl CmdSpan {
    pub(crate) fn record_command_result<Op: Operation>(&self, result: &Result<Op::O>) {
        if !self.enabled {
            return;
        }
        if let Ok(out) = result {
            if let Some(cursor_id) = <Op::Otel as OtelWitness>::output_cursor_id(out) {
                let span = self.context.span();
                span.set_attribute(KeyValue::new("db.mongodb.cursor_id", cursor_id));
            }
        }
        record_error(&self.context, result);
    }
}

#[derive(Debug)]
pub(crate) struct TxnSpan(Context);

fn record_error<T>(context: &Context, result: &Result<T>) {
    let error = if let Err(error) = result {
        error
    } else {
        return;
    };
    let span = context.span();
    span.set_attributes([
        KeyValue::new("exception.message", error.to_string()),
        KeyValue::new("exception.type", error.kind.name()),
        #[cfg(feature = "error-backtrace")]
        KeyValue::new("exception.stacktrace", error.backtrace.to_string()),
    ]);
    if let ErrorKind::Command(cmd_err) = &*error.kind {
        span.set_attribute(KeyValue::new(
            "db.response.status_code",
            cmd_err.code.to_string(),
        ));
    }
    span.record_error(error);
    span.set_status(opentelemetry::trace::Status::Error {
        description: error.to_string().into(),
    });
}

fn op_target(op: &impl OtelInfo) -> String {
    let target = op.target();
    let name = target.name();
    if let Some(coll) = name.collection {
        format!("{}.{}", name.database, coll)
    } else {
        name.database.to_owned()
    }
}

fn common_attrs(op: &impl OtelInfo) -> Vec<KeyValue> {
    let target = op.target();
    let name = target.name();
    let mut attrs = vec![
        KeyValue::new("db.system", "mongodb"),
        KeyValue::new("db.system.name", "mongodb"),
        KeyValue::new("db.namespace", name.database.to_owned()),
    ];
    if let Some(coll) = name.collection {
        attrs.push(KeyValue::new("db.collection.name", coll.to_owned()));
    }
    attrs
}

#[derive(Clone)]
pub(crate) struct CommandAttributes {
    should_redact: bool,
    name: String,
    attrs: Vec<KeyValue>,
}

impl CommandAttributes {
    pub(crate) fn new(cmd: &Command) -> Self {
        let mut attrs = vec![KeyValue::new("db.command.name", cmd.name.clone())];
        if let Some(lsid) = &cmd.lsid {
            attrs.push(KeyValue::new(
                "db.mongodb.lsid",
                Bson::Document(lsid.clone())
                    .into_relaxed_extjson()
                    .to_string(),
            ));
        }
        if let Some(txn_number) = &cmd.txn_number {
            attrs.push(KeyValue::new("db.mongodb.txn_number", *txn_number));
        }
        Self {
            should_redact: cmd.should_redact(),
            name: cmd.name.clone(),
            attrs,
        }
    }
}

pub(crate) trait OtelWitness {
    type Op: OtelInfo;
    fn otel(op: &Self::Op) -> &impl OtelInfo {
        op
    }
    fn output_cursor_id(output: &<Self::Op as Operation>::O) -> Option<i64> {
        Self::Op::output_cursor_id(output)
    }
}

pub(crate) struct Witness<T: OtelInfo> {
    _t: std::marker::PhantomData<T>,
}

impl<T: OtelInfo> OtelWitness for Witness<T> {
    type Op = T;
}

pub(crate) trait OtelInfo: Operation {
    fn log_name(&self) -> &str;

    fn cursor_id(&self) -> Option<i64>;

    fn output_cursor_id(output: &<Self as Operation>::O) -> Option<i64>;
}

pub(crate) trait OtelInfoDefaults: Operation {
    fn log_name(&self) -> &str {
        crate::bson_compat::cstr_to_str(self.name())
    }

    fn cursor_id(&self) -> Option<i64> {
        None
    }

    fn output_cursor_id(_output: &<Self as Operation>::O) -> Option<i64> {
        None
    }
}

impl<T: OtelInfoDefaults> OtelInfo for T {
    fn log_name(&self) -> &str {
        self.log_name()
    }

    fn cursor_id(&self) -> Option<i64> {
        self.cursor_id()
    }

    fn output_cursor_id(output: &<Self as Operation>::O) -> Option<i64> {
        T::output_cursor_id(output)
    }
}

pub(crate) struct TargetName<'a> {
    pub(crate) database: &'a str,
    pub(crate) collection: Option<&'a str>,
}

impl OperationTarget {
    fn name(&self) -> TargetName<'_> {
        match self {
            OperationTarget::Database(db) => TargetName {
                database: db.name(),
                collection: None,
            },
            OperationTarget::Collection(coll) => TargetName {
                database: coll.db().name(),
                collection: Some(coll.name()),
            },
            OperationTarget::Namespace(ns) => TargetName {
                database: &ns.db,
                collection: Some(&ns.coll),
            },
        }
    }
}

pub(crate) trait FutureExt: Future + Sized {
    fn with_span(self, span: &OpSpan) -> impl Future<Output = Self::Output> {
        use opentelemetry::context::FutureExt;
        self.with_context(span.context.clone())
    }
}

impl<T: Future> FutureExt for T {}
