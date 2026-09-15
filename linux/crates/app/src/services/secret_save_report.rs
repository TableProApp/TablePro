use tablepro_core::credentials::{SecretError, SecretKind};

/// Which secrets failed to store, so the save can carry on and the user
/// is told exactly what was not kept.
#[derive(Debug, Default)]
pub(crate) struct SecretSaveReport {
    pub failed: Vec<(SecretKind, SecretError)>,
}

impl SecretSaveReport {
    pub fn record(&mut self, kind: SecretKind, result: Result<(), SecretError>) -> bool {
        match result {
            Ok(()) => true,
            Err(error) => {
                self.failed.push((kind, error));
                false
            }
        }
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.failed.is_empty()
    }

    /// One line per failure, for a toast.
    pub fn messages(&self) -> Vec<String> {
        self.failed
            .iter()
            .map(|(_, error)| {
                crate::i18n::gettext_f(
                    "Password not saved in the keyring: {reason}",
                    &[("reason", &error.to_string())],
                )
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_reports_success_and_collects_failures() {
        let mut report = SecretSaveReport::default();

        assert!(report.record(SecretKind::DatabasePassword, Ok(())));
        assert!(!report.record(SecretKind::SshPassphrase, Err(SecretError::Locked)));

        assert!(!report.is_empty());
        assert_eq!(report.failed.len(), 1);
        assert_eq!(report.failed[0].0, SecretKind::SshPassphrase);
    }

    #[test]
    fn messages_name_the_reason() {
        let mut report = SecretSaveReport::default();
        report.record(SecretKind::DatabasePassword, Err(SecretError::UnlockDismissed));

        let messages = report.messages();

        assert_eq!(messages.len(), 1);
        assert!(
            messages[0].contains("Password not saved in the keyring"),
            "{messages:?}"
        );
        assert!(messages[0].contains("dismissed"), "{messages:?}");
    }

    #[test]
    fn an_empty_report_has_no_messages() {
        let report = SecretSaveReport::default();

        assert!(report.is_empty());
        assert!(report.messages().is_empty());
    }
}
