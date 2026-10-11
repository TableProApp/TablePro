use std::collections::HashMap;

use opentelemetry::SpanId;
use opentelemetry_sdk::trace::{
    BatchSpanProcessor,
    InMemorySpanExporter,
    InMemorySpanExporterBuilder,
    SdkTracerProvider,
    SpanData,
};
use serde::Deserialize;

use crate::{
    bson::{doc, Bson, Document},
    test::spec::unified_runner::{results_match, EntityMap, TestRunner},
};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ObserveTracingMessages {
    enable_command_payload: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ExpectedTracingMessages {
    client: String,
    ignore_extra_spans: Option<bool>,
    spans: Vec<ExpectedSpan>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExpectedSpan {
    name: String,
    attributes: Document,
    #[serde(default)]
    nested: Vec<ExpectedSpan>,
}

#[derive(Clone, Debug)]
pub(crate) struct ClientTracing {
    exporter: InMemorySpanExporter,
    provider: SdkTracerProvider,
}

impl ClientTracing {
    pub(crate) fn new(observe: &ObserveTracingMessages) -> (Self, super::OpentelemetryOptions) {
        let exporter = InMemorySpanExporterBuilder::new().build();
        let provider = SdkTracerProvider::builder()
            .with_span_processor(BatchSpanProcessor::builder(exporter.clone()).build())
            .build();
        let mut options = super::OpentelemetryOptions::builder()
            .enabled(true)
            .tracer_provider(provider.clone())
            .build();
        if observe.enable_command_payload.unwrap_or(false) {
            options.query_text_max_length = Some(1000);
        }
        (Self { exporter, provider }, options)
    }
}

impl TestRunner {
    pub(crate) async fn match_spans(
        &self,
        expected: &ExpectedTracingMessages,
    ) -> Result<(), String> {
        let client_tracing = self.get_client(&expected.client).await.tracing.unwrap();
        client_tracing.provider.force_flush().unwrap();
        let mut root_spans = vec![];
        let mut nested_spans = HashMap::<SpanId, Vec<SpanData>>::new();
        for span in client_tracing.exporter.get_finished_spans().unwrap() {
            if span.parent_span_id == SpanId::INVALID {
                root_spans.push(span);
            } else {
                nested_spans
                    .entry(span.parent_span_id)
                    .or_default()
                    .push(span);
            }
        }
        let (root_spans, nested_spans) = (root_spans, nested_spans);

        let entities = self.entities.read().await;
        Matcher {
            nested: &nested_spans,
            entities: &entities,
            ignore_extra: expected.ignore_extra_spans.unwrap_or(false),
        }
        .match_span_slice(&root_spans, &expected.spans)?;

        Ok(())
    }
}

struct Matcher<'a> {
    nested: &'a HashMap<SpanId, Vec<SpanData>>,
    entities: &'a EntityMap,
    ignore_extra: bool,
}

impl<'a> Matcher<'a> {
    fn match_span_slice(
        &self,
        actual: &[SpanData],
        expected: &[ExpectedSpan],
    ) -> Result<(), String> {
        let err_suffix = || format!("actual:\n{:#?}\n\nexpected:\n{:#?}", actual, expected);
        if self.ignore_extra {
            if actual.len() < expected.len() {
                return Err(format!(
                    "expected at least {} spans, got {}\n{}",
                    expected.len(),
                    actual.len(),
                    err_suffix(),
                ));
            }
            let mut actual = actual;
            let mut expected = expected;
            while let Some((exp_span, rest)) = expected.split_first() {
                expected = rest;
                let act_span = loop {
                    let Some((span, rest)) = actual.split_first() else {
                        return Err(format!(
                            "no span found with name {:?}\n{}",
                            exp_span.name,
                            err_suffix(),
                        ));
                    };
                    actual = rest;
                    if span.name == exp_span.name {
                        break span;
                    }
                };
                self.match_span(act_span, exp_span)?;
            }
        } else {
            if actual.len() != expected.len() {
                return Err(format!(
                    "expected exactly {} spans, got {}\n{}",
                    expected.len(),
                    actual.len(),
                    err_suffix(),
                ));
            }

            for (act_span, exp_span) in actual.iter().zip(expected) {
                self.match_span(act_span, exp_span)?;
            }
        }

        Ok(())
    }

    fn match_span(&self, actual: &SpanData, expected: &ExpectedSpan) -> Result<(), String> {
        let err_suffix = || format!("actual:\n{:#?}\nexpected:\n{:#?}", actual, expected);
        if expected.name != actual.name {
            return Err(format!(
                "expected name {:?}, got {:?}\n{}",
                expected.name,
                actual.name,
                err_suffix(),
            ));
        }
        let mut actual_attrs = doc! {};
        for kv in &actual.attributes {
            let key = kv.key.as_str();
            let value = match key {
                "db.mongodb.lsid" => match &kv.value {
                    opentelemetry::Value::String(s) => {
                        let doc: Bson = serde_json::from_str::<serde_json::Value>(s.as_str())
                            .map_err(|e| format!("serde_json error: {}", e))?
                            .try_into()
                            .map_err(|e| format!("json value error: {}", e))?;
                        doc
                    }
                    _ => return Err(format!("unexpected type for {:?}: {:?}", key, kv.value)),
                },
                _ => value_to_bson(&kv.value)?,
            };
            actual_attrs.insert(key, value);
        }
        for (k, expected_v) in &expected.attributes {
            if let Err(e) =
                results_match(actual_attrs.get(k), expected_v, false, Some(self.entities))
            {
                return Err(format!("span attribute {}: {}\n{}", k, e, err_suffix()));
            }
        }

        let actual_nested = self
            .nested
            .get(&actual.span_context.span_id())
            .map(|v| v.as_slice())
            .unwrap_or(&[]);
        self.match_span_slice(actual_nested, &expected.nested)?;

        Ok(())
    }
}

fn value_to_bson(val: &opentelemetry::Value) -> Result<Bson, String> {
    use opentelemetry::{Array, Value};
    Ok(match val {
        Value::Bool(b) => Bson::Boolean(*b),
        Value::I64(i) => Bson::Int64(*i),
        Value::F64(f) => Bson::Double(*f),
        Value::String(sv) => Bson::String(sv.as_str().to_owned()),
        Value::Array(array) => match array {
            Array::Bool(items) => items.into(),
            Array::I64(items) => items.into(),
            Array::F64(items) => items.into(),
            Array::String(items) => items.iter().map(|i| i.as_str()).collect::<Vec<_>>().into(),
            _ => return Err(format!("unhandled opentelemetry array {:?}", array)),
        },
        _ => return Err(format!("unhandled opentelemetry value {:?}", val)),
    })
}
