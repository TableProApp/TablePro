use std::sync::Arc;

use futures::future::BoxFuture;
use secrecy::SecretString;
use tablepro_core::credentials::{CredentialPrompt, CredentialPrompter, PromptPurpose, PromptReason, PromptReply};
use tablepro_session::runtime::Tasks;

use crate::library::Redacted;

// The app asks the user and returns the answer; the core calls it on a thread it lets block.
#[uniffi::export(callback_interface)]
pub trait HostPrompter: Send + Sync {
    fn prompt(&self, prompt: PromptRequest) -> PromptAnswer;
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PromptRequest {
    pub purpose: PromptPurposeTag,
    // What the question is about, such as user@host, for the dialog's text.
    pub target: String,
    pub fields: Vec<PromptFieldInfo>,
    pub offer_remember: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PromptPurposeTag {
    DatabasePassword {
        reason: PromptReasonTag,
    },
    SshPassword {
        reason: PromptReasonTag,
    },
    SshPassphrase {
        path: String,
        reason: PromptReasonTag,
    },
    SshKeyboardInteractive {
        name: String,
        instructions: String,
    },
    SshHostKey {
        host: String,
        algorithm: String,
        fingerprint: String,
    },
    SshConfirmation {
        text: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PromptReasonTag {
    NotStored,
    KeyringLocked,
    KeyringUnavailable { detail: String },
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PromptFieldInfo {
    pub label: String,
    pub secret: bool,
}

#[derive(Clone, uniffi::Enum)]
pub enum PromptAnswer {
    // One value per field; a host key or a confirmation is trusted with none.
    Submitted { values: Vec<SecretString>, remember: bool },
    Cancelled,
}

impl std::fmt::Debug for PromptAnswer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Submitted { values, remember } => f
                .debug_struct("Submitted")
                .field("values", &values.iter().map(|_| Redacted).collect::<Vec<_>>())
                .field("remember", remember)
                .finish(),
            Self::Cancelled => f.write_str("Cancelled"),
        }
    }
}

pub(crate) struct HostPrompterBridge {
    host: Arc<dyn HostPrompter>,
    tasks: Tasks,
}

impl HostPrompterBridge {
    pub(crate) fn new(host: Box<dyn HostPrompter>, tasks: Tasks) -> Self {
        Self {
            host: Arc::from(host),
            tasks,
        }
    }
}

impl std::fmt::Debug for HostPrompterBridge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HostPrompterBridge").finish_non_exhaustive()
    }
}

impl CredentialPrompter for HostPrompterBridge {
    fn prompt(&self, request: CredentialPrompt) -> BoxFuture<'static, PromptReply> {
        let host = self.host.clone();
        let tasks = self.tasks.clone();
        Box::pin(async move {
            let request = PromptRequest::from(request);
            match tasks.spawn_blocking_task(move || host.prompt(request)).await {
                Ok(answer) => answer.into(),
                Err(failure) => {
                    tracing::warn!(%failure, "the app's prompt failed, so it counts as cancelled");
                    PromptReply::Cancelled
                }
            }
        })
    }
}

impl From<CredentialPrompt> for PromptRequest {
    fn from(prompt: CredentialPrompt) -> Self {
        Self {
            purpose: prompt.purpose.into(),
            target: prompt.target,
            fields: prompt
                .fields
                .into_iter()
                .map(|field| PromptFieldInfo {
                    label: field.label,
                    secret: field.secret,
                })
                .collect(),
            offer_remember: prompt.offer_remember,
        }
    }
}

impl From<PromptPurpose> for PromptPurposeTag {
    fn from(purpose: PromptPurpose) -> Self {
        match purpose {
            PromptPurpose::DatabasePassword { reason } => Self::DatabasePassword { reason: reason.into() },
            PromptPurpose::SshPassword { reason } => Self::SshPassword { reason: reason.into() },
            PromptPurpose::SshPassphrase { path, reason } => Self::SshPassphrase {
                path: path.display().to_string(),
                reason: reason.into(),
            },
            PromptPurpose::SshKeyboardInteractive { name, instructions } => {
                Self::SshKeyboardInteractive { name, instructions }
            }
            PromptPurpose::SshHostKeyConfirmation {
                host,
                algorithm,
                fingerprint,
            } => Self::SshHostKey {
                host,
                algorithm,
                fingerprint,
            },
            PromptPurpose::SshConfirmation { text } => Self::SshConfirmation { text },
        }
    }
}

impl From<PromptReason> for PromptReasonTag {
    fn from(reason: PromptReason) -> Self {
        match reason {
            PromptReason::NotStored => Self::NotStored,
            PromptReason::KeyringLocked => Self::KeyringLocked,
            PromptReason::KeyringUnavailable { detail } => Self::KeyringUnavailable { detail },
            PromptReason::Rejected => Self::Rejected,
        }
    }
}

impl From<PromptAnswer> for PromptReply {
    fn from(answer: PromptAnswer) -> Self {
        match answer {
            PromptAnswer::Submitted { values, remember } => Self::Submitted { values, remember },
            PromptAnswer::Cancelled => Self::Cancelled,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::Mutex;

    use secrecy::ExposeSecret;
    use tablepro_core::credentials::PromptField;

    use super::*;
    use crate::runtime;

    struct Answering {
        asked: Arc<Mutex<Vec<PromptRequest>>>,
        answer: PromptAnswer,
    }

    impl HostPrompter for Answering {
        fn prompt(&self, prompt: PromptRequest) -> PromptAnswer {
            self.asked.lock().unwrap().push(prompt);
            self.answer.clone()
        }
    }

    struct Failing;

    impl HostPrompter for Failing {
        fn prompt(&self, _: PromptRequest) -> PromptAnswer {
            panic!("the app's callback threw");
        }
    }

    fn bridge(host: impl HostPrompter + 'static) -> HostPrompterBridge {
        HostPrompterBridge::new(Box::new(host), runtime::tasks().unwrap())
    }

    fn passphrase() -> CredentialPrompt {
        CredentialPrompt {
            purpose: PromptPurpose::SshPassphrase {
                path: PathBuf::from("/keys/id_ed25519"),
                reason: PromptReason::Rejected,
            },
            target: "deploy@bastion".to_owned(),
            fields: vec![PromptField {
                label: "Passphrase".to_owned(),
                secret: true,
            }],
            offer_remember: false,
        }
    }

    #[tokio::test]
    async fn the_app_sees_the_question_and_its_answer_comes_back() {
        let asked = Arc::new(Mutex::new(Vec::new()));
        let prompter = bridge(Answering {
            asked: asked.clone(),
            answer: PromptAnswer::Submitted {
                values: vec![SecretString::from("correct horse")],
                remember: true,
            },
        });

        let reply = prompter.prompt(passphrase()).await;

        let PromptReply::Submitted { values, remember } = reply else {
            panic!("cancelled")
        };
        assert_eq!(
            values.iter().map(|value| value.expose_secret()).collect::<Vec<_>>(),
            ["correct horse"]
        );
        assert!(remember);
        assert_eq!(
            *asked.lock().unwrap(),
            [PromptRequest {
                purpose: PromptPurposeTag::SshPassphrase {
                    path: PathBuf::from("/keys/id_ed25519").display().to_string(),
                    reason: PromptReasonTag::Rejected,
                },
                target: "deploy@bastion".to_owned(),
                fields: vec![PromptFieldInfo {
                    label: "Passphrase".to_owned(),
                    secret: true,
                }],
                offer_remember: false,
            }]
        );
    }

    #[test]
    fn debug_output_of_an_answer_holds_no_typed_value() {
        let answer = PromptAnswer::Submitted {
            values: vec![SecretString::from("correct horse")],
            remember: true,
        };

        assert_eq!(
            format!("{answer:?}"),
            "Submitted { values: [[REDACTED]], remember: true }"
        );
    }

    #[tokio::test]
    async fn a_callback_that_fails_counts_as_cancelled() {
        let reply = bridge(Failing).prompt(passphrase()).await;

        assert!(matches!(reply, PromptReply::Cancelled));
    }
}
