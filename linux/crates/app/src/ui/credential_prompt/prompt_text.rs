use tablepro_core::credentials::{CredentialPrompt, PromptPurpose, PromptReason};

/// What a prompt dialog says, worked out before any widget exists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct PromptText {
    pub heading: String,
    pub body: String,
    /// The label of the button that answers the prompt.
    pub accept: String,
    pub remember: String,
}

impl PromptText {
    pub fn for_prompt(prompt: &CredentialPrompt) -> Self {
        let target = prompt.target.as_str();
        let (heading, body, accept) = match &prompt.purpose {
            PromptPurpose::DatabasePassword { reason } => (
                crate::i18n::gettext("Password Required"),
                with_reason(
                    crate::i18n::gettext_f("Enter the database password for {target}.", &[("target", target)]),
                    reason,
                ),
                crate::i18n::gettext("Connect"),
            ),
            PromptPurpose::SshPassword { reason } => (
                crate::i18n::gettext("Password Required"),
                with_reason(
                    crate::i18n::gettext_f("Enter the SSH password for {target}.", &[("target", target)]),
                    reason,
                ),
                crate::i18n::gettext("Connect"),
            ),
            PromptPurpose::SshPassphrase { path, reason } => (
                crate::i18n::gettext("Passphrase Required"),
                with_reason(
                    crate::i18n::gettext_f(
                        "Enter the passphrase for the SSH key {path}.",
                        &[("path", &path.display().to_string())],
                    ),
                    reason,
                ),
                crate::i18n::gettext("Connect"),
            ),
            PromptPurpose::SshKeyboardInteractive { name, instructions } => {
                let heading = match name.trim() {
                    "" => crate::i18n::gettext("Authentication Required"),
                    name => name.to_owned(),
                };
                let body = match instructions.trim() {
                    "" => crate::i18n::gettext_f("The SSH server {target} asks for more.", &[("target", target)]),
                    instructions => instructions.to_owned(),
                };
                (heading, body, crate::i18n::gettext("Continue"))
            }
            PromptPurpose::SshHostKeyConfirmation {
                host,
                algorithm,
                fingerprint,
            } => (
                crate::i18n::gettext_f("Trust {host}?", &[("host", host)]),
                crate::i18n::gettext_f(
                    "This is the first connection to {host}. Its {algorithm} key fingerprint is {fingerprint}. Connect only if it matches the fingerprint the server's administrator gave you.",
                    &[("host", host), ("algorithm", algorithm), ("fingerprint", fingerprint)],
                ),
                crate::i18n::gettext("Trust and Connect"),
            ),
            PromptPurpose::SshConfirmation { text } => (
                crate::i18n::gettext("Authentication Required"),
                text.clone(),
                crate::i18n::gettext("Continue"),
            ),
        };
        let remember = match prompt.purpose {
            PromptPurpose::SshPassphrase { .. } => crate::i18n::gettext("Remember Passphrase"),
            _ => crate::i18n::gettext("Remember Password"),
        };
        Self {
            heading,
            body,
            accept,
            remember,
        }
    }
}

/// Why the user is being asked, which tells them whether something is
/// wrong with the keyring or with what they typed before.
fn with_reason(request: String, reason: &PromptReason) -> String {
    let because = match reason {
        PromptReason::NotStored => crate::i18n::gettext("No password is saved for this connection."),
        PromptReason::KeyringLocked => crate::i18n::gettext("The keyring is locked, so the saved one could not be read."),
        PromptReason::KeyringUnavailable { .. } => {
            crate::i18n::gettext("No keyring is available, so it cannot be read or saved.")
        }
        PromptReason::Rejected => crate::i18n::gettext("The server refused the one it was given."),
    };
    format!("{because} {request}")
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tablepro_core::credentials::PromptField;

    use super::*;

    fn prompt(purpose: PromptPurpose) -> CredentialPrompt {
        CredentialPrompt {
            purpose,
            target: "app@db.example.com:5432/shop".to_owned(),
            fields: vec![PromptField {
                label: "Password".to_owned(),
                secret: true,
            }],
            offer_remember: true,
        }
    }

    #[test]
    fn a_password_prompt_names_its_target_and_its_reason() {
        let text = PromptText::for_prompt(&prompt(PromptPurpose::DatabasePassword {
            reason: PromptReason::Rejected,
        }));

        assert_eq!(text.heading, "Password Required");
        assert!(text.body.contains("app@db.example.com:5432/shop"), "{}", text.body);
        assert!(text.body.contains("refused"), "{}", text.body);
    }

    #[test]
    fn each_reason_reads_differently() {
        let reasons = [
            PromptReason::NotStored,
            PromptReason::KeyringLocked,
            PromptReason::KeyringUnavailable {
                detail: "no service".to_owned(),
            },
            PromptReason::Rejected,
        ];

        let bodies: std::collections::HashSet<String> = reasons
            .into_iter()
            .map(|reason| PromptText::for_prompt(&prompt(PromptPurpose::SshPassword { reason })).body)
            .collect();

        assert_eq!(bodies.len(), 4);
    }

    #[test]
    fn a_passphrase_prompt_names_the_key_file() {
        let text = PromptText::for_prompt(&prompt(PromptPurpose::SshPassphrase {
            path: PathBuf::from("/home/u/.ssh/id_ed25519"),
            reason: PromptReason::NotStored,
        }));

        assert_eq!(text.heading, "Passphrase Required");
        assert!(text.body.contains("/home/u/.ssh/id_ed25519"), "{}", text.body);
    }

    #[test]
    fn a_host_key_prompt_shows_the_fingerprint() {
        let text = PromptText::for_prompt(&prompt(PromptPurpose::SshHostKeyConfirmation {
            host: "bastion.example.com".to_owned(),
            algorithm: "ED25519".to_owned(),
            fingerprint: "SHA256:abc".to_owned(),
        }));

        assert!(text.heading.contains("bastion.example.com"));
        assert!(text.body.contains("SHA256:abc"));
        assert!(text.body.contains("ED25519"));
    }

    #[test]
    fn keyboard_interactive_shows_the_server_s_own_words() {
        let text = PromptText::for_prompt(&prompt(PromptPurpose::SshKeyboardInteractive {
            name: "Duo two-factor login".to_owned(),
            instructions: "Enter a passcode or select one of the following options".to_owned(),
        }));

        assert_eq!(text.heading, "Duo two-factor login");
        assert!(text.body.starts_with("Enter a passcode"));

        let unnamed = PromptText::for_prompt(&prompt(PromptPurpose::SshKeyboardInteractive {
            name: String::new(),
            instructions: String::new(),
        }));
        assert_eq!(unnamed.heading, "Authentication Required");
    }
}
