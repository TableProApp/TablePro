use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_core::SshFailure;
use tablepro_core::credentials::{
    CredentialInteraction, CredentialPrompt, PromptField, PromptPurpose, PromptReason, PromptReply,
};

use tokio_util::sync::CancellationToken;

use super::clock::PromptClock;

// The questions a login asks the user, each one stopping the handshake clock.
pub(crate) struct Prompts {
    interaction: CredentialInteraction,
    clock: Arc<PromptClock>,
    destination: String,
    // Set once the connect gives up, so a question still open cannot trust a key for it later.
    abort: CancellationToken,
}

impl Prompts {
    pub fn new(
        interaction: CredentialInteraction,
        clock: Arc<PromptClock>,
        destination: String,
        abort: CancellationToken,
    ) -> Self {
        Self {
            interaction,
            clock,
            destination,
            abort,
        }
    }

    async fn ask(&self, request: CredentialPrompt) -> Option<PromptReply> {
        let CredentialInteraction::Attended(prompter) = &self.interaction else {
            return None;
        };
        let _paused = self.clock.pause();
        tokio::select! {
            () = self.abort.cancelled() => Some(PromptReply::Cancelled),
            reply = prompter.prompt(request) => Some(reply),
        }
    }

    // Unattended, or a no, both leave the key untrusted, as the askpass bridge answers ssh.
    pub async fn trust_host_key(&self, host: &str, algorithm: &str, fingerprint: &str) -> bool {
        let request = CredentialPrompt {
            purpose: PromptPurpose::SshHostKeyConfirmation {
                host: host.to_owned(),
                algorithm: algorithm.to_owned(),
                fingerprint: fingerprint.to_owned(),
            },
            target: self.destination.clone(),
            fields: Vec::new(),
            offer_remember: false,
        };
        matches!(self.ask(request).await, Some(PromptReply::Submitted { .. }))
    }

    pub async fn password(&self, user_host: &str, reason: PromptReason) -> Result<Option<SecretString>, SshFailure> {
        self.secret(PromptPurpose::SshPassword { reason }, user_host, "Password")
            .await
    }

    pub async fn passphrase(&self, path: &Path, reason: PromptReason) -> Result<Option<SecretString>, SshFailure> {
        let purpose = PromptPurpose::SshPassphrase {
            path: path.to_owned(),
            reason,
        };
        self.secret(purpose, &self.destination, "Passphrase").await
    }

    // `None` when nobody can be asked; a cancel ends the login.
    async fn secret(
        &self,
        purpose: PromptPurpose,
        target: &str,
        label: &str,
    ) -> Result<Option<SecretString>, SshFailure> {
        let request = CredentialPrompt {
            purpose,
            target: target.to_owned(),
            fields: vec![PromptField {
                label: label.to_owned(),
                secret: true,
            }],
            offer_remember: false,
        };
        match self.ask(request).await {
            None => Ok(None),
            Some(PromptReply::Submitted { values, .. }) => Ok(Some(
                values.into_iter().next().unwrap_or_else(|| SecretString::from("")),
            )),
            Some(PromptReply::Cancelled) => Err(SshFailure::InteractionCancelled),
        }
    }

    pub async fn keyboard_interactive(
        &self,
        target: &str,
        name: &str,
        instructions: &str,
        prompts: &[russh::client::Prompt],
    ) -> Result<Option<Vec<SecretString>>, SshFailure> {
        let request = CredentialPrompt {
            purpose: PromptPurpose::SshKeyboardInteractive {
                name: name.to_owned(),
                instructions: instructions.to_owned(),
            },
            target: target.to_owned(),
            fields: prompts
                .iter()
                .map(|prompt| PromptField {
                    label: prompt.prompt.trim().to_owned(),
                    secret: !prompt.echo,
                })
                .collect(),
            offer_remember: false,
        };
        match self.ask(request).await {
            None => Ok(None),
            Some(PromptReply::Submitted { mut values, .. }) => {
                values.resize_with(prompts.len(), || SecretString::from(""));
                Ok(Some(values))
            }
            Some(PromptReply::Cancelled) => Err(SshFailure::InteractionCancelled),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use secrecy::ExposeSecret;
    use tablepro_test_support::FakePrompter;

    use super::*;

    fn prompts(replies: impl IntoIterator<Item = PromptReply>) -> (Prompts, Arc<FakePrompter>) {
        let prompter = Arc::new(FakePrompter::new(replies));
        let clock = Arc::new(PromptClock::new(Duration::from_secs(20)));
        let prompts = Prompts::new(
            CredentialInteraction::Attended(prompter.clone()),
            clock,
            "deploy@db.internal".to_owned(),
            CancellationToken::new(),
        );
        (prompts, prompter)
    }

    fn submitted(values: &[&str]) -> PromptReply {
        PromptReply::Submitted {
            values: values.iter().map(|value| SecretString::from(*value)).collect(),
            remember: false,
        }
    }

    #[tokio::test]
    async fn each_question_asks_with_the_purpose_ssh_would_and_never_offers_to_remember() {
        let (prompts, prompter) = prompts([PromptReply::Cancelled, submitted(&["s3cret"]), submitted(&[])]);

        assert!(
            !prompts
                .trust_host_key("[db.internal]:2222", "ED25519", "SHA256:abc")
                .await
        );
        let password = prompts.password("ops@jump1", PromptReason::Rejected).await.unwrap();
        assert!(prompts.trust_host_key("jump1", "ECDSA", "SHA256:def").await);

        assert_eq!(password.unwrap().expose_secret(), "s3cret");
        let requests = prompter.requests();
        assert_eq!(
            requests[0].purpose,
            PromptPurpose::SshHostKeyConfirmation {
                host: "[db.internal]:2222".to_owned(),
                algorithm: "ED25519".to_owned(),
                fingerprint: "SHA256:abc".to_owned(),
            }
        );
        assert_eq!(requests[0].target, "deploy@db.internal");
        assert_eq!(requests[1].target, "ops@jump1", "the host asking, not the destination");
        assert_eq!(
            requests[1].purpose,
            PromptPurpose::SshPassword {
                reason: PromptReason::Rejected
            }
        );
        assert!(requests.iter().all(|request| !request.offer_remember));
    }

    #[tokio::test]
    async fn a_cancelled_secret_ends_the_login_and_unattended_asks_nobody() {
        let (prompts, _) = prompts([PromptReply::Cancelled]);
        let unattended = Prompts::new(
            CredentialInteraction::Unattended,
            Arc::new(PromptClock::new(Duration::from_secs(20))),
            "db".to_owned(),
            CancellationToken::new(),
        );

        assert_eq!(
            prompts
                .passphrase(Path::new("/keys/id_ed25519"), PromptReason::NotStored)
                .await
                .unwrap_err(),
            SshFailure::InteractionCancelled
        );
        assert!(
            unattended
                .password("db", PromptReason::NotStored)
                .await
                .unwrap()
                .is_none()
        );
        assert!(!unattended.trust_host_key("db", "ED25519", "SHA256:abc").await);
    }

    #[tokio::test]
    async fn a_question_open_when_the_connect_gives_up_is_a_no() {
        let prompter = Arc::new(FakePrompter::new([submitted(&[])]).with_delay(Duration::from_secs(60)));
        let abort = CancellationToken::new();
        let prompts = Prompts::new(
            CredentialInteraction::Attended(prompter),
            Arc::new(PromptClock::new(Duration::from_secs(20))),
            "db".to_owned(),
            abort.clone(),
        );

        let asking = prompts.trust_host_key("db", "ED25519", "SHA256:abc");
        tokio::pin!(asking);
        tokio::select! {
            _ = &mut asking => panic!("the prompt answered before the abort"),
            () = tokio::time::sleep(Duration::from_millis(50)) => abort.cancel(),
        }

        assert!(!asking.await);
    }

    #[tokio::test]
    async fn keyboard_interactive_asks_every_prompt_at_once_and_hides_what_the_server_hides() {
        let (prompts, prompter) = prompts([submitted(&["123456"])]);
        let questions = [
            russh::client::Prompt {
                prompt: "Verification code: ".to_owned(),
                echo: false,
            },
            russh::client::Prompt {
                prompt: "Team: ".to_owned(),
                echo: true,
            },
        ];

        let answers = prompts
            .keyboard_interactive("deploy@db.internal", "MFA", "Enter the code", &questions)
            .await
            .unwrap()
            .unwrap();

        assert_eq!(answers.len(), 2, "one answer per prompt, blank when none was given");
        let fields = &prompter.requests()[0].fields;
        assert_eq!(fields[0].label, "Verification code:");
        assert!(fields[0].secret);
        assert!(!fields[1].secret);
    }
}
