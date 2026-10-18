use crate::credentials::{PromptField, PromptPurpose};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CredentialPrompt {
    pub purpose: PromptPurpose,
    pub target: String,
    pub fields: Vec<PromptField>,
    pub offer_remember: bool,
}
