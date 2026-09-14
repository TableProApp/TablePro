use std::path::PathBuf;

use crate::credentials::PromptReason;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PromptPurpose {
    DatabasePassword {
        reason: PromptReason,
    },
    SshPassword {
        reason: PromptReason,
    },
    SshPassphrase {
        path: PathBuf,
        reason: PromptReason,
    },
    SshKeyboardInteractive {
        name: String,
        instructions: String,
    },
    SshHostKeyConfirmation {
        host: String,
        algorithm: String,
        fingerprint: String,
    },
    SshConfirmation {
        text: String,
    },
}
