#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PromptReason {
    NotStored,
    KeyringLocked,
    KeyringUnavailable { detail: String },
    Rejected,
}
