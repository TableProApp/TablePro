use async_trait::async_trait;
use secrecy::SecretString;

const HOST_KEY_OPENING: &str = "The authenticity of host '";
const HOST_KEY_FINGERPRINT: &str = " key fingerprint is";
const HOST_KEY_QUESTION: &str = "(yes/no/[fingerprint])?";
const PASSPHRASE_OPENING: &str = "Enter passphrase for key '";
const PASSPHRASE_ENDING: &str = "': ";
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

    pub fn is_confirmation(&self) -> bool {
        matches!(self, Self::HostKeyConfirmation { .. } | Self::Confirmation { .. })
    }
}

#[derive(Debug)]
pub enum PromptAnswer {
    Accept,
    Secret(SecretString),
    Decline,
}

#[async_trait]
pub trait Prompter: Send + Sync {
    async fn answer(&self, prompt: &AskpassPrompt) -> PromptAnswer;

    fn notify(&self, _text: &str) {}
}

#[derive(Debug, Clone, Copy, Default)]
pub struct UnattendedPrompter;

#[async_trait]
impl Prompter for UnattendedPrompter {
    async fn answer(&self, _prompt: &AskpassPrompt) -> PromptAnswer {
        PromptAnswer::Decline
    }
}

fn host_key_confirmation(text: &str) -> Option<AskpassPrompt> {
    if !text.starts_with(HOST_KEY_OPENING) || !text.trim_end().ends_with(HOST_KEY_QUESTION) {
        return None;
    }
    let quoted = text.get(HOST_KEY_OPENING.len()..)?.split_once('\'')?.0;
    let host = quoted.split_once(" (").map_or(quoted, |(host, _)| host);
    let (algorithm, fingerprint) = text.lines().find_map(fingerprint_line)?;
    Some(AskpassPrompt::HostKeyConfirmation {
        host: host.to_owned(),
        algorithm: algorithm.to_owned(),
        fingerprint: fingerprint.to_owned(),
    })
}

// OpenSSH 10 writes "ED25519 key fingerprint is: SHA256:..." and 9.x writes
// "ED25519 key fingerprint is SHA256:...." with no colon and a closing period.
fn fingerprint_line(line: &str) -> Option<(&str, &str)> {
    let (algorithm, rest) = line.split_once(HOST_KEY_FINGERPRINT)?;
    let fingerprint = rest.trim_start_matches(':').trim().trim_end_matches('.');
    Some((algorithm.trim(), fingerprint))
}

fn secret_prompt(text: &str) -> AskpassPrompt {
    if let Some(key_path) = text
        .strip_prefix(PASSPHRASE_OPENING)
        .and_then(|rest| rest.strip_suffix(PASSPHRASE_ENDING))
    {
        return AskpassPrompt::Passphrase {
            key_path: key_path.to_owned(),
        };
    }
    if text.starts_with('(') && text.contains(") ") {
        return AskpassPrompt::KeyboardInteractive { text: text.to_owned() };
    }
    if let Some(user_host) = text.strip_suffix(PASSWORD_ENDING) {
        return AskpassPrompt::Password {
            user_host: user_host.to_owned(),
        };
    }
    AskpassPrompt::Other { text: text.to_owned() }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST_KEY_10: &str = "The authenticity of host 'bastion (192.0.2.10)' can't be established.\nED25519 key fingerprint is: SHA256:Qa4bFq8b0hN2kL9x\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ";
    const HOST_KEY_9_6: &str = "The authenticity of host 'bastion (192.0.2.10)' can't be established.\nED25519 key fingerprint is SHA256:Qa4bFq8b0hN2kL9x.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ";

    fn bastion_key() -> AskpassPrompt {
        AskpassPrompt::HostKeyConfirmation {
            host: "bastion".to_owned(),
            algorithm: "ED25519".to_owned(),
            fingerprint: "SHA256:Qa4bFq8b0hN2kL9x".to_owned(),
        }
    }

    #[test]
    fn host_key_prompts_from_openssh_10_and_9_6_read_the_same() {
        assert_eq!(AskpassPrompt::classify("", HOST_KEY_10), bastion_key());
        assert_eq!(AskpassPrompt::classify("confirm", HOST_KEY_9_6), bastion_key());
    }

    #[test]
    fn a_question_without_the_fingerprint_arm_is_not_a_host_key_prompt() {
        let older = HOST_KEY_9_6.replace("(yes/no/[fingerprint])", "(yes/no)");
        assert!(!matches!(
            AskpassPrompt::classify("", &older),
            AskpassPrompt::HostKeyConfirmation { .. }
        ));
    }

    #[test]
    fn secret_prompts_are_told_apart() {
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
            AskpassPrompt::classify("", "PIN: "),
            AskpassPrompt::Other {
                text: "PIN: ".to_owned()
            }
        );
    }

    #[test]
    fn a_server_supplied_keyboard_interactive_prompt_cannot_pose_as_a_password_prompt() {
        let spoof = "(ops@jump1) deploy@bastion's password: ";
        assert_eq!(
            AskpassPrompt::classify("", spoof),
            AskpassPrompt::KeyboardInteractive { text: spoof.to_owned() }
        );
    }

    #[test]
    fn notifications_and_confirmations_follow_the_hint() {
        assert_eq!(
            AskpassPrompt::classify("none", "Confirm user presence for key ED25519-SK SHA256:abc"),
            AskpassPrompt::Notification {
                text: "Confirm user presence for key ED25519-SK SHA256:abc".to_owned()
            }
        );
        let confirm = AskpassPrompt::classify("confirm", "Allow use of key id_ed25519?");
        assert!(confirm.is_confirmation());
        assert!(bastion_key().is_confirmation());
        assert!(!AskpassPrompt::classify("", "PIN: ").is_confirmation());
    }

    #[tokio::test]
    async fn the_unattended_prompter_declines_everything() {
        for prompt in [
            bastion_key(),
            AskpassPrompt::classify("", "deploy@bastion's password: "),
        ] {
            assert!(matches!(
                UnattendedPrompter.answer(&prompt).await,
                PromptAnswer::Decline
            ));
        }
    }
}
