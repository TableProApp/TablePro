use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::Duration;

use futures::future::BoxFuture;
use tablepro_core::credentials::{CredentialPrompt, CredentialPrompter, PromptReply};

use crate::lock;

#[derive(Debug, Default)]
pub struct FakePrompter {
    replies: Mutex<VecDeque<PromptReply>>,
    requests: Mutex<Vec<CredentialPrompt>>,
    delay: Option<Duration>,
}

impl FakePrompter {
    pub fn new(replies: impl IntoIterator<Item = PromptReply>) -> Self {
        Self {
            replies: Mutex::new(replies.into_iter().collect()),
            requests: Mutex::new(Vec::new()),
            delay: None,
        }
    }

    pub fn with_delay(mut self, delay: Duration) -> Self {
        self.delay = Some(delay);
        self
    }

    pub fn requests(&self) -> Vec<CredentialPrompt> {
        lock(&self.requests).clone()
    }
}

impl CredentialPrompter for FakePrompter {
    fn prompt(&self, request: CredentialPrompt) -> BoxFuture<'static, PromptReply> {
        lock(&self.requests).push(request);
        let reply = lock(&self.replies).pop_front().unwrap_or(PromptReply::Cancelled);
        let delay = self.delay;
        Box::pin(async move {
            if let Some(delay) = delay {
                tokio::time::sleep(delay).await;
            }
            reply
        })
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::credentials::{PromptPurpose, PromptReason};

    use super::*;

    fn request() -> CredentialPrompt {
        CredentialPrompt {
            purpose: PromptPurpose::SshPassword {
                reason: PromptReason::NotStored,
            },
            target: "deploy@bastion".to_owned(),
            fields: Vec::new(),
            offer_remember: false,
        }
    }

    #[tokio::test(start_paused = true)]
    async fn replies_in_order_then_cancels_and_records_requests() {
        let prompter = FakePrompter::new([PromptReply::Submitted {
            values: Vec::new(),
            remember: true,
        }])
        .with_delay(Duration::from_secs(3));

        let started = tokio::time::Instant::now();
        assert!(matches!(
            prompter.prompt(request()).await,
            PromptReply::Submitted { remember: true, .. }
        ));
        assert!(started.elapsed() >= Duration::from_secs(3));
        assert!(matches!(prompter.prompt(request()).await, PromptReply::Cancelled));
        assert_eq!(prompter.requests().len(), 2);
    }
}
