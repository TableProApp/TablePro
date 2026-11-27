use tablepro_ai::{Action, ChatMessage, ChatRequest, StopReason};
use tablepro_core::AiProvider;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AiProviderTag {
    Anthropic,
    OpenAi,
    // Ollama, and any other server that speaks OpenAI's Chat Completions.
    OpenAiCompatible,
}

impl From<AiProviderTag> for AiProvider {
    fn from(tag: AiProviderTag) -> Self {
        match tag {
            AiProviderTag::Anthropic => Self::Anthropic,
            AiProviderTag::OpenAi => Self::OpenAi,
            AiProviderTag::OpenAiCompatible => Self::OpenAiCompatible,
        }
    }
}

impl From<AiProvider> for AiProviderTag {
    fn from(provider: AiProvider) -> Self {
        match provider {
            AiProvider::Anthropic => Self::Anthropic,
            AiProvider::OpenAi => Self::OpenAi,
            AiProvider::OpenAiCompatible => Self::OpenAiCompatible,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiProviderInfo {
    pub provider: AiProviderTag,
    // The address requests go to, version path included.
    pub default_base_url: String,
    pub requires_key: bool,
    // Only the compatible server's address is the user's to change.
    pub takes_address: bool,
}

// A model a settings page offers: the provider's list merged with TablePro's catalog (core ADR 0049).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiModelInfo {
    pub id: String,
    // None when neither the provider nor the catalog names it.
    pub name: Option<String>,
    pub deprecated: bool,
    pub is_default: bool,
    // From the catalog only, because the provider's own list was not read.
    pub offline: bool,
}

impl From<tablepro_ai::ModelInfo> for AiModelInfo {
    fn from(model: tablepro_ai::ModelInfo) -> Self {
        Self {
            id: model.id,
            name: model.name,
            deprecated: model.deprecated,
            is_default: model.default,
            offline: model.offline,
        }
    }
}

// What the settings name. `address` is read for the compatible server only; None there is its default.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiSettingsArg {
    pub provider: AiProviderTag,
    pub model: String,
    pub address: Option<String>,
}

impl AiSettingsArg {
    pub(crate) fn base_url(&self) -> String {
        let provider = AiProvider::from(self.provider);
        match (provider, self.address.as_deref().map(str::trim)) {
            (AiProvider::OpenAiCompatible, Some(address)) if !address.is_empty() => address.to_owned(),
            _ => provider.default_base_url().to_owned(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiActionTag {
    Explain,
    Review,
    Optimize,
    // Correct a statement the server refused, with its error.
    Fix,
}

impl From<AiActionTag> for Action {
    fn from(tag: AiActionTag) -> Self {
        match tag {
            AiActionTag::Explain => Self::Explain,
            AiActionTag::Review => Self::Review,
            AiActionTag::Optimize => Self::Optimize,
            AiActionTag::Fix => Self::Fix,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiRoleTag {
    User,
    Assistant,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiMessageArg {
    pub role: AiRoleTag,
    pub text: String,
}

// One turn's request: the system prompt the conversation started with, and every message so far.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiChatArg {
    pub system: String,
    pub messages: Vec<AiMessageArg>,
}

impl From<AiChatArg> for ChatRequest {
    fn from(chat: AiChatArg) -> Self {
        Self {
            system: chat.system,
            messages: chat
                .messages
                .into_iter()
                .map(|message| match message.role {
                    AiRoleTag::User => ChatMessage::user(message.text),
                    AiRoleTag::Assistant => ChatMessage::assistant(message.text),
                })
                .collect(),
            max_tokens: ChatRequest::CHAT_MAX_TOKENS,
            // Phase 1a: the FFI text-chat path offers no tools yet.
            tools: Vec::new(),
        }
    }
}

// `asked` is the question or the statement, whose table names pick the structure sent; `editor` is the editor's
// text for a typed question. `database` is the one the editor runs in, None for the connection's.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiConversationArg {
    // The engine as the user knows it, such as PostgreSQL.
    pub engine: String,
    pub asked: String,
    pub editor: Option<String>,
    pub database: Option<String>,
}

// The system prompt a conversation keeps, and the tables whose structure it carries.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiConversationStart {
    pub system: String,
    pub described: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiStopTag {
    Complete,
    // The reply reached the token limit and stops mid-way.
    LengthLimit,
    // The model declined to answer.
    Refused,
}

impl From<StopReason> for AiStopTag {
    fn from(stop: StopReason) -> Self {
        match stop {
            StopReason::Complete => Self::Complete,
            StopReason::LengthLimit => Self::LengthLimit,
            StopReason::Refused => Self::Refused,
            // Text chat offers no tools, so the model never stops for one;
            // treat it as a normal end rather than widen the FFI enum.
            StopReason::ToolUse => Self::Complete,
        }
    }
}

// The fields of an `ai.*` error: the host it is about, an HTTP status, the provider whose key is missing.
// `detail` is the transport's or parser's English, shown after the app's own sentence.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct AiFailureInfo {
    pub host: Option<String>,
    pub status: Option<u16>,
    pub provider: Option<AiProviderTag>,
    pub detail: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_compatible_server_takes_an_address() {
        let hosted = AiSettingsArg {
            provider: AiProviderTag::Anthropic,
            model: String::new(),
            address: Some("http://elsewhere.example/v1".to_owned()),
        };
        let compatible = AiSettingsArg {
            provider: AiProviderTag::OpenAiCompatible,
            model: String::new(),
            address: Some(" http://gpu-box:11434/v1 ".to_owned()),
        };
        let blank = AiSettingsArg {
            address: Some("  ".to_owned()),
            ..compatible.clone()
        };

        assert_eq!(hosted.base_url(), "https://api.anthropic.com/v1");
        assert_eq!(compatible.base_url(), "http://gpu-box:11434/v1");
        assert_eq!(blank.base_url(), "http://localhost:11434/v1");
    }

    #[test]
    fn a_chat_keeps_its_turns_in_order_with_the_chat_limit() {
        let request = ChatRequest::from(AiChatArg {
            system: "system".to_owned(),
            messages: vec![
                AiMessageArg {
                    role: AiRoleTag::User,
                    text: "first".to_owned(),
                },
                AiMessageArg {
                    role: AiRoleTag::Assistant,
                    text: "one".to_owned(),
                },
            ],
        });

        assert_eq!(request.system, "system");
        assert_eq!(
            request.messages,
            [ChatMessage::user("first"), ChatMessage::assistant("one")]
        );
        assert_eq!(request.max_tokens, ChatRequest::CHAT_MAX_TOKENS);
    }
}
