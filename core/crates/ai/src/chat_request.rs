use serde_json::Value;

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

/// One piece of a message. A plain chat turn is a single `Text` block; a
/// tool round adds the model's `ToolUse` call and the app's `ToolResult`.
#[derive(Debug, Clone, PartialEq)]
pub enum ContentBlock {
    Text(String),
    ToolUse {
        id: String,
        name: String,
        input: Value,
    },
    ToolResult {
        id: String,
        content: String,
        is_error: bool,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChatMessage {
    pub role: Role,
    pub content: Vec<ContentBlock>,
}

impl ChatMessage {
    pub fn user(text: impl Into<String>) -> Self {
        Self {
            role: Role::User,
            content: vec![ContentBlock::Text(text.into())],
        }
    }

    pub fn assistant(text: impl Into<String>) -> Self {
        Self {
            role: Role::Assistant,
            content: vec![ContentBlock::Text(text.into())],
        }
    }

    /// The message's text, every `Text` block joined. Tool blocks add
    /// nothing, so a tool round reads as empty.
    pub fn text(&self) -> String {
        let mut text = String::new();
        for block in &self.content {
            if let ContentBlock::Text(part) = block {
                text.push_str(part);
            }
        }
        text
    }
}

/// A tool offered to the model: its name, what it does, and the JSON
/// Schema of its input, passed to each provider as the Value it was
/// given.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

/// One turn's request. The system prompt is fixed when a conversation
/// starts and sent unchanged with every turn after it.
#[derive(Debug, Clone, PartialEq)]
pub struct ChatRequest {
    pub system: String,
    pub messages: Vec<ChatMessage>,
    /// The longest reply asked for. Anthropic needs one; the Chat
    /// Completions request leaves the server's own limit in place.
    pub max_tokens: u32,
    /// The tools this turn offers. Empty on a plain chat, which asks for
    /// none and reaches no tool-calling code path.
    pub tools: Vec<ToolSpec>,
}

impl ChatRequest {
    /// Room for a long answer, with the thinking a current model does
    /// before it.
    pub const CHAT_MAX_TOKENS: u32 = 64_000;
    /// A suggestion is a line or a few, but a model may think first.
    pub const SUGGESTION_MAX_TOKENS: u32 = 8_000;
}
