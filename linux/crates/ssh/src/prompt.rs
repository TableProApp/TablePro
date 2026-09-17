use std::path::PathBuf;

use tablepro_core::credentials::{CredentialPrompt, PromptField, PromptPurpose, PromptReason};

const HOST_KEY_OPENING: &str = "The authenticity of host '";
/// OpenSSH 10 writes "ED25519 key fingerprint is: SHA256:…" while 9.x
/// writes "ED25519 key fingerprint is SHA256:…." Matching up to the
/// word reads both, and the colon and the closing period come off
/// with the surrounding space.
const HOST_KEY_FINGERPRINT: &str = " key fingerprint is";
const HOST_KEY_QUESTION: &str = "(yes/no/[fingerprint])? ";
const PASSPHRASE_OPENING: &str = "Enter passphrase for key '";
const PASSWORD_ENDING: &str = "'s password: ";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AskpassPrompt {
    HostKeyConfirmation {
        host: String,
        algorithm: String,
        fingerprint: String,
    },
    Confirmation {
        text: String,
    },
    Notification {
        text: String,
    },
    Passphrase {
        key_path: String,
    },
    Password {
        user_host: String,
    },
    KeyboardInteractive {
        text: String,
    },
    Other {
        text: String,
    },
}

impl AskpassPrompt {
    pub fn classify(hint: &str, text: &str) -> Self {
        if let Some(host_key) = host_key_confirmation(text) {
            return host_key;
        }
        match hint {
            "none" => Self::Notification { text: text.to_owned() },
            "confirm" => Self::Confirmation { text: text.to_owned() },
            _ => secret_prompt(text),
        }
    }

    pub fn credential_prompt(&self, target: &str, reason: PromptReason) -> Option<CredentialPrompt> {
        let secret_field = |label: &str| {
            vec![PromptField {
                label: label.to_owned(),
                secret: true,
            }]
        };
        let (purpose, fields, offer_remember) = match self {
            Self::Notification { .. } => return None,
            Self::HostKeyConfirmation {
                host,
                algorithm,
                fingerprint,
            } => (
                PromptPurpose::SshHostKeyConfirmation {
                    host: host.clone(),
                    algorithm: algorithm.clone(),
                    fingerprint: fingerprint.clone(),
                },
                Vec::new(),
                false,
            ),
            Self::Confirmation { text } => (PromptPurpose::SshConfirmation { text: text.clone() }, Vec::new(), false),
            Self::Passphrase { key_path } => (
                PromptPurpose::SshPassphrase {
                    path: PathBuf::from(key_path),
                    reason,
                },
                secret_field("Passphrase"),
                true,
            ),
            Self::Password { .. } => (PromptPurpose::SshPassword { reason }, secret_field("Password"), true),
            Self::KeyboardInteractive { text } | Self::Other { text } => (
                PromptPurpose::SshKeyboardInteractive {
                    name: String::new(),
                    instructions: text.clone(),
                },
                secret_field(text.trim()),
                false,
            ),
        };
        Some(CredentialPrompt {
            purpose,
            target: target.to_owned(),
            fields,
            offer_remember,
        })
    }
}

fn host_key_confirmation(text: &str) -> Option<AskpassPrompt> {
    if !text.starts_with(HOST_KEY_OPENING) || !text.trim_end().ends_with(HOST_KEY_QUESTION.trim_end()) {
        return None;
    }
    let quoted = text.get(HOST_KEY_OPENING.len()..)?.split_once('\'')?.0;
    let host = quoted.split_once(" (").map_or(quoted, |(host, _)| host);
    let (algorithm, fingerprint) = text.lines().find_map(|line| {
        let (algorithm, rest) = line.split_once(HOST_KEY_FINGERPRINT)?;
        let fingerprint = rest.trim_start_matches(':').trim().trim_end_matches('.');
        Some((algorithm.trim(), fingerprint))
    })?;
    Some(AskpassPrompt::HostKeyConfirmation {
        host: host.to_owned(),
        algorithm: algorithm.to_owned(),
        fingerprint: fingerprint.to_owned(),
    })
}

fn secret_prompt(text: &str) -> AskpassPrompt {
    if let Some(key_path) = text
        .strip_prefix(PASSPHRASE_OPENING)
        .and_then(|rest| rest.strip_suffix("': "))
    {
        return AskpassPrompt::Passphrase {
            key_path: key_path.to_owned(),
        };
    }
    if let Some(user_host) = text.strip_suffix(PASSWORD_ENDING) {
        return AskpassPrompt::Password {
            user_host: user_host.to_owned(),
        };
    }
    if text.starts_with('(') && text.contains(") ") {
        return AskpassPrompt::KeyboardInteractive { text: text.to_owned() };
    }
    AskpassPrompt::Other { text: text.to_owned() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn askpass_classify_matches_openssh_10_2_strings() {
        let host_key = "The authenticity of host 'bastion (192.0.2.10)' can't be established.\nED25519 key fingerprint is: SHA256:Qa4bFq8b0hN2kL9x\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ";
        assert_eq!(
            AskpassPrompt::classify("", host_key),
            AskpassPrompt::HostKeyConfirmation {
                host: "bastion".to_owned(),
                algorithm: "ED25519".to_owned(),
                fingerprint: "SHA256:Qa4bFq8b0hN2kL9x".to_owned(),
            }
        );
        assert_eq!(
            AskpassPrompt::classify("", "deploy@bastion's password: "),
            AskpassPrompt::Password {
                user_host: "deploy@bastion".to_owned()
            }
        );
        assert_eq!(
            AskpassPrompt::classify("", "Enter passphrase for key '/home/deploy/.ssh/id_ed25519': "),
            AskpassPrompt::Passphrase {
                key_path: "/home/deploy/.ssh/id_ed25519".to_owned()
            }
        );
        assert_eq!(
            AskpassPrompt::classify("", "(deploy@bastion) Verification code: "),
            AskpassPrompt::KeyboardInteractive {
                text: "(deploy@bastion) Verification code: ".to_owned()
            }
        );
        assert_eq!(
            AskpassPrompt::classify("none", "Confirm user presence for key ED25519-SK"),
            AskpassPrompt::Notification {
                text: "Confirm user presence for key ED25519-SK".to_owned()
            }
        );
        assert_eq!(
            AskpassPrompt::classify("confirm", "Allow use of key id_ed25519?"),
            AskpassPrompt::Confirmation {
                text: "Allow use of key id_ed25519?".to_owned()
            }
        );
        assert_eq!(
            AskpassPrompt::classify("", "PIN: "),
            AskpassPrompt::Other {
                text: "PIN: ".to_owned()
            }
        );
    }

    /// Ubuntu 24.04 ships OpenSSH 9.6, which writes the fingerprint
    /// line without the colon and with a closing period. It is what the
    /// CI runner has, so the parser has to read it too.
    #[test]
    fn askpass_classify_matches_openssh_9_6_strings() {
        let host_key = "The authenticity of host 'bastion (192.0.2.10)' can't be established.\nED25519 key fingerprint is SHA256:Qa4bFq8b0hN2kL9x.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ";

        assert_eq!(
            AskpassPrompt::classify("", host_key),
            AskpassPrompt::HostKeyConfirmation {
                host: "bastion".to_owned(),
                algorithm: "ED25519".to_owned(),
                fingerprint: "SHA256:Qa4bFq8b0hN2kL9x".to_owned(),
            }
        );
    }

    /// OpenSSH keeps a second, older question without the
    /// `[fingerprint]` arm, which it asks for things that are not host
    /// keys. Answering it as though it were one would say yes to a
    /// question nobody read.
    #[test]
    fn a_question_without_the_fingerprint_arm_is_not_a_host_key_prompt() {
        let host_key = "The authenticity of host 'bastion (192.0.2.10)' can't be established.\nED25519 key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no)? ";

        assert!(!matches!(
            AskpassPrompt::classify("", host_key),
            AskpassPrompt::HostKeyConfirmation { .. }
        ));
    }

    #[test]
    fn prompts_map_to_credential_prompts() {
        let password = AskpassPrompt::Password {
            user_host: "deploy@bastion".to_owned(),
        };
        let prompt = password
            .credential_prompt("deploy@bastion", PromptReason::NotStored)
            .unwrap();
        assert_eq!(
            prompt.purpose,
            PromptPurpose::SshPassword {
                reason: PromptReason::NotStored
            }
        );
        assert_eq!(prompt.fields.len(), 1);
        assert!(prompt.offer_remember);

        let other = AskpassPrompt::Other {
            text: "PIN: ".to_owned(),
        };
        let prompt = other.credential_prompt("bastion", PromptReason::NotStored).unwrap();
        assert_eq!(prompt.fields[0].label, "PIN:");
        assert!(prompt.fields[0].secret);

        let notification = AskpassPrompt::Notification {
            text: "touch".to_owned(),
        };
        assert_eq!(notification.credential_prompt("bastion", PromptReason::NotStored), None);
    }
}
