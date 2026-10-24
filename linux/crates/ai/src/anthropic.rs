//! Anthropic's Messages API: the request body and the stream's events.

use serde::{Deserialize, Serialize};

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
    stream: bool,
}

#[derive(Serialize)]
pub(crate) struct WireMessage<'a> {
    role: &'static str,
    content: &'a str,
}

pub(crate) fn request_body<'a>(
    model: &'a str,
    request: &'a ChatRequest,
    max_tokens: u32,
    stream: bool,
) -> RequestBody<'a> {
    // Text only: a thinking block from an earlier turn is never sent
    // back, so no history check can refuse an edited conversation.
    RequestBody {
        model,
        max_tokens,
        system: &request.system,
        messages: request
            .messages
            .iter()
            .map(|message| WireMessage {
                role: message.role.wire_name(),
                content: &message.text,
            })
            .collect(),
        stream,
    }
}

/// What one server-sent event means for the reply.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Step {
    Text(String),
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
    delta: Option<Delta>,
    #[serde(default)]
    usage: Option<WireUsage>,
    #[serde(default)]
    message: Option<StartMessage>,
    #[serde(default)]
    error: Option<WireError>,
}

#[derive(Deserialize)]
struct Delta {
    #[serde(rename = "type", default)]
    kind: Option<String>,
    #[serde(default)]
    text: Option<String>,
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
        "content_block_delta" => {
            // Thinking and signature deltas are the model's own and are
            // not shown.
            if let Some(Delta {
                kind: Some(kind),
                text: Some(text),
                ..
            }) = event.delta
                && kind == "text_delta"
                && !text.is_empty()
            {
                steps.push(Step::Text(text));
            }
        }
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
        _ => StopReason::Complete,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ChatMessage;

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
        };

        let body = serde_json::to_value(request_body("claude-opus-5-5", &request, request.max_tokens, true)).unwrap();

        assert_eq!(body["model"], "claude-opus-5-5");
        assert_eq!(body["system"], "be brief");
        assert_eq!(body["max_tokens"], 1000);
        assert_eq!(body["stream"], true);
        assert_eq!(body["messages"][1]["role"], "assistant");
        assert_eq!(body["messages"][2]["content"], "more");
        assert!(body.get("temperature").is_none());
    }

    #[test]
    fn text_deltas_are_shown_and_thinking_is_not() {
        let text = r#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"SELECT"}}"#;
        let thinking = r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#;

        assert_eq!(decode_event(text).unwrap(), vec![Step::Text("SELECT".to_owned())]);
        assert_eq!(decode_event(thinking).unwrap(), Vec::<Step>::new());
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
    fn an_error_event_fails_the_reply_with_its_message() {
        let error = r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#;

        assert_eq!(decode_event(error), Err(AiError::Provider("Overloaded".to_owned())));
        assert_eq!(decode_event(r#"{"type":"ping"}"#).unwrap(), vec![Step::Ignore]);
        assert!(matches!(decode_event("not json"), Err(AiError::Protocol(_))));
    }
}
