use std::path::{Path, PathBuf};

use russh::keys::known_hosts::{check_known_hosts_path, known_host_keys_path, learn_known_hosts_path};
use russh::keys::ssh_key::PublicKey;

use crate::UnknownHostKey;
use crate::handshake::HostKeyPromptEvent;
use crate::openssh::{AskpassPrompt, PromptAnswer, Prompter};

#[derive(Debug, Clone)]
pub(super) enum HostKeyOutcome {
    Trusted,
    LearnedNew { fingerprint: String },
    Changed { fingerprint: String, line: usize },
    Unknown { fingerprint: String },
    KnownHostsIo(String),
}

pub(super) fn verify_or_learn(
    host: &str,
    port: u16,
    key: &PublicKey,
    known_hosts: &Path,
    fingerprint: &str,
    unknown: UnknownHostKey,
) -> HostKeyOutcome {
    match check_known_host(host, port, key, known_hosts, fingerprint) {
        Ok(true) => HostKeyOutcome::Trusted,
        Ok(false) if unknown == UnknownHostKey::Refuse => HostKeyOutcome::Unknown {
            fingerprint: fingerprint.to_string(),
        },
        Ok(false) => record_known_host(host, port, key, known_hosts, fingerprint),
        Err(outcome) => outcome,
    }
}

pub(super) async fn verify_or_prompt(
    host: &str,
    port: u16,
    key: &PublicKey,
    known_hosts: &Path,
    fingerprint: &str,
    prompter: &dyn Prompter,
    prompt_events: &tokio::sync::mpsc::UnboundedSender<HostKeyPromptEvent>,
) -> HostKeyOutcome {
    match check_known_host(host, port, key, known_hosts, fingerprint) {
        Ok(true) => HostKeyOutcome::Trusted,
        Ok(false) => {
            let prompt = AskpassPrompt::HostKeyConfirmation {
                host: format!("{host}:{port}"),
                algorithm: key.algorithm().to_string(),
                fingerprint: fingerprint.to_string(),
            };
            let _ = prompt_events.send(HostKeyPromptEvent::WaitingForUser);
            let answer = prompter.answer(&prompt).await;
            let outcome = if matches!(answer, PromptAnswer::Accept) {
                record_known_host(host, port, key, known_hosts, fingerprint)
            } else {
                HostKeyOutcome::Unknown {
                    fingerprint: fingerprint.to_string(),
                }
            };
            let declined_fingerprint = match &outcome {
                HostKeyOutcome::Unknown { fingerprint } => Some(fingerprint.clone()),
                _ => None,
            };
            tracing::warn!(
                declined = declined_fingerprint.is_some(),
                "SSH host key prompt answered"
            );
            let _ = prompt_events.send(HostKeyPromptEvent::UserResponded { declined_fingerprint });
            outcome
        }
        Err(outcome) => outcome,
    }
}

fn check_known_host(
    host: &str,
    port: u16,
    key: &PublicKey,
    known_hosts: &Path,
    fingerprint: &str,
) -> Result<bool, HostKeyOutcome> {
    match check_known_hosts_path(host, port, key, known_hosts) {
        Ok(true) => Ok(true),
        Ok(false) => match known_host_keys_path(host, port, known_hosts) {
            Ok(existing) if !existing.is_empty() => Err(HostKeyOutcome::Changed {
                fingerprint: fingerprint.to_string(),
                line: existing[0].0,
            }),
            Ok(_) => Ok(false),
            Err(error) => Err(HostKeyOutcome::KnownHostsIo(error.to_string())),
        },
        Err(russh::keys::Error::KeyChanged { line }) => Err(HostKeyOutcome::Changed {
            fingerprint: fingerprint.to_string(),
            line,
        }),
        Err(error) => Err(HostKeyOutcome::KnownHostsIo(error.to_string())),
    }
}

fn record_known_host(host: &str, port: u16, key: &PublicKey, known_hosts: &Path, fingerprint: &str) -> HostKeyOutcome {
    match ensure_parent_dir(known_hosts).and_then(|_| {
        learn_known_hosts_path(host, port, key, known_hosts).map_err(|e| std::io::Error::other(format!("{e}")))
    }) {
        Ok(()) => HostKeyOutcome::LearnedNew {
            fingerprint: fingerprint.to_string(),
        },
        Err(error) => HostKeyOutcome::KnownHostsIo(error.to_string()),
    }
}

fn ensure_parent_dir(path: &Path) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}

pub fn default_known_hosts_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("tablepro").join("known_hosts"))
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;

    const KEY_A_BASE64: &str = "AAAAC3NzaC1lZDI1NTE5AAAAIGAdbe+Xv3hfmzwpfcGVeMHE/jfo5bmR1IgIpfuP4ypR";
    const KEY_B_BASE64: &str = "AAAAC3NzaC1lZDI1NTE5AAAAIFvC8V+mh5lxNlOLorBehIwTS2R/nvw2ghab6N1SlSk6";
    const RSA_KEY_BASE64: &str = "AAAAB3NzaC1yc2EAAAADAQABAAABAQDNTWi6IachyABYXmaOyLJ2TyBGTwkzBdub6FHS7xEB4XyqU9ZkAaFajaYlhT+3zmoFgDHhnNxULyJtOK3nHpcRaouO9XT8IfUqmmcVbkJrgsoS/gUyHKWqqbzpr70uZXoqM+tjbBAvPt7S6kts1QsJgi+AvPod+1lpfbe9O6Az+hREcPqHIn0BznhMzU/d6DirOCTE81fWoACZm0y6hrhE4MDU17JpTMe9E5bbNKLUh65d2BXBo0MolCClns/UA5trjRboNz+28HRMnyPqIzqMCE7J9HLmpCdTD2+aEGnD2RbsVwYKPRokiyJVOHtQGZwMsEqTgnrG7T61sM1ZCG+D";

    fn parse_key(base64: &str) -> PublicKey {
        russh::keys::parse_public_key_base64(base64).expect("valid base64 public key")
    }

    struct RecordingPrompter {
        accept: bool,
        prompts: Arc<Mutex<Vec<AskpassPrompt>>>,
    }

    #[async_trait::async_trait]
    impl Prompter for RecordingPrompter {
        async fn answer(&self, prompt: &AskpassPrompt) -> PromptAnswer {
            self.prompts.lock().unwrap().push(prompt.clone());
            if self.accept {
                PromptAnswer::Accept
            } else {
                PromptAnswer::Decline
            }
        }
    }

    fn recording_prompter(accept: bool) -> (RecordingPrompter, Arc<Mutex<Vec<AskpassPrompt>>>) {
        let prompts = Arc::new(Mutex::new(Vec::new()));
        (
            RecordingPrompter {
                accept,
                prompts: prompts.clone(),
            },
            prompts,
        )
    }

    #[test]
    fn verify_or_learn_creates_known_hosts_on_first_use() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested").join("known_hosts");
        let outcome = verify_or_learn(
            "bastion.example.com",
            22,
            &parse_key(KEY_A_BASE64),
            &path,
            "fp",
            UnknownHostKey::Learn,
        );
        assert!(matches!(outcome, HostKeyOutcome::LearnedNew { .. }));
        assert!(path.exists());
    }

    #[tokio::test]
    async fn built_in_host_key_trust_is_persisted_only_after_acceptance() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested").join("known_hosts");
        let key = parse_key(KEY_A_BASE64);
        let (decliner, prompts) = recording_prompter(false);
        let (prompt_events, _prompt_event_receiver) = tokio::sync::mpsc::unbounded_channel();
        let declined = verify_or_prompt(
            "bastion.example.com",
            2222,
            &key,
            &path,
            "SHA256:abc",
            &decliner,
            &prompt_events,
        )
        .await;
        assert!(matches!(declined, HostKeyOutcome::Unknown { .. }));
        assert!(!path.exists(), "decline must not modify known_hosts");
        assert!(matches!(
            prompts.lock().unwrap().as_slice(),
            [AskpassPrompt::HostKeyConfirmation { host, fingerprint, .. }]
                if host == "bastion.example.com:2222" && fingerprint == "SHA256:abc"
        ));

        let (acceptor, _) = recording_prompter(true);
        let accepted = verify_or_prompt(
            "bastion.example.com",
            2222,
            &key,
            &path,
            "SHA256:abc",
            &acceptor,
            &prompt_events,
        )
        .await;
        assert!(matches!(accepted, HostKeyOutcome::LearnedNew { .. }));
        assert!(path.exists(), "accepted key must be persisted");
    }

    #[tokio::test]
    async fn a_changed_builtin_host_key_is_refused_without_prompting_or_overwriting() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let first = parse_key(KEY_A_BASE64);
        let changed = parse_key(KEY_B_BASE64);
        let _ = verify_or_learn("bastion.example.com", 22, &first, &path, "first", UnknownHostKey::Learn);
        let (acceptor, prompts) = recording_prompter(true);
        let (prompt_events, _prompt_event_receiver) = tokio::sync::mpsc::unbounded_channel();
        let outcome = verify_or_prompt(
            "bastion.example.com",
            22,
            &changed,
            &path,
            "changed",
            &acceptor,
            &prompt_events,
        )
        .await;
        assert!(matches!(outcome, HostKeyOutcome::Changed { .. }));
        assert!(prompts.lock().unwrap().is_empty());
        assert!(matches!(
            verify_or_learn(
                "bastion.example.com",
                22,
                &first,
                &path,
                "first",
                UnknownHostKey::Refuse
            ),
            HostKeyOutcome::Trusted
        ));
    }

    #[test]
    fn a_refusing_connection_does_not_learn_an_unknown_key_but_still_trusts_a_known_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let key = parse_key(KEY_A_BASE64);
        let refused = verify_or_learn("bastion.example.com", 22, &key, &path, "fp", UnknownHostKey::Refuse);
        assert!(matches!(refused, HostKeyOutcome::Unknown { ref fingerprint } if fingerprint == "fp"));
        assert!(!path.exists(), "a refused key must not be written to known_hosts");

        let _ = verify_or_learn("bastion.example.com", 22, &key, &path, "fp", UnknownHostKey::Learn);
        let known = verify_or_learn("bastion.example.com", 22, &key, &path, "fp", UnknownHostKey::Refuse);
        assert!(matches!(known, HostKeyOutcome::Trusted));
        let changed = verify_or_learn(
            "bastion.example.com",
            22,
            &parse_key(KEY_B_BASE64),
            &path,
            "fp_b",
            UnknownHostKey::Refuse,
        );
        assert!(matches!(changed, HostKeyOutcome::Changed { .. }));
    }

    #[test]
    fn verify_or_learn_trusts_recorded_key_on_repeat() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let key = parse_key(KEY_A_BASE64);
        let _ = verify_or_learn("bastion.example.com", 22, &key, &path, "fp", UnknownHostKey::Learn);
        let outcome = verify_or_learn("bastion.example.com", 22, &key, &path, "fp", UnknownHostKey::Learn);
        assert!(matches!(outcome, HostKeyOutcome::Trusted));
    }

    #[test]
    fn verify_or_learn_detects_key_type_change() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let ed25519 = parse_key(KEY_A_BASE64);
        let rsa = parse_key(RSA_KEY_BASE64);
        let _ = verify_or_learn(
            "bastion.example.com",
            22,
            &ed25519,
            &path,
            "ed25519",
            UnknownHostKey::Learn,
        );
        let outcome = verify_or_learn("bastion.example.com", 22, &rsa, &path, "rsa", UnknownHostKey::Learn);
        assert!(matches!(outcome, HostKeyOutcome::Changed { fingerprint, .. } if fingerprint == "rsa"));
    }

    #[test]
    fn verify_or_learn_detects_key_mismatch() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let first = parse_key(KEY_A_BASE64);
        let _ = verify_or_learn("bastion.example.com", 22, &first, &path, "fp_a", UnknownHostKey::Learn);
        let outcome = verify_or_learn(
            "bastion.example.com",
            22,
            &parse_key(KEY_B_BASE64),
            &path,
            "fp_b",
            UnknownHostKey::Learn,
        );
        assert!(matches!(outcome, HostKeyOutcome::Changed { fingerprint, .. } if fingerprint == "fp_b"));
    }

    #[test]
    fn verify_or_learn_reports_io_error_when_known_hosts_path_is_a_directory() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts_dir");
        std::fs::create_dir(&path).unwrap();
        let outcome = verify_or_learn(
            "bastion.example.com",
            22,
            &parse_key(KEY_A_BASE64),
            &path,
            "fp",
            UnknownHostKey::Learn,
        );
        assert!(matches!(outcome, HostKeyOutcome::KnownHostsIo(_)));
    }
}
