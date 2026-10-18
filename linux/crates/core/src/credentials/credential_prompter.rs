use futures::future::BoxFuture;

use crate::credentials::{CredentialPrompt, PromptReply};

pub trait CredentialPrompter: Send + Sync {
    fn prompt(&self, request: CredentialPrompt) -> BoxFuture<'static, PromptReply>;
}
