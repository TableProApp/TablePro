use crate::AiError;

/// What a streaming reply sends, in order: text as it arrives, then one
/// `Finished` or `Failed`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReplyEvent {
    Text(String),
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
