use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use futures::FutureExt;
use futures::future::BoxFuture;
use tablepro_core::credentials::{CredentialPrompt, CredentialPrompter, PromptPurpose, PromptReply};

use super::ReviewedHostKey;

/// The user's answer to ssh's host key question, given before ssh asks.
///
/// The user reviewed this key from a parked session and chose to trust
/// it, so the retry they started should not ask them again. Only that
/// key for that host is answered, and only once: ssh showing any other
/// key, the same key for another host, or asking anything else, reaches
/// the user as on any connect. ssh still makes the decision and writes
/// known_hosts itself.
pub(crate) struct TrustedHostKey {
    reviewed: ReviewedHostKey,
    prompter: Option<Arc<dyn CredentialPrompter>>,
    answered: AtomicBool,
}

impl TrustedHostKey {
    pub(crate) fn new(reviewed: ReviewedHostKey, prompter: Option<Arc<dyn CredentialPrompter>>) -> Self {
        Self {
            reviewed,
            prompter,
            answered: AtomicBool::new(false),
        }
    }

    fn answers(&self, request: &CredentialPrompt) -> bool {
        let PromptPurpose::SshHostKeyConfirmation { host, fingerprint, .. } = &request.purpose else {
            return false;
        };
        let reviewed = &self.reviewed;
        !fingerprint.is_empty()
            && *fingerprint == reviewed.fingerprint
            && host.eq_ignore_ascii_case(&reviewed.host)
            && !self.answered.swap(true, Ordering::AcqRel)
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
        host_key_of("bastion", fingerprint)
    }

    fn host_key_of(host: &str, fingerprint: &str) -> CredentialPrompt {
        CredentialPrompt {
            purpose: PromptPurpose::SshHostKeyConfirmation {
                host: host.to_owned(),
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
        let trusted = TrustedHostKey::new(reviewed("bastion", "SHA256:reviewed"), Some(user.clone()));

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
        let trusted = TrustedHostKey::new(reviewed("bastion", ""), None);

        assert!(!accepted(&trusted.prompt(host_key("")).await));
    }

    #[tokio::test]
    async fn a_key_trusted_for_one_host_does_not_answer_for_another() {
        let user = Arc::new(FakePrompter::new([]));
        let trusted = TrustedHostKey::new(reviewed("[db.example.com]:2222", "SHA256:reviewed"), Some(user.clone()));

        let other = trusted.prompt(host_key_of("jump.example.com", "SHA256:reviewed")).await;
        let reviewed_host = trusted
            .prompt(host_key_of("[DB.example.com]:2222", "SHA256:reviewed"))
            .await;

        assert!(!accepted(&other), "a key trusted for one host was trusted for another");
        assert!(accepted(&reviewed_host));
        assert_eq!(
            user.requests().len(),
            1,
            "the other host's question did not reach the user"
        );
    }

    fn reviewed(host: &str, fingerprint: &str) -> ReviewedHostKey {
        ReviewedHostKey {
            host: host.to_owned(),
            fingerprint: fingerprint.to_owned(),
        }
    }
}
