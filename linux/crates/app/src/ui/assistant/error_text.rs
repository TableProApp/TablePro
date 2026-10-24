use tablepro_ai::AiError;
use tablepro_core::credentials::SecretError;

use crate::services::ai_service::AiSetupError;

pub(crate) fn setup_error_text(error: &AiSetupError) -> String {
    match error {
        AiSetupError::Off => crate::i18n::gettext("Choose a provider in Preferences to use the assistant."),
        AiSetupError::Keyring(error) => keyring_text(error),
        AiSetupError::Ai(error) => reply_error_text(error),
        AiSetupError::Stopped => crate::i18n::gettext("The request stopped before it finished."),
    }
}

pub(crate) fn reply_error_text(error: &AiError) -> String {
    match error {
        AiError::MissingKey(provider) => crate::i18n::gettext_f(
            "Add your {provider} API key in Preferences.",
            &[("provider", &super::provider_name(*provider))],
        ),
        AiError::MissingModel => crate::i18n::gettext("Choose a model in Preferences."),
        AiError::InvalidAddress => {
            crate::i18n::gettext("The server address in Preferences is not an http or https address.")
        }
        AiError::KeyOverPlainHttp => crate::i18n::gettext(
            "An API key goes to another computer over https only. Use an https address, or remove the key.",
        ),
        AiError::InvalidKey => {
            crate::i18n::gettext("The API key holds characters a key cannot have. Enter it again in Preferences.")
        }
        AiError::Tls(detail) => crate::i18n::gettext_f(
            "A secure connection could not be set up: {detail}",
            &[("detail", detail)],
        ),
        AiError::Unreachable { host, detail } => crate::i18n::gettext_f(
            "TablePro could not reach {host}: {detail}",
            &[("host", host), ("detail", detail)],
        ),
        AiError::TimedOut { host } => crate::i18n::gettext_f("{host} did not answer in time.", &[("host", host)]),
        AiError::Unauthorized { host, message } => with_server_words(
            crate::i18n::gettext_f(
                "{host} refused the API key. Check it in Preferences.",
                &[("host", host)],
            ),
            message.as_deref(),
        ),
        AiError::RateLimited { host, message } => with_server_words(
            crate::i18n::gettext_f(
                "{host} is limiting requests. Wait a moment and try again.",
                &[("host", host)],
            ),
            message.as_deref(),
        ),
        AiError::Status { host, status, message } => with_server_words(
            crate::i18n::gettext_f(
                "{host} answered with error {status}.",
                &[("host", host), ("status", &status.to_string())],
            ),
            message.as_deref(),
        ),
        AiError::Provider(message) => {
            crate::i18n::gettext_f("The provider stopped the reply: {message}", &[("message", message)])
        }
        AiError::Protocol(detail) => {
            crate::i18n::gettext_f("The reply could not be read: {detail}", &[("detail", detail)])
        }
        AiError::TooLong => crate::i18n::gettext("The reply grew longer than TablePro keeps, so it stopped."),
    }
}

/// The server's own sentence, after the app's.
fn with_server_words(sentence: String, server: Option<&str>) -> String {
    match server {
        Some(server) => crate::i18n::gettext_f(
            "{sentence} The server said: {message}",
            &[("sentence", &sentence), ("message", server)],
        ),
        None => sentence,
    }
}

/// The API key is the user's own, so the sentences say what the
/// assistant cannot do without it.
fn keyring_text(error: &SecretError) -> String {
    match error {
        SecretError::Locked | SecretError::UnlockDismissed => {
            crate::i18n::gettext("The keyring is locked, so the API key cannot be read. Unlock it and try again.")
        }
        SecretError::ServiceUnavailable { .. } => crate::i18n::gettext(
            "No keyring is running, so the API key cannot be read or kept. Start a keyring and try again.",
        ),
        SecretError::PortalUnavailable { .. } => crate::i18n::gettext(
            "The secret portal is unavailable, so the API key cannot be read or kept. Check that xdg-desktop-portal and a keyring are running.",
        ),
        SecretError::InvalidEncoding => {
            crate::i18n::gettext("The API key kept in the keyring is not readable text. Enter it again in Preferences.")
        }
        SecretError::Backend { service_message, .. } => match service_message {
            Some(message) => crate::i18n::gettext_f("The keyring reported: {detail}", &[("detail", message)]),
            None => crate::i18n::gettext("The keyring failed without giving a reason."),
        },
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use tablepro_core::AiProvider;

    use super::*;

    #[test]
    fn each_failure_has_its_own_sentence() {
        let host = || "api.example.com".to_owned();
        let errors = [
            AiError::MissingKey(AiProvider::Anthropic),
            AiError::MissingModel,
            AiError::InvalidAddress,
            AiError::KeyOverPlainHttp,
            AiError::InvalidKey,
            AiError::Tls("bad".to_owned()),
            AiError::Unreachable {
                host: host(),
                detail: "refused".to_owned(),
            },
            AiError::TimedOut { host: host() },
            AiError::Unauthorized {
                host: host(),
                message: None,
            },
            AiError::RateLimited {
                host: host(),
                message: None,
            },
            AiError::Status {
                host: host(),
                status: 500,
                message: None,
            },
            AiError::Provider("overloaded".to_owned()),
            AiError::Protocol("bad json".to_owned()),
            AiError::TooLong,
        ];
        let texts: HashSet<String> = errors.iter().map(reply_error_text).collect();

        assert_eq!(texts.len(), errors.len());
    }

    #[test]
    fn the_servers_words_follow_the_apps() {
        let text = reply_error_text(&AiError::Status {
            host: "localhost".to_owned(),
            status: 404,
            message: Some("model \"x\" not found".to_owned()),
        });

        assert_eq!(
            text,
            "localhost answered with error 404. The server said: model \"x\" not found"
        );
    }

    #[test]
    fn a_missing_key_names_the_provider() {
        let text = setup_error_text(&AiSetupError::Ai(AiError::MissingKey(AiProvider::OpenAi)));

        assert_eq!(text, "Add your OpenAI API key in Preferences.");
    }
}
