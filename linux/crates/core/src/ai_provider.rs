/// Who answers the AI assistant. Ollama, and any other server that
/// speaks OpenAI's Chat Completions protocol, is `OpenAiCompatible`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AiProvider {
    Anthropic,
    OpenAi,
    OpenAiCompatible,
}

impl AiProvider {
    pub const ALL: [AiProvider; 3] = [Self::Anthropic, Self::OpenAi, Self::OpenAiCompatible];

    /// The stored spelling, in the keyring and the settings, so it is
    /// never renamed.
    pub fn id(self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic",
            Self::OpenAi => "openai",
            Self::OpenAiCompatible => "openai-compatible",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|provider| provider.id() == id)
    }

    /// The address requests go to, version path included. Only the
    /// compatible server's is the user's to change.
    pub fn default_base_url(self) -> &'static str {
        match self {
            Self::Anthropic => "https://api.anthropic.com/v1",
            Self::OpenAi => "https://api.openai.com/v1",
            Self::OpenAiCompatible => "http://localhost:11434/v1",
        }
    }

    /// A server on the user's own machine usually checks no key.
    pub fn requires_key(self) -> bool {
        !matches!(self, Self::OpenAiCompatible)
    }
}

impl std::fmt::Display for AiProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.id())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_provider_reads_back_from_its_id() {
        for provider in AiProvider::ALL {
            assert_eq!(AiProvider::from_id(provider.id()), Some(provider));
        }
        assert_eq!(AiProvider::from_id("ollama"), None);
        assert_eq!(AiProvider::from_id("none"), None);
    }

    #[test]
    fn the_hosted_providers_need_a_key_and_https() {
        assert!(AiProvider::Anthropic.requires_key());
        assert!(AiProvider::OpenAi.requires_key());
        assert!(!AiProvider::OpenAiCompatible.requires_key());
        assert!(AiProvider::Anthropic.default_base_url().starts_with("https://"));
        assert!(AiProvider::OpenAi.default_base_url().starts_with("https://"));
    }
}
