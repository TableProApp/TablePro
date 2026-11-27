//! OpenAI's Chat Completions protocol, which Ollama and other
//! self-hosted servers speak too.

use std::borrow::Cow;

use serde::{Deserialize, Serialize};

use crate::chat_request::{ChatMessage, ContentBlock};
use crate::reply::{StopReason, Usage};
use tablepro_core::AiProvider;

use crate::{AiError, ChatRequest};

/// What a stream sends in place of a last chunk.
pub(crate) const DONE: &str = "[DONE]";

#[derive(Serialize)]
pub(crate) struct RequestBody<'a> {
    model: &'a str,
    messages: Vec<WireMessage<'a>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tools: Vec<WireTool<'a>>,
    stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    stream_options: Option<StreamOptions>,
}

#[derive(Serialize)]
struct WireMessage<'a> {
    role: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    content: Option<Cow<'a, str>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_calls: Option<Vec<WireToolCall<'a>>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_call_id: Option<&'a str>,
}

#[derive(Serialize)]
struct WireToolCall<'a> {
    id: &'a str,
    #[serde(rename = "type")]
    kind: &'static str,
    function: WireFunctionCall<'a>,
}

#[derive(Serialize)]
struct WireFunctionCall<'a> {
    name: &'a str,
    // The API takes the arguments as a JSON string, not an object.
    arguments: String,
}

#[derive(Serialize)]
struct WireTool<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    function: WireFunction<'a>,
}

#[derive(Serialize)]
struct WireFunction<'a> {
    name: &'a str,
    description: &'a str,
    parameters: &'a serde_json::Value,
}

#[derive(Serialize)]
pub(crate) struct StreamOptions {
    include_usage: bool,
}

/// Expand one message into the wire messages it maps to. Text and tool
/// calls stay one message; each tool result is its own `role:"tool"`
/// message, as the API requires.
fn push_message<'a>(out: &mut Vec<WireMessage<'a>>, message: &'a ChatMessage) {
    let mut text = String::new();
    let mut tool_calls = Vec::new();
    let mut results = Vec::new();
    for block in &message.content {
        match block {
            ContentBlock::Text(part) => text.push_str(part),
            ContentBlock::ToolUse { id, name, input } => tool_calls.push(WireToolCall {
                id,
                kind: "function",
                function: WireFunctionCall {
                    name,
                    // Serializing a Value never fails; an empty string on the
                    // impossible error is harmless.
                    arguments: serde_json::to_string(input).unwrap_or_default(),
                },
            }),
            ContentBlock::ToolResult { id, content, .. } => results.push((id.as_str(), content.as_str())),
        }
    }
    let has_text = !text.is_empty();
    if has_text || !tool_calls.is_empty() {
        out.push(WireMessage {
            role: message.role.wire_name(),
            content: has_text.then_some(Cow::Owned(text)),
            tool_calls: (!tool_calls.is_empty()).then_some(tool_calls),
            tool_call_id: None,
        });
    }
    for (id, content) in results {
        out.push(WireMessage {
            role: "tool",
            content: Some(Cow::Borrowed(content)),
            tool_calls: None,
            tool_call_id: Some(id),
        });
    }
}

pub(crate) fn request_body<'a>(
    provider: AiProvider,
    model: &'a str,
    request: &'a ChatRequest,
    stream: bool,
) -> RequestBody<'a> {
    let mut messages = vec![WireMessage {
        role: "system",
        content: Some(Cow::Borrowed(request.system.as_str())),
        tool_calls: None,
        tool_call_id: None,
    }];
    for message in &request.messages {
        push_message(&mut messages, message);
    }
    RequestBody {
        model,
        messages,
        tools: request
            .tools
            .iter()
            .map(|tool| WireTool {
                kind: "function",
                function: WireFunction {
                    name: &tool.name,
                    description: &tool.description,
                    parameters: &tool.input_schema,
                },
            })
            .collect(),
        stream,
        // Not every compatible server knows stream_options, and one that
        // checks its fields strictly would refuse the request.
        stream_options: (stream && provider == AiProvider::OpenAi).then_some(StreamOptions { include_usage: true }),
    }
}

/// What one chunk means. A tool call streams as a run of `ToolDelta`
/// fragments keyed by `index`, finished by `Stop(ToolUse)`.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Step {
    Text(String),
    ToolDelta {
        index: u32,
        id: Option<String>,
        name: Option<String>,
        arguments: String,
    },
    Usage(Usage),
    Stop(StopReason),
}

#[derive(Deserialize)]
struct Chunk {
    #[serde(default)]
    choices: Vec<Choice>,
    #[serde(default)]
    usage: Option<WireUsage>,
    #[serde(default)]
    error: Option<WireError>,
}

#[derive(Deserialize)]
struct Choice {
    #[serde(default)]
    delta: Option<Delta>,
    #[serde(default)]
    message: Option<Delta>,
    #[serde(default)]
    finish_reason: Option<String>,
}

#[derive(Deserialize)]
struct Delta {
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    refusal: Option<String>,
    #[serde(default)]
    tool_calls: Vec<ToolCallDelta>,
}

#[derive(Deserialize)]
struct ToolCallDelta {
    #[serde(default)]
    index: u32,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    function: Option<FunctionDelta>,
}

#[derive(Deserialize)]
struct FunctionDelta {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    arguments: Option<String>,
}

#[derive(Deserialize)]
struct WireUsage {
    #[serde(default)]
    prompt_tokens: Option<u64>,
    #[serde(default)]
    completion_tokens: Option<u64>,
}

/// OpenAI sends an object; Ollama and some other servers a bare string.
#[derive(Deserialize)]
#[serde(untagged)]
pub(crate) enum WireError {
    Object {
        #[serde(default)]
        message: Option<String>,
    },
    Text(String),
}

impl WireError {
    pub(crate) fn into_message(self) -> Option<String> {
        match self {
            Self::Object { message } => message,
            Self::Text(text) => Some(text),
        }
    }
}

/// One stream chunk, or a whole non-streaming answer.
pub(crate) fn decode_chunk(data: &str) -> Result<Vec<Step>, AiError> {
    let chunk: Chunk = serde_json::from_str(data).map_err(|error| AiError::Protocol(error.to_string()))?;
    if let Some(error) = chunk.error {
        return Err(AiError::Provider(
            error.into_message().unwrap_or_else(|| "unknown error".to_owned()),
        ));
    }
    let mut steps = Vec::new();
    for choice in chunk.choices {
        let delta = choice.delta.or(choice.message);
        if let Some(delta) = delta {
            if let Some(text) = delta.content.filter(|text| !text.is_empty()) {
                steps.push(Step::Text(text));
            }
            if delta.refusal.is_some_and(|refusal| !refusal.is_empty()) {
                steps.push(Step::Stop(StopReason::Refused));
            }
            for call in delta.tool_calls {
                let (name, arguments) = match call.function {
                    Some(function) => (function.name, function.arguments.unwrap_or_default()),
                    None => (None, String::new()),
                };
                steps.push(Step::ToolDelta {
                    index: call.index,
                    id: call.id,
                    name,
                    arguments,
                });
            }
        }
        if let Some(reason) = choice.finish_reason {
            steps.push(Step::Stop(match reason.as_str() {
                "length" => StopReason::LengthLimit,
                "content_filter" => StopReason::Refused,
                "tool_calls" => StopReason::ToolUse,
                _ => StopReason::Complete,
            }));
        }
    }
    if let Some(usage) = chunk.usage {
        steps.push(Step::Usage(Usage {
            input_tokens: usage.prompt_tokens,
            output_tokens: usage.completion_tokens,
        }));
    }
    Ok(steps)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat_request::{ContentBlock, Role, ToolSpec};
    use crate::ChatMessage;

    fn parse(json: &str) -> serde_json::Value {
        serde_json::from_str(json).unwrap()
    }

    fn request() -> ChatRequest {
        ChatRequest {
            system: "be brief".to_owned(),
            messages: vec![ChatMessage::user("hi")],
            max_tokens: 1000,
            tools: Vec::new(),
        }
    }

    #[test]
    fn the_system_prompt_is_the_first_message() {
        let request = request();
        let body =
            serde_json::to_value(request_body(AiProvider::OpenAiCompatible, "llama3.2", &request, true)).unwrap();

        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][0]["content"], "be brief");
        assert_eq!(body["messages"][1]["content"], "hi");
        assert_eq!(body["stream"], true);
        assert!(
            body.get("stream_options").is_none(),
            "a compatible server may refuse it"
        );
        assert!(body.get("max_tokens").is_none());
        assert!(body.get("tools").is_none(), "no tools, no field");
    }

    #[test]
    fn the_body_carries_tools_tool_calls_and_tool_messages() {
        let request = ChatRequest {
            system: "help".to_owned(),
            messages: vec![
                ChatMessage::user("list tables"),
                ChatMessage {
                    role: Role::Assistant,
                    content: vec![
                        ContentBlock::Text("calling".to_owned()),
                        ContentBlock::ToolUse {
                            id: "call_1".to_owned(),
                            name: "run_sql".to_owned(),
                            input: parse(r#"{"query":"SELECT 1"}"#),
                        },
                    ],
                },
                ChatMessage {
                    role: Role::User,
                    content: vec![ContentBlock::ToolResult {
                        id: "call_1".to_owned(),
                        content: "1".to_owned(),
                        is_error: false,
                    }],
                },
            ],
            max_tokens: 1000,
            tools: vec![ToolSpec {
                name: "run_sql".to_owned(),
                description: "Run a query".to_owned(),
                input_schema: parse(r#"{"type":"object"}"#),
            }],
        };

        let body = serde_json::to_value(request_body(AiProvider::OpenAi, "m", &request, true)).unwrap();

        assert_eq!(body["tools"][0]["type"], "function");
        assert_eq!(body["tools"][0]["function"]["name"], "run_sql");
        assert_eq!(body["tools"][0]["function"]["description"], "Run a query");
        assert_eq!(body["tools"][0]["function"]["parameters"]["type"], "object");
        // messages: [0] system, [1] user, [2] assistant + tool_calls, [3] tool result.
        assert_eq!(body["messages"][2]["role"], "assistant");
        assert_eq!(body["messages"][2]["content"], "calling");
        assert_eq!(body["messages"][2]["tool_calls"][0]["id"], "call_1");
        assert_eq!(body["messages"][2]["tool_calls"][0]["type"], "function");
        assert_eq!(body["messages"][2]["tool_calls"][0]["function"]["name"], "run_sql");
        // The arguments are a JSON string, not an object.
        assert_eq!(
            body["messages"][2]["tool_calls"][0]["function"]["arguments"],
            r#"{"query":"SELECT 1"}"#
        );
        assert_eq!(body["messages"][3]["role"], "tool");
        assert_eq!(body["messages"][3]["tool_call_id"], "call_1");
        assert_eq!(body["messages"][3]["content"], "1");
    }

    #[test]
    fn openai_is_asked_for_the_usage_of_a_stream() {
        let request = request();
        let body = serde_json::to_value(request_body(AiProvider::OpenAi, "m", &request, true)).unwrap();

        assert_eq!(body["stream_options"]["include_usage"], true);
    }

    #[test]
    fn chunks_give_text_then_the_finish_and_the_usage() {
        let text = r#"{"choices":[{"index":0,"delta":{"role":"assistant","content":"SEL"},"finish_reason":null}]}"#;
        let end = r#"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#;
        let usage = r#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}}"#;

        assert_eq!(decode_chunk(text).unwrap(), vec![Step::Text("SEL".to_owned())]);
        assert_eq!(decode_chunk(end).unwrap(), vec![Step::Stop(StopReason::LengthLimit)]);
        assert_eq!(
            decode_chunk(usage).unwrap(),
            vec![Step::Usage(Usage {
                input_tokens: Some(10),
                output_tokens: Some(3)
            })]
        );
    }

    #[test]
    fn a_tool_call_delta_decodes_with_its_index_id_name_and_arguments() {
        let first = r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"run_sql","arguments":""}}]},"finish_reason":null}]}"#;
        let more = r#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"q\":1}"}}]},"finish_reason":null}]}"#;
        let end = r#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#;

        assert_eq!(
            decode_chunk(first).unwrap(),
            vec![Step::ToolDelta {
                index: 0,
                id: Some("call_1".to_owned()),
                name: Some("run_sql".to_owned()),
                arguments: String::new(),
            }]
        );
        assert_eq!(
            decode_chunk(more).unwrap(),
            vec![Step::ToolDelta {
                index: 0,
                id: None,
                name: None,
                arguments: "{\"q\":1}".to_owned(),
            }]
        );
        assert_eq!(decode_chunk(end).unwrap(), vec![Step::Stop(StopReason::ToolUse)]);
    }

    #[test]
    fn an_error_chunk_fails_in_either_spelling() {
        assert_eq!(
            decode_chunk(r#"{"error":{"message":"model not found"}}"#),
            Err(AiError::Provider("model not found".to_owned()))
        );
        assert_eq!(
            decode_chunk(r#"{"error":"model \"x\" not found, try pulling it first"}"#),
            Err(AiError::Provider(
                "model \"x\" not found, try pulling it first".to_owned()
            ))
        );
    }

    #[test]
    fn a_whole_answer_reads_like_one_chunk() {
        let answer = r#"{"choices":[{"index":0,"message":{"role":"assistant","content":"id"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1}}"#;

        assert_eq!(
            decode_chunk(answer).unwrap(),
            vec![
                Step::Text("id".to_owned()),
                Step::Stop(StopReason::Complete),
                Step::Usage(Usage {
                    input_tokens: Some(4),
                    output_tokens: Some(1)
                })
            ]
        );
    }
}
