use crate::AiError;

/// What a streaming reply sends, in order: text and tool calls as they
/// arrive, then one `Finished` or `Failed`.
// Not `Eq`: a tool call's input is a `serde_json::Value`, whose numbers
// are not `Eq`.
#[derive(Debug, Clone, PartialEq)]
pub enum ReplyEvent {
    Text(String),
    /// A tool call assembled from the stream, ready for the agent loop
    /// to run. `input` is the parsed arguments.
    ToolCall {
        id: String,
        name: String,
        input: serde_json::Value,
    },
    Finished(ReplyEnd),
    Failed(AiError),
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReplyEnd {
    pub stop: StopReason,
    pub usage: Usage,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum StopReason {
    #[default]
    Complete,
    /// The reply reached the token limit and stops mid-way.
    LengthLimit,
    /// The model declined to answer.
    Refused,
    /// The model called one or more tools and waits for their results.
    ToolUse,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Usage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
}

impl Usage {
    pub fn total(self) -> Option<u64> {
        match (self.input_tokens, self.output_tokens) {
            (None, None) => None,
            (input, output) => Some(input.unwrap_or(0) + output.unwrap_or(0)),
        }
    }
}
