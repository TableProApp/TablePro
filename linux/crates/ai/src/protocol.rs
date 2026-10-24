use tablepro_core::AiProvider;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Protocol {
    AnthropicMessages,
    ChatCompletions,
}

impl Protocol {
    pub(crate) fn of(provider: AiProvider) -> Self {
        match provider {
            AiProvider::Anthropic => Self::AnthropicMessages,
            AiProvider::OpenAi | AiProvider::OpenAiCompatible => Self::ChatCompletions,
        }
    }
}
