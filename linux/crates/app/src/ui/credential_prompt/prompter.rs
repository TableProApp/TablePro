use futures::future::BoxFuture;
use tablepro_core::credentials::{CredentialPrompt, CredentialPrompter, PromptReply};
use tokio::sync::{mpsc, oneshot};

/// One prompt waiting for the user, and where the answer goes.
#[derive(Debug)]
pub struct PendingPrompt {
    pub prompt: CredentialPrompt,
    pub reply: oneshot::Sender<PromptReply>,
}

/// The prompts asked for, in order, until a presenter takes them.
#[derive(Debug)]
pub struct PromptQueue {
    receiver: mpsc::UnboundedReceiver<PendingPrompt>,
}

impl PromptQueue {
    pub async fn next(&mut self) -> Option<PendingPrompt> {
        self.receiver.recv().await
    }
}

/// The `CredentialPrompter` the app hands to every attended connect.
///
/// It only queues: the dialog is built on the GTK thread by the
/// presenter. With no presenter left to answer, every prompt is
/// cancelled rather than left hanging, so a connect never waits on a
/// window that is gone.
#[derive(Debug, Clone)]
pub struct GtkCredentialPrompter {
    requests: mpsc::UnboundedSender<PendingPrompt>,
}

impl GtkCredentialPrompter {
    pub fn new() -> (Self, PromptQueue) {
        let (requests, receiver) = mpsc::unbounded_channel();
        (Self { requests }, PromptQueue { receiver })
    }
}

impl CredentialPrompter for GtkCredentialPrompter {
    fn prompt(&self, request: CredentialPrompt) -> BoxFuture<'static, PromptReply> {
        let (reply, answer) = oneshot::channel();
        let queued = self.requests.send(PendingPrompt { prompt: request, reply });
        Box::pin(async move {
            if queued.is_err() {
                return PromptReply::Cancelled;
            }
            answer.await.unwrap_or(PromptReply::Cancelled)
        })
    }
}

#[cfg(test)]
mod tests {
    use secrecy::{ExposeSecret, SecretString};
    use tablepro_core::credentials::{PromptField, PromptPurpose, PromptReason};

    use super::*;

    fn prompt() -> CredentialPrompt {
        CredentialPrompt {
            purpose: PromptPurpose::DatabasePassword {
                reason: PromptReason::NotStored,
            },
            target: "app@db.example.com:5432/shop".to_owned(),
            fields: vec![PromptField {
                label: "Password".to_owned(),
                secret: true,
            }],
            offer_remember: true,
        }
    }

    #[tokio::test]
    async fn the_answer_given_to_the_queue_is_the_prompt_reply() {
        let (prompter, mut queue) = GtkCredentialPrompter::new();

        let answering = async {
            let pending = queue.next().await.expect("a queued prompt");
            assert_eq!(pending.prompt, prompt());
            pending
                .reply
                .send(PromptReply::Submitted {
                    values: vec![SecretString::from("hunter2")],
                    remember: true,
                })
                .expect("the asker is waiting");
        };
        let (reply, ()) = tokio::join!(prompter.prompt(prompt()), answering);

        let PromptReply::Submitted { values, remember } = reply else {
            panic!("expected a submitted reply");
        };
        assert!(remember);
        assert_eq!(values[0].expose_secret(), "hunter2");
    }

    #[tokio::test]
    async fn a_prompt_with_no_presenter_is_cancelled() {
        let (prompter, queue) = GtkCredentialPrompter::new();
        drop(queue);

        assert!(matches!(prompter.prompt(prompt()).await, PromptReply::Cancelled));
    }

    #[tokio::test]
    async fn a_prompt_dropped_unanswered_is_cancelled() {
        let (prompter, mut queue) = GtkCredentialPrompter::new();

        let dropping = async {
            drop(queue.next().await.expect("a queued prompt"));
        };
        let (reply, ()) = tokio::join!(prompter.prompt(prompt()), dropping);

        assert!(matches!(reply, PromptReply::Cancelled));
    }
}
