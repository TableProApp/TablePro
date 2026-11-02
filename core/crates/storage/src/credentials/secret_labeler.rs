use tablepro_core::AiProvider;
use tablepro_core::credentials::{SecretItem, SecretKind};

/// Turns a secret's target into the label the keyring shows for it.
///
/// A plain function so the app can pass its translated wording without
/// this crate knowing about gettext.
pub type SecretLabeler = fn(SecretKind, &str) -> String;

/// The label of a secret that belongs to no connection, passed the same
/// way as `SecretLabeler`.
pub type SecretItemLabeler = fn(SecretItem) -> String;

/// The untranslated label, for callers that have no catalog.
pub fn english_secret_label(kind: SecretKind, target: &str) -> String {
    match kind {
        SecretKind::DatabasePassword => format!("TablePro database password for {target}"),
        SecretKind::SshPassword => format!("TablePro SSH password for {target}"),
        SecretKind::SshPassphrase => format!("TablePro SSH key passphrase for {target}"),
    }
}

/// The untranslated label of an item, for callers that have no catalog.
pub fn english_item_label(item: SecretItem) -> String {
    match item {
        SecretItem::McpToken => "TablePro MCP access token".to_owned(),
        SecretItem::AiKey(provider) => {
            let name = match provider {
                AiProvider::Anthropic => "Anthropic",
                AiProvider::OpenAi => "OpenAI",
                AiProvider::OpenAiCompatible => "an OpenAI-compatible server",
            };
            format!("TablePro API key for {name}")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_untranslated_item_labels_are_the_ones_the_keyring_already_holds() {
        assert_eq!(english_item_label(SecretItem::McpToken), "TablePro MCP access token");
        assert_eq!(
            english_item_label(SecretItem::AiKey(AiProvider::Anthropic)),
            "TablePro API key for Anthropic"
        );
        assert_eq!(
            english_item_label(SecretItem::AiKey(AiProvider::OpenAi)),
            "TablePro API key for OpenAI"
        );
        assert_eq!(
            english_item_label(SecretItem::AiKey(AiProvider::OpenAiCompatible)),
            "TablePro API key for an OpenAI-compatible server"
        );
    }
}
