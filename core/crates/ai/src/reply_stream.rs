use std::collections::BTreeMap;
use std::time::Duration;

use futures_util::StreamExt;
use http::Method;
use sse_stream::SseStream;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::protocol::Protocol;
use crate::reply::Usage;
use crate::{AiClient, AiError, ChatRequest, Endpoint, ReplyEnd, ReplyEvent, StopReason, anthropic, openai};

/// A model that thinks before it writes sends pings meanwhile, so a
/// silence this long is a dead connection.
const IDLE_TIMEOUT: Duration = Duration::from_secs(300);

/// The longest reply kept, in bytes. A chat answer is a few thousand.
/// Streamed tool-call input counts against it too.
const MAX_REPLY_BYTES: usize = 512 * 1024;
/// The most the stream itself may carry: each piece of text comes
/// wrapped in an event of its own, many times its size.
const MAX_STREAM_BYTES: usize = 32 * 1024 * 1024;

/// A closure that takes a `Text` or `ToolCall` event and returns whether
/// the receiver still wants more.
type Emit<'a> = dyn FnMut(ReplyEvent) -> bool + Send + 'a;

/// Stream one reply into `events`: its text and tool calls as they come,
/// then `Finished` or `Failed`. A cancel ends it with neither, and a
/// closed receiver stops it.
pub async fn stream_reply(
    client: &AiClient,
    endpoint: &Endpoint,
    request: &ChatRequest,
    cancel: CancellationToken,
    events: mpsc::UnboundedSender<ReplyEvent>,
) {
    let mut emit = |event: ReplyEvent| events.send(event).is_ok();
    let outcome = tokio::select! {
        biased;
        () = cancel.cancelled() => return,
        outcome = read_reply(client, endpoint, request, &mut emit) => outcome,
    };
    let last = match outcome {
        Ok(end) => ReplyEvent::Finished(end),
        Err(error) => ReplyEvent::Failed(endpoint.scrub(error)),
    };
    // The receiver may be gone already, which only means no one waits.
    let _ = events.send(last);
}

/// The whole reply at once, for a suggestion nobody watches being
/// written. It drops any tool call, since a suggestion offers no tools.
pub async fn collect_reply(
    client: &AiClient,
    endpoint: &Endpoint,
    request: &ChatRequest,
) -> Result<(String, ReplyEnd), AiError> {
    let mut text = String::new();
    let mut emit = |event: ReplyEvent| {
        if let ReplyEvent::Text(part) = event {
            text.push_str(&part);
        }
        true
    };
    let end = read_reply(client, endpoint, request, &mut emit)
        .await
        .map_err(|error| endpoint.scrub(error))?;
    Ok((text, end))
}

async fn read_reply(
    client: &AiClient,
    endpoint: &Endpoint,
    request: &ChatRequest,
    emit: &mut Emit<'_>,
) -> Result<ReplyEnd, AiError> {
    if endpoint.model().is_empty() {
        return Err(AiError::MissingModel);
    }
    let protocol = Protocol::of(endpoint.kind());
    let (path, body) = match protocol {
        Protocol::AnthropicMessages => {
            // A model that writes less than asked for refuses the request.
            let max_tokens = crate::model_list::output_limit(client, endpoint)
                .await
                .map_or(request.max_tokens, |limit| limit.min(request.max_tokens));
            (
                "/messages",
                serde_json::to_vec(&anthropic::request_body(endpoint.model(), request, max_tokens, true)),
            )
        }
        Protocol::ChatCompletions => (
            "/chat/completions",
            serde_json::to_vec(&openai::request_body(endpoint.kind(), endpoint.model(), request, true)),
        ),
    };
    let body = body.map_err(|error| AiError::Protocol(error.to_string()))?;
    let response = client
        .send(endpoint, Method::POST, path, Some(body), "text/event-stream")
        .await?;
    // Bounded before parsing, so a server that never ends a line cannot
    // fill memory with it.
    let body = http_body_util::BodyExt::map_err(
        http_body_util::Limited::new(response.into_body(), MAX_STREAM_BYTES),
        BodyError,
    );
    let mut events = SseStream::new(body);
    let mut reading = Reading::default();
    loop {
        let next = tokio::time::timeout(IDLE_TIMEOUT, events.next())
            .await
            .map_err(|_| AiError::TimedOut {
                host: endpoint.host().to_owned(),
            })?;
        let Some(event) = next else {
            return reading.ended(protocol);
        };
        let event = event.map_err(|error| match error {
            sse_stream::Error::Body(cause)
                if cause
                    .downcast_ref::<BodyError>()
                    .is_some_and(|error| error.0.is::<http_body_util::LengthLimitError>()) =>
            {
                AiError::TooLong
            }
            sse_stream::Error::Body(cause) => AiError::Unreachable {
                host: endpoint.host().to_owned(),
                detail: crate::http_client::error_chain(cause.as_ref()),
            },
            other => AiError::Protocol(other.to_string()),
        })?;
        let Some(data) = event.data else {
            continue;
        };
        let done = match protocol {
            Protocol::AnthropicMessages => reading.anthropic(&data, emit)?,
            Protocol::ChatCompletions => reading.chat_completions(&data, emit)?,
        };
        if done || reading.abandoned {
            return Ok(reading.end);
        }
    }
}

/// The limited body's error, as a type the event parser takes.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
struct BodyError(Box<dyn std::error::Error + Send + Sync>);

#[derive(Default)]
struct Reading {
    end: ReplyEnd,
    bytes: usize,
    /// A finish reason arrived, which some compatible servers send as
    /// their last word without `[DONE]`.
    finished: bool,
    /// The receiver went away, so nothing more is read.
    abandoned: bool,
    tools: ToolCalls,
}

impl Reading {
    fn anthropic(&mut self, data: &str, emit: &mut Emit<'_>) -> Result<bool, AiError> {
        for step in anthropic::decode_event(data)? {
            match step {
                anthropic::Step::Text(text) => self.text(text, emit)?,
                anthropic::Step::ToolStart { index, id, name } => self.tools.start(index as u32, id, name),
                anthropic::Step::ToolInput { index, partial_json } => self.tool_input(index as u32, &partial_json)?,
                // Anthropic ends each block; a stop for a text block has no
                // tool building under its index and emits nothing.
                anthropic::Step::ToolStop { index } => self.finish_tool(index as u32, emit)?,
                anthropic::Step::Usage(usage) => self.usage(usage),
                anthropic::Step::Stop(stop) => self.stop(stop),
                anthropic::Step::Done => return Ok(true),
                anthropic::Step::Ignore => {}
            }
        }
        Ok(false)
    }

    fn chat_completions(&mut self, data: &str, emit: &mut Emit<'_>) -> Result<bool, AiError> {
        if data.trim() == openai::DONE {
            return Ok(true);
        }
        for step in openai::decode_chunk(data)? {
            match step {
                openai::Step::Text(text) => self.text(text, emit)?,
                openai::Step::ToolDelta {
                    index,
                    id,
                    name,
                    arguments,
                } => {
                    self.tools.update(index, id, name);
                    self.tool_input(index, &arguments)?;
                }
                openai::Step::Usage(usage) => self.usage(usage),
                // Chat Completions has no per-call stop; a finish reason
                // ends every call it was building at once.
                openai::Step::Stop(stop) => {
                    self.finish_all_tools(emit)?;
                    self.stop(stop);
                }
            }
        }
        Ok(false)
    }

    fn text(&mut self, text: String, emit: &mut Emit<'_>) -> Result<(), AiError> {
        self.spend(text.len())?;
        if !emit(ReplyEvent::Text(text)) {
            self.abandoned = true;
        }
        Ok(())
    }

    fn tool_input(&mut self, index: u32, fragment: &str) -> Result<(), AiError> {
        self.spend(fragment.len())?;
        self.tools.push_input(index, fragment);
        Ok(())
    }

    fn finish_tool(&mut self, index: u32, emit: &mut Emit<'_>) -> Result<(), AiError> {
        if let Some(call) = self.tools.take(index) {
            self.emit_tool(call, emit)?;
        }
        Ok(())
    }

    fn finish_all_tools(&mut self, emit: &mut Emit<'_>) -> Result<(), AiError> {
        for call in self.tools.take_all() {
            self.emit_tool(call, emit)?;
        }
        Ok(())
    }

    fn emit_tool(&mut self, call: PartialCall, emit: &mut Emit<'_>) -> Result<(), AiError> {
        if !emit(call.into_event()?) {
            self.abandoned = true;
        }
        Ok(())
    }

    fn spend(&mut self, bytes: usize) -> Result<(), AiError> {
        self.bytes += bytes;
        if self.bytes > MAX_REPLY_BYTES {
            return Err(AiError::TooLong);
        }
        Ok(())
    }

    fn usage(&mut self, usage: Usage) {
        let kept = &mut self.end.usage;
        kept.input_tokens = usage.input_tokens.or(kept.input_tokens);
        kept.output_tokens = usage.output_tokens.or(kept.output_tokens);
    }

    fn stop(&mut self, stop: StopReason) {
        self.finished = true;
        // A refusal said in the text is not undone by the finish reason
        // that follows it.
        if self.end.stop != StopReason::Refused {
            self.end.stop = stop;
        }
    }

    /// The body ended. Anthropic always says `message_stop` first, so
    /// without it the connection was cut.
    fn ended(self, protocol: Protocol) -> Result<ReplyEnd, AiError> {
        match protocol {
            Protocol::ChatCompletions if self.finished => Ok(self.end),
            _ => Err(AiError::Protocol("the reply ended before it was complete".to_owned())),
        }
    }
}

/// Tool calls being assembled from the stream, keyed by the index each
/// provider gives them (Anthropic's content-block index, OpenAI's
/// tool-call index). Only one protocol fills this per stream.
#[derive(Default)]
struct ToolCalls {
    building: BTreeMap<u32, PartialCall>,
}

#[derive(Default)]
struct PartialCall {
    id: String,
    name: String,
    input: String,
}

impl ToolCalls {
    fn start(&mut self, index: u32, id: String, name: String) {
        let call = self.building.entry(index).or_default();
        call.id = id;
        call.name = name;
    }

    fn update(&mut self, index: u32, id: Option<String>, name: Option<String>) {
        let call = self.building.entry(index).or_default();
        if let Some(id) = id.filter(|id| !id.is_empty()) {
            call.id = id;
        }
        if let Some(name) = name.filter(|name| !name.is_empty()) {
            call.name = name;
        }
    }

    fn push_input(&mut self, index: u32, fragment: &str) {
        self.building.entry(index).or_default().input.push_str(fragment);
    }

    fn take(&mut self, index: u32) -> Option<PartialCall> {
        self.building.remove(&index)
    }

    fn take_all(&mut self) -> Vec<PartialCall> {
        std::mem::take(&mut self.building).into_values().collect()
    }
}

impl PartialCall {
    fn into_event(self) -> Result<ReplyEvent, AiError> {
        // A tool with no parameters sends no input; its call is still an
        // empty object.
        let input = if self.input.trim().is_empty() {
            serde_json::Value::Object(Default::default())
        } else {
            serde_json::from_str(&self.input).map_err(|error| AiError::Protocol(error.to_string()))?
        };
        Ok(ReplyEvent::ToolCall {
            id: self.id,
            name: self.name,
            input,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Drive a sequence of SSE data payloads through `Reading` and return
    /// the events emitted and the finished reading state.
    fn drive(protocol: Protocol, payloads: &[&str]) -> (Vec<ReplyEvent>, Reading) {
        let mut out = Vec::new();
        let mut reading = Reading::default();
        {
            let mut emit = |event: ReplyEvent| {
                out.push(event);
                true
            };
            for data in payloads {
                let done = match protocol {
                    Protocol::AnthropicMessages => reading.anthropic(data, &mut emit).unwrap(),
                    Protocol::ChatCompletions => reading.chat_completions(data, &mut emit).unwrap(),
                };
                if done {
                    break;
                }
            }
        }
        (out, reading)
    }

    fn parse(json: &str) -> serde_json::Value {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn an_anthropic_tool_use_block_assembles_into_one_tool_call() {
        let payloads = [
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"run_sql","input":{}}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\""}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"SELECT 1\"}"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}"#,
            r#"{"type":"message_stop"}"#,
        ];

        let (events, reading) = drive(Protocol::AnthropicMessages, &payloads);

        assert_eq!(
            events,
            vec![ReplyEvent::ToolCall {
                id: "toolu_1".to_owned(),
                name: "run_sql".to_owned(),
                input: parse(r#"{"query":"SELECT 1"}"#),
            }]
        );
        assert_eq!(reading.end.stop, StopReason::ToolUse);
    }

    #[test]
    fn an_anthropic_text_block_stop_emits_no_tool_call() {
        let payloads = [
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
        ];

        let (events, _) = drive(Protocol::AnthropicMessages, &payloads);

        assert_eq!(events, vec![ReplyEvent::Text("hi".to_owned())]);
    }

    #[test]
    fn an_openai_tool_call_assembles_from_argument_fragments() {
        let payloads = [
            r#"{"choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"run_sql","arguments":""}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"SELECT 1\"}"}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ];

        let (events, reading) = drive(Protocol::ChatCompletions, &payloads);

        assert_eq!(
            events,
            vec![ReplyEvent::ToolCall {
                id: "call_1".to_owned(),
                name: "run_sql".to_owned(),
                input: parse(r#"{"query":"SELECT 1"}"#),
            }]
        );
        assert_eq!(reading.end.stop, StopReason::ToolUse);
    }

    #[test]
    fn two_openai_tool_calls_come_out_in_index_order() {
        let payloads = [
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"a","arguments":"{}"}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"b","arguments":"{}"}}]},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ];

        let (events, _) = drive(Protocol::ChatCompletions, &payloads);

        assert_eq!(
            events,
            vec![
                ReplyEvent::ToolCall {
                    id: "call_a".to_owned(),
                    name: "a".to_owned(),
                    input: parse("{}"),
                },
                ReplyEvent::ToolCall {
                    id: "call_b".to_owned(),
                    name: "b".to_owned(),
                    input: parse("{}"),
                },
            ]
        );
    }
}
