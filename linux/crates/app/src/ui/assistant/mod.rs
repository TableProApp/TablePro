//! The AI assistant: the pane beside a connection's tabs, what its
//! requests may carry, and the words for what goes wrong.

mod assistant_access;
mod assistant_pane;
mod code_block;
mod conversation;
mod error_text;
#[cfg(test)]
pub(crate) mod fake_provider;
mod markdown;
mod message_view;
mod schema_reader;

pub(crate) use self::assistant_access::{AssistantAccess, Availability};
pub(crate) use self::assistant_pane::{AssistantPane, PaneHooks};
pub(crate) use self::error_text::{reply_error_text, setup_error_text};

use tablepro_ai::Action;
use tablepro_core::AiProvider;

/// What an editor asks the assistant about one statement.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AssistantRequest {
    pub action: Action,
    pub statement: String,
    /// The server's error, for a Fix.
    pub error: Option<String>,
}

/// The provider as the user knows it.
pub(crate) fn provider_name(provider: AiProvider) -> String {
    match provider {
        AiProvider::Anthropic => crate::i18n::gettext("Anthropic"),
        AiProvider::OpenAi => crate::i18n::gettext("OpenAI"),
        AiProvider::OpenAiCompatible => crate::i18n::gettext("Ollama or Compatible Server"),
    }
}

/// The editor's command for `action`, as its menus name it.
pub(crate) fn action_title(action: Action) -> String {
    match action {
        Action::Explain => crate::i18n::gettext("Explain the Statement"),
        Action::Review => crate::i18n::gettext("Review the Statement"),
        Action::Optimize => crate::i18n::gettext("Optimize the Statement"),
        Action::Fix => crate::i18n::gettext("Fix the Statement"),
    }
}
