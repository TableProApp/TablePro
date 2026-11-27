//! Anthropic's Messages API: the request body and the stream's events.

use serde::{Deserialize, Serialize};

use crate::chat_request::{ChatMessage, ContentBlock};
use crate::reply::{StopReason, Usage};
use crate::{AiError, ChatRequest};

/// The API version the requests are written against. It drops the
/// sampling parameters, which no request here sends.
pub(crate) const API_VERSION: &str = "2026-10-21";

#[derive(Serialize)]
pub(crate) struct RequestBody<'a> {
    model: &'a str,
    max_tokens: u32,
    system: &'a str,
    messages: Vec<WireMessage<'a>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tools: Vec<WireTool<'a>>,
    stream: bool,
}

#[derive(Serialize)]
pub(crate) struct WireMessage<'a> {
    role: &'static str,
    content: WireContent<'a>,
}

/// A plain text turn stays a bare string, as the API also accepts; a
/// turn with a tool block becomes an array of typed blocks.
#[derive(Serialize)]
#[serde(untagged)]
enum WireContent<'a> {
    Text(&'a str),
    Blocks(Vec<WireBlock<'a>>),
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum WireBlock<'a> {
    Text {
        text: &'a str,
    },
    ToolUse {
        id: &'a str,
        name: &'a str,
        input: &'a serde_json::Value,
    },
    ToolResult {
        tool_use_id: &'a str,
        content: &'a str,
        #[serde(skip_serializing_if = "is_false")]
        is_error: bool,
    },
}

#[derive(Serialize)]
struct WireTool<'a> {
    name: &'a str,
    description: &'a str,
    input_schema: &'a serde_json::Value,
}

fn is_false(value: &bool) -> bool {
    !*value
}

fn wire_content(message: &ChatMessage) -> WireContent<'_> {
    if let [ContentBlock::Text(text)] = message.content.as_slice() {
        return WireContent::Text(text);
    }
    WireContent::Blocks(message.content.iter().map(wire_block).collect())
}

fn wire_block(block: &ContentBlock) -> WireBlock<'_> {
    match block {
        ContentBlock::Text(text) => WireBlock::Text { text },
        ContentBlock::ToolUse { id, name, input } => WireBlock::ToolUse { id, name, input },
        ContentBlock::ToolResult { id, content, is_error } => WireBlock::ToolResult {
            tool_use_id: id,
            content,
            is_error: *is_error,
        },
    }
}

pub(crate) fn request_body<'a>(
    model: &'a str,
    request: &'a ChatRequest,
    max_tokens: u32,
    stream: bool,
) -> RequestBody<'a> {
    RequestBody {
        model,
        max_tokens,
        system: &request.system,
        messages: request
            .messages
            .iter()
            .map(|message| WireMessage {
                role: message.role.wire_name(),
                content: wire_content(message),
            })
            .collect(),
        tools: request
            .tools
            .iter()
            .map(|tool| WireTool {
                name: &tool.name,
                description: &tool.description,
                input_schema: &tool.input_schema,
            })
            .collect(),
        stream,
    }
}

/// What one server-sent event means for the reply. A tool_use block
/// arrives as a `ToolStart`, a run of `ToolInput` fragments and a
/// `ToolStop`, assembled into a `ReplyEvent::ToolCall` by the reader.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Step {
    Text(String),
    ToolStart { index: usize, id: String, name: String },
    ToolInput { index: usize, partial_json: String },
    ToolStop { index: usize },
    Usage(Usage),
    Stop(StopReason),
    Done,
    Ignore,
}

#[derive(Deserialize)]
struct Event {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    index: Option<usize>,
    #[serde(default)]
    delta: Option<Delta>,
    #[serde(default)]
    content_block: Option<ContentBlockStart>,
    #[serde(default)]
    usage: Option<WireUsage>,
    #[serde(default)]
    message: Option<StartMessage>,
    #[serde(default)]
    error: Option<WireError>,
}

#[derive(Deserialize)]
struct ContentBlockStart {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
struct Delta {
    #[serde(rename = "type", default)]
    kind: Option<String>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    partial_json: Option<String>,
    #[serde(default)]
    stop_reason: Option<String>,
}

#[derive(Deserialize)]
struct StartMessage {
    #[serde(default)]
    usage: Option<WireUsage>,
}

#[derive(Deserialize, Default)]
struct WireUsage {
    #[serde(default)]
    input_tokens: Option<u64>,
    #[serde(default)]
    output_tokens: Option<u64>,
}

#[derive(Deserialize)]
pub(crate) struct WireError {
    #[serde(default)]
    pub message: Option<String>,
}

pub(crate) fn decode_event(data: &str) -> Result<Vec<Step>, AiError> {
    let event: Event = serde_json::from_str(data).map_err(|error| AiError::Protocol(error.to_string()))?;
    let mut steps = Vec::new();
    match event.kind.as_str() {
        "message_start" => {
            if let Some(usage) = event.message.and_then(|message| message.usage) {
                steps.push(Step::Usage(Usage {
                    input_tokens: usage.input_tokens,
                    output_tokens: None,
                }));
            }
        }
        "content_block_start" => {
            if let Some(block) = event.content_block.filter(|block| block.kind == "tool_use") {
                steps.push(Step::ToolStart {
                    index: event.index.unwrap_or_default(),
                    id: block.id.unwrap_or_default(),
                    name: block.name.unwrap_or_default(),
                });
            }
        }
        "content_block_delta" => {
            if let Some(delta) = event.delta {
                match delta.kind.as_deref() {
                    Some("text_delta") => {
                        if let Some(text) = delta.text.filter(|text| !text.is_empty()) {
                            steps.push(Step::Text(text));
                        }
                    }
                    Some("input_json_delta") => {
                        if let Some(partial_json) = delta.partial_json {
                            steps.push(Step::ToolInput {
                                index: event.index.unwrap_or_default(),
                                partial_json,
                            });
                        }
                    }
                    // Thinking and signature deltas are the model's own and
                    // are not shown.
                    _ => {}
                }
            }
        }
        "content_block_stop" => steps.push(Step::ToolStop {
            index: event.index.unwrap_or_default(),
        }),
        "message_delta" => {
            if let Some(usage) = event.usage {
                steps.push(Step::Usage(Usage {
                    input_tokens: usage.input_tokens,
                    output_tokens: usage.output_tokens,
                }));
            }
            if let Some(reason) = event.delta.and_then(|delta| delta.stop_reason) {
                steps.push(Step::Stop(stop_reason(&reason)));
            }
        }
        "message_stop" => steps.push(Step::Done),
        "error" => {
            let message = event
                .error
                .and_then(|error| error.message)
                .unwrap_or_else(|| "unknown error".to_owned());
            return Err(AiError::Provider(message));
        }
        _ => steps.push(Step::Ignore),
    }
    Ok(steps)
}

fn stop_reason(reason: &str) -> StopReason {
    match reason {
        "max_tokens" | "model_context_window_exceeded" => StopReason::LengthLimit,
        "refusal" => StopReason::Refused,
        "tool_use" => StopReason::ToolUse,
        _ => StopReason::Complete,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ChatMessage;
    use crate::chat_request::{ContentBlock, Role, ToolSpec};

    fn parse(json: &str) -> serde_json::Value {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn the_body_sends_the_system_prompt_and_the_turns_as_text() {
        let request = ChatRequest {
            system: "be brief".to_owned(),
            messages: vec![
                ChatMessage::user("hi"),
                ChatMessage::assistant("hello"),
                ChatMessage::user("more"),
            ],
            max_tokens: 1000,
            tools: Vec::new(),
        };

        let body = serde_json::to_value(request_body("claude-opus-5-5", &request, request.max_tokens, true)).unwrap();

        assert_eq!(body["model"], "claude-opus-5-5");
        assert_eq!(body["system"], "be brief");
        assert_eq!(body["max_tokens"], 1000);
        assert_eq!(body["stream"], true);
        assert_eq!(body["messages"][1]["role"], "assistant");
        assert_eq!(body["messages"][2]["content"], "more");
        assert!(body.get("temperature").is_none());
        assert!(body.get("tools").is_none(), "no tools, no field");
    }

    #[test]
    fn the_body_carries_tools_and_tool_use_and_tool_result_blocks() {
        let request = ChatRequest {
            system: "help".to_owned(),
            messages: vec![
                ChatMessage::user("list tables"),
                ChatMessage {
                    role: Role::Assistant,
                    content: vec![ContentBlock::ToolUse {
                        id: "toolu_1".to_owned(),
                        name: "run_sql".to_owned(),
                        input: parse(r#"{"query":"SELECT 1"}"#),
                    }],
                },
                ChatMessage {
                    role: Role::User,
                    content: vec![ContentBlock::ToolResult {
                        id: "toolu_1".to_owned(),
                        content: "1".to_owned(),
                        is_error: false,
                    }],
                },
            ],
            max_tokens: 1000,
            tools: vec![ToolSpec {
                name: "run_sql".to_owned(),
                description: "Run a query".to_owned(),
                input_schema: parse(r#"{"type":"object","properties":{"query":{"type":"string"}}}"#),
            }],
        };

        let body = serde_json::to_value(request_body("m", &request, 1000, true)).unwrap();

        assert_eq!(body["tools"][0]["name"], "run_sql");
        assert_eq!(body["tools"][0]["description"], "Run a query");
        assert_eq!(body["tools"][0]["input_schema"]["type"], "object");
        // A plain text turn stays a bare string.
        assert_eq!(body["messages"][0]["content"], "list tables");
        // The model's call is a tool_use block with the input as JSON.
        assert_eq!(body["messages"][1]["content"][0]["type"], "tool_use");
        assert_eq!(body["messages"][1]["content"][0]["id"], "toolu_1");
        assert_eq!(body["messages"][1]["content"][0]["input"]["query"], "SELECT 1");
        // Its result is a tool_result block keyed by tool_use_id.
        assert_eq!(body["messages"][2]["content"][0]["type"], "tool_result");
        assert_eq!(body["messages"][2]["content"][0]["tool_use_id"], "toolu_1");
        assert_eq!(body["messages"][2]["content"][0]["content"], "1");
        assert!(
            body["messages"][2]["content"][0].get("is_error").is_none(),
            "a success omits is_error"
        );
    }

    #[test]
    fn text_deltas_are_shown_and_thinking_is_not() {
        let text = r#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"SELECT"}}"#;
        let thinking = r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#;

        assert_eq!(decode_event(text).unwrap(), vec![Step::Text("SELECT".to_owned())]);
        assert_eq!(decode_event(thinking).unwrap(), Vec::<Step>::new());
    }

    #[test]
    fn a_tool_use_block_decodes_to_start_input_and_stop_steps() {
        let start = r#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"run_sql","input":{}}}"#;
        let input =
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"q\":"}}"#;
        let stop = r#"{"type":"content_block_stop","index":1}"#;

        assert_eq!(
            decode_event(start).unwrap(),
            vec![Step::ToolStart {
                index: 1,
                id: "toolu_1".to_owned(),
                name: "run_sql".to_owned(),
            }]
        );
        assert_eq!(
            decode_event(input).unwrap(),
            vec![Step::ToolInput {
                index: 1,
                partial_json: "{\"q\":".to_owned(),
            }]
        );
        assert_eq!(decode_event(stop).unwrap(), vec![Step::ToolStop { index: 1 }]);
    }

    #[test]
    fn usage_and_the_stop_reason_come_with_the_message_delta() {
        let start = r#"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":120,"output_tokens":1}}}"#;
        let delta = r#"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":7}}"#;

        assert_eq!(
            decode_event(start).unwrap(),
            vec![Step::Usage(Usage {
                input_tokens: Some(120),
                output_tokens: None
            })]
        );
        assert_eq!(
            decode_event(delta).unwrap(),
            vec![
                Step::Usage(Usage {
                    input_tokens: None,
                    output_tokens: Some(7)
                }),
                Step::Stop(StopReason::Refused)
            ]
        );
        assert_eq!(decode_event(r#"{"type":"message_stop"}"#).unwrap(), vec![Step::Done]);
    }

    #[test]
    fn the_tool_use_stop_reason_maps_to_tool_use() {
        let delta = r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}"#;

        assert_eq!(
            decode_event(delta).unwrap(),
            vec![
                Step::Usage(Usage {
                    input_tokens: None,
                    output_tokens: Some(3)
                }),
                Step::Stop(StopReason::ToolUse)
            ]
        );
    }

    #[test]
    fn an_error_event_fails_the_reply_with_its_message() {
        let error = r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#;

        assert_eq!(decode_event(error), Err(AiError::Provider("Overloaded".to_owned())));
        assert_eq!(decode_event(r#"{"type":"ping"}"#).unwrap(), vec![Step::Ignore]);
        assert!(matches!(decode_event("not json"), Err(AiError::Protocol(_))));
    }
}
