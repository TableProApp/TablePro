#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
}

impl Role {
    pub(crate) fn wire_name(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatMessage {
    pub role: Role,
    pub text: String,
}

impl ChatMessage {
    pub fn user(text: impl Into<String>) -> Self {
        Self {
            role: Role::User,
            text: text.into(),
        }
    }

    pub fn assistant(text: impl Into<String>) -> Self {
        Self {
            role: Role::Assistant,
            text: text.into(),
        }
    }
}

/// One turn's request. The system prompt is fixed when a conversation
/// starts and sent unchanged with every turn after it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatRequest {
    pub system: String,
    pub messages: Vec<ChatMessage>,
    /// The longest reply asked for. Anthropic needs one; the Chat
    /// Completions request leaves the server's own limit in place.
    pub max_tokens: u32,
}

impl ChatRequest {
    /// Room for a long answer, with the thinking a current model does
    /// before it.
    pub const CHAT_MAX_TOKENS: u32 = 64_000;
    /// A suggestion is a line or a few, but a model may think first.
    pub const SUGGESTION_MAX_TOKENS: u32 = 8_000;
}
