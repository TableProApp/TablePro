//! OpenAI's Chat Completions protocol, which Ollama and other
//! self-hosted servers speak too.

use serde::{Deserialize, Serialize};

use crate::reply::{StopReason, Usage};
use tablepro_core::AiProvider;

use crate::{AiError, ChatRequest};

/// What a stream sends in place of a last chunk.
pub(crate) const DONE: &str = "[DONE]";

#[derive(Serialize)]
pub(crate) struct RequestBody<'a> {
    model: &'a str,
    messages: Vec<WireMessage<'a>>,
    stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    stream_options: Option<StreamOptions>,
}

#[derive(Serialize)]
pub(crate) struct WireMessage<'a> {
    role: &'static str,
    content: &'a str,
}

#[derive(Serialize)]
pub(crate) struct StreamOptions {
    include_usage: bool,
}

pub(crate) fn request_body<'a>(
    provider: AiProvider,
    model: &'a str,
    request: &'a ChatRequest,
    stream: bool,
) -> RequestBody<'a> {
    let mut messages = vec![WireMessage {
        role: "system",
        content: &request.system,
    }];
    messages.extend(request.messages.iter().map(|message| WireMessage {
        role: message.role.wire_name(),
        content: &message.text,
    }));
    RequestBody {
        model,
        messages,
        stream,
        // Not every compatible server knows stream_options, and one that
        // checks its fields strictly would refuse the request.
        stream_options: (stream && provider == AiProvider::OpenAi).then_some(StreamOptions { include_usage: true }),
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Step {
    Text(String),
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
        }
        if let Some(reason) = choice.finish_reason {
            steps.push(Step::Stop(match reason.as_str() {
                "length" => StopReason::LengthLimit,
                "content_filter" => StopReason::Refused,
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
    use crate::ChatMessage;

    fn request() -> ChatRequest {
        ChatRequest {
            system: "be brief".to_owned(),
            messages: vec![ChatMessage::user("hi")],
            max_tokens: 1000,
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
