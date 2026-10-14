use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use futures::FutureExt;
use futures::future::BoxFuture;
use tablepro_core::credentials::{CredentialPrompt, CredentialPrompter, PromptPurpose, PromptReply};

/// The user's answer to ssh's host key question, given before ssh asks.
///
/// The user reviewed this fingerprint from a parked session and chose to
/// trust it, so the retry they started should not ask them again. Only
/// that key is answered, and only once: ssh showing any other key, or
/// asking anything else, reaches the user as on any connect. ssh still
/// makes the decision and writes known_hosts itself.
pub(crate) struct TrustedHostKey {
    fingerprint: String,
    prompter: Option<Arc<dyn CredentialPrompter>>,
    answered: AtomicBool,
}

impl TrustedHostKey {
    pub(crate) fn new(fingerprint: String, prompter: Option<Arc<dyn CredentialPrompter>>) -> Self {
        Self {
            fingerprint,
            prompter,
            answered: AtomicBool::new(false),
        }
    }

    fn answers(&self, request: &CredentialPrompt) -> bool {
        let PromptPurpose::SshHostKeyConfirmation { fingerprint, .. } = &request.purpose else {
            return false;
        };
        !fingerprint.is_empty() && *fingerprint == self.fingerprint && !self.answered.swap(true, Ordering::AcqRel)
    }
}

impl CredentialPrompter for TrustedHostKey {
    fn prompt(&self, request: CredentialPrompt) -> BoxFuture<'static, PromptReply> {
        if self.answers(&request) {
            return futures::future::ready(PromptReply::Submitted {
                values: Vec::new(),
                remember: false,
            })
            .boxed();
        }
        match &self.prompter {
            Some(prompter) => prompter.prompt(request),
            None => futures::future::ready(PromptReply::Cancelled).boxed(),
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_test_support::FakePrompter;

    use super::*;

    fn host_key(fingerprint: &str) -> CredentialPrompt {
        CredentialPrompt {
            purpose: PromptPurpose::SshHostKeyConfirmation {
                host: "bastion".to_owned(),
                algorithm: "ED25519".to_owned(),
                fingerprint: fingerprint.to_owned(),
            },
            target: "bastion".to_owned(),
            fields: Vec::new(),
            offer_remember: false,
        }
    }

    fn accepted(reply: &PromptReply) -> bool {
        matches!(reply, PromptReply::Submitted { .. })
    }

    #[tokio::test]
    async fn the_reviewed_key_is_answered_once_and_anything_else_asks() {
        let user = Arc::new(FakePrompter::new([]));
        let trusted = TrustedHostKey::new("SHA256:reviewed".to_owned(), Some(user.clone()));

        let other = trusted.prompt(host_key("SHA256:other")).await;
        let reviewed = trusted.prompt(host_key("SHA256:reviewed")).await;
        let again = trusted.prompt(host_key("SHA256:reviewed")).await;

        assert!(!accepted(&other), "a key nobody reviewed was trusted");
        assert!(accepted(&reviewed));
        assert!(!accepted(&again), "one review answered twice");
        assert_eq!(user.requests().len(), 2, "the user was not asked about the rest");
    }

    #[tokio::test]
    async fn an_empty_fingerprint_is_never_answered() {
        let trusted = TrustedHostKey::new(String::new(), None);

        assert!(!accepted(&trusted.prompt(host_key("")).await));
    }
}
