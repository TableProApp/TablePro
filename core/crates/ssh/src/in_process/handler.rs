use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use russh::client::{DisconnectReason, Handler};
use russh::keys::PublicKeyOrCertificate;
use russh::keys::ssh_key::{Algorithm, HashAlg, PublicKey};
use tablepro_core::SshFailure;
use tokio_util::sync::CancellationToken;

use super::known_hosts::{KnownKey, KnownTypes, Verdict, append, known_types, lookup_name, read_known, verdict};
use super::prompts::Prompts;
use super::services::InProcessSsh;
use crate::lock;

// OpenSSH's sshkey_type() names, which its host key prompt shows.
pub(crate) fn key_type_label(algorithm: &Algorithm) -> String {
    match algorithm {
        Algorithm::Ed25519 => "ED25519".to_owned(),
        Algorithm::Ecdsa { .. } => "ECDSA".to_owned(),
        Algorithm::Rsa { .. } => "RSA".to_owned(),
        Algorithm::Dsa => "DSA".to_owned(),
        Algorithm::SkEcdsaSha2NistP256 => "ECDSA-SK".to_owned(),
        Algorithm::SkEd25519 => "ED25519-SK".to_owned(),
        other => other.as_str().to_ascii_uppercase(),
    }
}

// Why the session ended, kept for the error a later call reports.
#[derive(Debug, Default)]
pub(crate) struct SessionEnd {
    closed: CancellationToken,
    detail: Mutex<Option<String>>,
}

impl SessionEnd {
    pub fn closed(&self) -> &CancellationToken {
        &self.closed
    }

    pub fn detail(&self) -> Option<String> {
        lock(&self.detail).clone()
    }

    pub fn record(&self, detail: String) {
        lock(&self.detail).get_or_insert(detail);
        self.closed.cancel();
    }
}

// One hop's host key decision: known_hosts first, then the user.
pub(crate) struct HostKeyCheck {
    name: String,
    principal: String,
    files: Vec<PathBuf>,
    user_file: Option<PathBuf>,
    prompts: Arc<Prompts>,
    refusal: Mutex<Option<SshFailure>>,
}

impl HostKeyCheck {
    pub fn new(services: &InProcessSsh, host: &str, port: u16, prompts: Arc<Prompts>) -> Self {
        Self {
            name: lookup_name(host, port),
            principal: host.to_ascii_lowercase(),
            files: services.known_hosts_files().map(PathBuf::from).collect(),
            user_file: services.user_known_hosts.clone(),
            prompts,
            refusal: Mutex::new(None),
        }
    }

    pub async fn known_types(&self) -> KnownTypes {
        let (files, name) = (self.files.clone(), self.name.clone());
        tokio::task::spawn_blocking(move || known_types(&read_all(&files, &name)))
            .await
            .unwrap_or_default()
    }

    pub fn take_refusal(&self) -> Option<SshFailure> {
        lock(&self.refusal).take()
    }

    fn refuse(&self, failure: SshFailure) -> bool {
        *lock(&self.refusal) = Some(failure);
        false
    }

    async fn accept(&self, presented: &PublicKeyOrCertificate) -> bool {
        let (key, certificate) = match presented {
            PublicKeyOrCertificate::PublicKey { key, .. } => (key.clone(), None),
            PublicKeyOrCertificate::Certificate(certificate) => (
                PublicKey::from(certificate.public_key().clone()),
                Some(certificate.clone()),
            ),
        };
        let decided = {
            let (files, name, principal, key) = (
                self.files.clone(),
                self.name.clone(),
                self.principal.clone(),
                key.clone(),
            );
            tokio::task::spawn_blocking(move || {
                verdict(
                    &read_all(&files, &name),
                    &key,
                    certificate.as_ref(),
                    &principal,
                    unix_now(),
                )
            })
            .await
        };
        let Ok(decided) = decided else {
            return self.refuse(SshFailure::Internal);
        };
        let algorithm = key_type_label(&key.algorithm());
        let fingerprint = key.fingerprint(HashAlg::Sha256).to_string();
        match decided {
            Verdict::Trusted => true,
            Verdict::Revoked { path, line } => self.refuse(SshFailure::HostKeyRevoked {
                host: self.name.clone(),
                detail: format!(
                    "{} key {fingerprint} is revoked at {}:{line}",
                    algorithm,
                    path.display()
                ),
            }),
            Verdict::Changed { path, line } => self.refuse(SshFailure::HostKeyChanged {
                host: self.name.clone(),
                algorithm,
                sha256_fingerprint: fingerprint,
                known_hosts: path,
                line,
                trust_allowed: true,
            }),
            Verdict::Unknown => {
                if self.prompts.trust_host_key(&self.name, &algorithm, &fingerprint).await {
                    self.learn(key).await;
                    return true;
                }
                self.refuse(SshFailure::HostKeyUnknown {
                    host: self.name.clone(),
                    algorithm,
                    sha256_fingerprint: fingerprint,
                    trust_allowed: true,
                    declined: true,
                })
            }
        }
    }

    // ssh goes on with a key it could not record, warning only; so does this.
    async fn learn(&self, key: PublicKey) {
        let Some(file) = self.user_file.clone() else {
            tracing::warn!("no home directory to record a trusted host key in");
            return;
        };
        let name = self.name.clone();
        let written = tokio::task::spawn_blocking(move || append(&file, &name, &key)).await;
        match written {
            Ok(Ok(())) => {}
            Ok(Err(error)) => tracing::warn!(%error, "the trusted host key could not be recorded"),
            Err(error) => tracing::warn!(%error, "recording the trusted host key stopped"),
        }
    }
}

// ssh reads past a file it cannot open, as if it named nothing.
fn read_all(files: &[PathBuf], name: &str) -> Vec<KnownKey> {
    files
        .iter()
        .flat_map(|file| {
            read_known(file, name).unwrap_or_else(|error| {
                tracing::debug!(%error, file = %file.display(), "a known_hosts file could not be read");
                Vec::new()
            })
        })
        .collect()
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs())
}

pub(crate) struct HopHandler {
    pub check: Arc<HostKeyCheck>,
    pub end: Arc<SessionEnd>,
}

impl Handler for HopHandler {
    type Error = russh::Error;

    async fn check_server_key(&mut self, key: &PublicKeyOrCertificate) -> Result<bool, Self::Error> {
        Ok(self.check.accept(key).await)
    }

    async fn disconnected(&mut self, reason: DisconnectReason<Self::Error>) -> Result<(), Self::Error> {
        match reason {
            DisconnectReason::ReceivedDisconnect(info) => {
                let detail = if info.message.trim().is_empty() {
                    format!("{:?}", info.reason_code)
                } else {
                    info.message.trim().to_owned()
                };
                self.end.record(detail);
                Ok(())
            }
            DisconnectReason::Error(error) => {
                self.end.record(error.to_string());
                Err(error)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use russh::keys::ssh_key::private::Ed25519Keypair;
    use russh::keys::ssh_key::{EcdsaCurve, PrivateKey};
    use tablepro_core::credentials::{CredentialInteraction, PromptReply};
    use tablepro_test_support::FakePrompter;

    use super::super::clock::PromptClock;
    use super::*;

    fn host_key(seed: u8) -> PublicKey {
        PrivateKey::from(Ed25519Keypair::from_seed(&[seed; 32]))
            .public_key()
            .clone()
    }

    fn check(dir: &std::path::Path, replies: Vec<PromptReply>) -> (HostKeyCheck, Arc<FakePrompter>) {
        let prompter = Arc::new(FakePrompter::new(replies));
        let prompts = Arc::new(Prompts::new(
            CredentialInteraction::Attended(prompter.clone()),
            Arc::new(PromptClock::new(Duration::from_secs(20))),
            "deploy@db.internal:2222".to_owned(),
            tokio_util::sync::CancellationToken::new(),
        ));
        let services = InProcessSsh {
            user_known_hosts: Some(dir.join("known_hosts")),
            other_known_hosts: Vec::new(),
            identity_files: Vec::new(),
            agent: None,
            pageant: false,
        };
        (HostKeyCheck::new(&services, "DB.internal", 2222, prompts), prompter)
    }

    fn presented(key: &PublicKey) -> PublicKeyOrCertificate {
        PublicKeyOrCertificate::PublicKey {
            key: key.clone(),
            hash_alg: None,
        }
    }

    #[test]
    fn key_types_read_as_openssh_prints_them() {
        assert_eq!(key_type_label(&Algorithm::Ed25519), "ED25519");
        assert_eq!(
            key_type_label(&Algorithm::Ecdsa {
                curve: EcdsaCurve::NistP384
            }),
            "ECDSA"
        );
        assert_eq!(key_type_label(&Algorithm::Rsa { hash: None }), "RSA");
    }

    #[tokio::test]
    async fn an_unknown_key_the_user_trusts_is_recorded_and_not_asked_about_again() {
        let dir = tempfile::tempdir().unwrap();
        let accept = PromptReply::Submitted {
            values: Vec::new(),
            remember: false,
        };
        let (check, prompter) = check(dir.path(), vec![accept]);

        assert!(check.accept(&presented(&host_key(1))).await);
        assert!(check.accept(&presented(&host_key(1))).await);

        let requests = prompter.requests();
        assert_eq!(requests.len(), 1);
        let text = std::fs::read_to_string(dir.path().join("known_hosts")).unwrap();
        assert!(text.starts_with("[db.internal]:2222 ssh-ed25519 "), "{text}");
    }

    #[tokio::test]
    async fn a_declined_key_is_refused_with_its_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        let (check, _) = check(dir.path(), vec![PromptReply::Cancelled]);
        let key = host_key(1);

        assert!(!check.accept(&presented(&key)).await);

        assert_eq!(
            check.take_refusal(),
            Some(SshFailure::HostKeyUnknown {
                host: "[db.internal]:2222".to_owned(),
                algorithm: "ED25519".to_owned(),
                sha256_fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
                trust_allowed: true,
                declined: true,
            })
        );
        assert!(!dir.path().join("known_hosts").exists());
    }

    #[tokio::test]
    async fn a_changed_key_names_the_file_and_line_and_asks_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("known_hosts");
        std::fs::write(
            &file,
            format!("# first\n[db.internal]:2222 {}\n", host_key(2).to_openssh().unwrap()),
        )
        .unwrap();
        let (check, prompter) = check(dir.path(), Vec::new());

        assert!(!check.accept(&presented(&host_key(1))).await);

        assert!(prompter.requests().is_empty());
        assert!(matches!(
            check.take_refusal(),
            Some(SshFailure::HostKeyChanged { known_hosts, line: 2, trust_allowed: true, .. }) if known_hosts == file
        ));
    }

    #[test]
    fn the_first_end_is_the_one_kept() {
        let end = SessionEnd::default();

        end.record("Keepalive timeout".to_owned());
        end.record("Disconnected".to_owned());

        assert!(end.closed().is_cancelled());
        assert_eq!(end.detail().as_deref(), Some("Keepalive timeout"));
    }
}
