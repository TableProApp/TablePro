use std::cell::{Cell, RefCell};

use tablepro_core::{ConfigError, TlsConfig};

/// Where the check of the chosen certificate files stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PemState {
    /// No file to read, or every chosen file parsed.
    Valid,
    /// A read is running; Connect waits for it.
    Pending,
    Invalid(ConfigError),
}

/// One run of the file check, to be matched against the latest.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PemTicket(u64);

/// Reads of the CA and client certificate files, newest wins.
///
/// The files are read on the blocking pool, so a slow disk can answer
/// after the user has already picked another file. Every request gets
/// a generation and only the latest one may change the state.
#[derive(Debug)]
pub struct PemValidation {
    latest: Cell<u64>,
    state: RefCell<PemState>,
}

impl Default for PemValidation {
    fn default() -> Self {
        Self {
            latest: Cell::new(0),
            state: RefCell::new(PemState::Valid),
        }
    }
}

impl PemValidation {
    /// Whether `tls` names any file worth reading.
    pub fn needs_check(tls: &TlsConfig) -> bool {
        tls.ca_file.is_some() || tls.client_identity.is_some()
    }

    /// Start a check, which makes every earlier one stale.
    pub fn begin(&self) -> PemTicket {
        let generation = self.latest.get().wrapping_add(1);
        self.latest.set(generation);
        self.state.replace(PemState::Pending);
        PemTicket(generation)
    }

    /// There is nothing to read any more; whatever is in flight is stale.
    pub fn clear(&self) {
        self.latest.set(self.latest.get().wrapping_add(1));
        self.state.replace(PemState::Valid);
    }

    /// Record a finished check. Returns false, and changes nothing, for
    /// a check that a later one replaced.
    pub fn finish(&self, ticket: PemTicket, result: Result<(), ConfigError>) -> bool {
        if ticket.0 != self.latest.get() {
            return false;
        }
        self.state.replace(match result {
            Ok(()) => PemState::Valid,
            Err(error) => PemState::Invalid(error),
        });
        true
    }

    pub fn state(&self) -> PemState {
        self.state.borrow().clone()
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tablepro_core::CertificateFileProblem;

    use super::*;

    fn unreadable() -> ConfigError {
        ConfigError::CaFile {
            path: PathBuf::from("/etc/tls/ca.pem"),
            problem: CertificateFileProblem::NoCertificates,
        }
    }

    #[test]
    fn stale_generation_result_is_ignored() {
        let validation = PemValidation::default();
        let first = validation.begin();
        let second = validation.begin();

        assert!(!validation.finish(first, Err(unreadable())), "a stale result landed");
        assert_eq!(validation.state(), PemState::Pending);

        assert!(validation.finish(second, Ok(())));
        assert_eq!(validation.state(), PemState::Valid);
    }

    #[test]
    fn clearing_the_files_drops_the_check_in_flight() {
        let validation = PemValidation::default();
        let running = validation.begin();

        validation.clear();

        assert!(!validation.finish(running, Err(unreadable())));
        assert_eq!(validation.state(), PemState::Valid);
    }

    #[test]
    fn a_failed_check_holds_its_error() {
        let validation = PemValidation::default();
        let ticket = validation.begin();

        assert!(validation.finish(ticket, Err(unreadable())));

        assert_eq!(validation.state(), PemState::Invalid(unreadable()));
    }

    #[test]
    fn only_a_config_with_files_needs_reading() {
        assert!(!PemValidation::needs_check(&TlsConfig::verify_full()));
        assert!(PemValidation::needs_check(&TlsConfig {
            ca_file: Some(PathBuf::from("/etc/tls/ca.pem")),
            ..TlsConfig::verify_full()
        }));
    }
}
