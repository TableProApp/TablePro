use std::fmt;
use std::sync::Arc;

use crate::credentials::CredentialPrompter;

#[derive(Clone)]
pub enum CredentialInteraction {
    Unattended,
    Attended(Arc<dyn CredentialPrompter>),
}

impl fmt::Debug for CredentialInteraction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Unattended => "Unattended",
            Self::Attended(_) => "Attended",
        })
    }
}
