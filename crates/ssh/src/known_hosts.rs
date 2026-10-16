use std::ffi::OsString;
use std::io::Write;
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
    match is_revoked(host, port, key, known_hosts) {
        Ok(false) => {}
        Ok(true) => {
            return Err(HostKeyOutcome::KnownHostsIo(format!(
                "the host key of {host}:{port} is marked @revoked in {}; refusing to connect",
                known_hosts.display()
            )));
        }
        Err(error) => return Err(HostKeyOutcome::KnownHostsIo(error)),
    }
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

struct ScratchFile(PathBuf);

impl ScratchFile {
    fn create(contents: &str) -> std::io::Result<Self> {
        use std::os::unix::fs::OpenOptionsExt;
        let path = std::env::temp_dir().join(format!("tablepro-revoked-{}", uuid::Uuid::new_v4().simple()));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)?;
        let scratch = Self(path);
        file.write_all(contents.as_bytes())?;
        Ok(scratch)
    }
}

impl Drop for ScratchFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn is_revoked(host: &str, port: u16, key: &PublicKey, known_hosts: &Path) -> Result<bool, String> {
    let text = match std::fs::read_to_string(known_hosts) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.to_string()),
    };
    let revoked: String = text
        .lines()
        .filter_map(|line| {
            line.trim_start()
                .strip_prefix("@revoked")
                .filter(|rest| rest.starts_with(char::is_whitespace))
        })
        .map(|rest| format!("{}\n", rest.trim_start()))
        .collect();
    if revoked.is_empty() {
        return Ok(false);
    }
    if revoked.lines().any(|line| revoked_by_pattern(line, host, port, key)) {
        return Ok(true);
    }
    let scratch = ScratchFile::create(&revoked).map_err(|error| error.to_string())?;
    let keys = known_host_keys_path(host, port, &scratch.0).map_err(|error| error.to_string())?;
    Ok(keys.iter().any(|(_, known)| known == key))
}

fn revoked_by_pattern(line: &str, host: &str, port: u16, key: &PublicKey) -> bool {
    let mut fields = line.split_whitespace();
    let (Some(patterns), Some(_), Some(base64)) = (fields.next(), fields.next(), fields.next()) else {
        return false;
    };
    if patterns.starts_with('|') || !host_patterns_match(patterns, host, port) {
        return false;
    }
    russh::keys::parse_public_key_base64(base64).is_ok_and(|revoked| &revoked == key)
}

fn host_patterns_match(patterns: &str, host: &str, port: u16) -> bool {
    let host = host.to_ascii_lowercase();
    let name = if port == 22 { host } else { format!("[{host}]:{port}") };
    let mut matched = false;
    for pattern in patterns.split(',').map(str::to_ascii_lowercase) {
        match pattern.strip_prefix('!') {
            Some(negated) if wildcard_match(negated.as_bytes(), name.as_bytes()) => return false,
            Some(_) => {}
            None => matched |= wildcard_match(pattern.as_bytes(), name.as_bytes()),
        }
    }
    matched
}

fn wildcard_match(pattern: &[u8], text: &[u8]) -> bool {
    let (mut p, mut t) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while t < text.len() {
        match pattern.get(p) {
            Some(b'*') => {
                star = Some((p, t));
                p += 1;
            }
            Some(&c) if c == b'?' || c == text[t] => {
                p += 1;
                t += 1;
            }
            _ => match star {
                Some((star_p, star_t)) => {
                    p = star_p + 1;
                    t = star_t + 1;
                    star = Some((star_p, star_t + 1));
                }
                None => return false,
            },
        }
    }
    pattern[p.min(pattern.len())..].iter().all(|c| *c == b'*')
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
    known_hosts_path_from(std::env::var_os("XDG_CONFIG_HOME"), std::env::var_os("HOME"))
}

fn known_hosts_path_from(xdg_config_home: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    let base = xdg_config_home
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| home.map(|home| PathBuf::from(home).join(".config")))?;
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

    #[test]
    fn default_known_hosts_path_uses_the_product_config_directory() {
        match default_known_hosts_path() {
            Some(path) => {
                assert_eq!(path.file_name().and_then(|name| name.to_str()), Some("known_hosts"));
                assert_eq!(
                    path.parent().and_then(Path::file_name).and_then(|name| name.to_str()),
                    Some("tablepro")
                );
            }
            None => {
                assert!(std::env::var_os("XDG_CONFIG_HOME").is_none());
                assert!(std::env::var_os("HOME").is_none());
            }
        }
    }

    #[tokio::test]
    async fn a_declined_host_key_sends_its_fingerprint_to_the_handshake() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let key = parse_key(KEY_A_BASE64);
        let (decliner, _) = recording_prompter(false);
        let (prompt_events, mut prompt_event_receiver) = tokio::sync::mpsc::unbounded_channel();
        let outcome = verify_or_prompt(
            "bastion.example.com",
            2222,
            &key,
            &path,
            "SHA256:declined",
            &decliner,
            &prompt_events,
        )
        .await;

        assert!(matches!(outcome, HostKeyOutcome::Unknown { .. }));
        assert!(matches!(
            prompt_event_receiver.try_recv(),
            Ok(HostKeyPromptEvent::WaitingForUser)
        ));
        assert!(matches!(
            prompt_event_receiver.try_recv(),
            Ok(HostKeyPromptEvent::UserResponded {
                declined_fingerprint: Some(fingerprint)
            }) if fingerprint == "SHA256:declined"
        ));
        assert!(prompt_event_receiver.try_recv().is_err());
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
    const HASHED_BASTION: &str = "|1|AQIDBAUGBwgJCgsMDQ4PEBESExQ=|DUqwpsqDi3m75dxKjEHG8TtOtp4=";

    fn learn_then(path: &Path, host: &str, port: u16, key_base64: &str, unknown: UnknownHostKey) -> HostKeyOutcome {
        verify_or_learn(host, port, &parse_key(key_base64), path, "fp", unknown)
    }

    #[test]
    fn a_revoked_key_is_never_trusted_never_learned_and_never_prompted_for() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let line = format!("@revoked bastion.example.com ssh-ed25519 {KEY_A_BASE64}\n");
        std::fs::write(&path, &line).unwrap();

        for unknown in [UnknownHostKey::Learn, UnknownHostKey::Refuse] {
            let outcome = learn_then(&path, "bastion.example.com", 22, KEY_A_BASE64, unknown);
            assert!(
                !matches!(
                    outcome,
                    HostKeyOutcome::Trusted | HostKeyOutcome::LearnedNew { .. } | HostKeyOutcome::Unknown { .. }
                ),
                "a revoked key came back as {outcome:?}"
            );
            assert_eq!(
                std::fs::read_to_string(&path).unwrap(),
                line,
                "a revoked key was written over"
            );
        }
    }

    #[test]
    fn an_entry_for_port_22_does_not_trust_another_port() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        learn_then(&path, "h.example.com", 22, KEY_A_BASE64, UnknownHostKey::Learn);

        let other_port = learn_then(&path, "h.example.com", 2222, KEY_B_BASE64, UnknownHostKey::Refuse);
        assert!(matches!(other_port, HostKeyOutcome::Unknown { .. }), "{other_port:?}");
        let learned = learn_then(&path, "h.example.com", 2222, KEY_B_BASE64, UnknownHostKey::Learn);
        assert!(matches!(learned, HostKeyOutcome::LearnedNew { .. }), "{learned:?}");
        let again = learn_then(&path, "h.example.com", 2222, KEY_B_BASE64, UnknownHostKey::Refuse);
        assert!(matches!(again, HostKeyOutcome::Trusted), "{again:?}");
        let first = learn_then(&path, "h.example.com", 22, KEY_A_BASE64, UnknownHostKey::Refuse);
        assert!(matches!(first, HostKeyOutcome::Trusted), "{first:?}");
    }

    #[test]
    fn an_ipv6_host_round_trips_on_both_ports() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        for port in [22, 2222] {
            let learned = learn_then(&path, "::1", port, KEY_A_BASE64, UnknownHostKey::Learn);
            assert!(
                matches!(learned, HostKeyOutcome::LearnedNew { .. }),
                "{port}: {learned:?}"
            );
            let again = learn_then(&path, "::1", port, KEY_A_BASE64, UnknownHostKey::Refuse);
            assert!(matches!(again, HostKeyOutcome::Trusted), "{port}: {again:?}");
            let changed = learn_then(&path, "::1", port, KEY_B_BASE64, UnknownHostKey::Refuse);
            assert!(matches!(changed, HostKeyOutcome::Changed { .. }), "{port}: {changed:?}");
        }
    }

    #[test]
    fn a_matching_line_with_an_unreadable_key_fails_closed_and_is_not_written_over() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let line = "bastion.example.com ssh-ed25519 notbase64\n";
        std::fs::write(&path, line).unwrap();

        for unknown in [UnknownHostKey::Learn, UnknownHostKey::Refuse] {
            let outcome = learn_then(&path, "bastion.example.com", 22, KEY_A_BASE64, unknown);
            assert!(matches!(outcome, HostKeyOutcome::KnownHostsIo(_)), "{outcome:?}");
            assert_eq!(std::fs::read_to_string(&path).unwrap(), line);
        }
    }

    #[test]
    fn a_hashed_entry_trusts_its_key_and_flags_any_other_as_changed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        std::fs::write(&path, format!("{HASHED_BASTION} ssh-ed25519 {KEY_A_BASE64}\n")).unwrap();

        let trusted = learn_then(&path, "bastion.example.com", 22, KEY_A_BASE64, UnknownHostKey::Refuse);
        assert!(matches!(trusted, HostKeyOutcome::Trusted), "{trusted:?}");
        let changed = learn_then(&path, "bastion.example.com", 22, KEY_B_BASE64, UnknownHostKey::Refuse);
        assert!(matches!(changed, HostKeyOutcome::Changed { .. }), "{changed:?}");
        let other_host = learn_then(&path, "other.example.com", 22, KEY_A_BASE64, UnknownHostKey::Refuse);
        assert!(matches!(other_host, HostKeyOutcome::Unknown { .. }), "{other_host:?}");
    }

    #[test]
    fn comments_blank_lines_and_crlf_do_not_hide_or_break_an_entry() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        std::fs::write(
            &path,
            format!("# a comment\r\n\r\nbastion.example.com ssh-ed25519 {KEY_A_BASE64}\r\n"),
        )
        .unwrap();

        let outcome = learn_then(&path, "bastion.example.com", 22, KEY_A_BASE64, UnknownHostKey::Refuse);
        assert!(matches!(outcome, HostKeyOutcome::Trusted), "{outcome:?}");
    }
    #[test]
    fn the_default_path_ignores_an_empty_or_relative_xdg_config_home() {
        let home = Some(OsString::from("/h"));
        let expected = Some(PathBuf::from("/h/.config/tablepro/known_hosts"));
        assert_eq!(known_hosts_path_from(Some(OsString::new()), home.clone()), expected);
        assert_eq!(
            known_hosts_path_from(Some(OsString::from("cfg")), home.clone()),
            expected
        );
        assert_eq!(known_hosts_path_from(None, home.clone()), expected);
        assert_eq!(
            known_hosts_path_from(Some(OsString::from("/x")), home),
            Some(PathBuf::from("/x/tablepro/known_hosts"))
        );
        assert_eq!(known_hosts_path_from(Some(OsString::new()), None), None);
    }

    #[test]
    fn a_revoked_line_for_another_host_or_key_does_not_block_a_good_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        std::fs::write(
            &path,
            format!(
                "@revoked other.example.com ssh-ed25519 {KEY_A_BASE64}\n@revoked bastion.example.com ssh-ed25519 {KEY_B_BASE64}\nbastion.example.com ssh-ed25519 {KEY_A_BASE64}\n"
            ),
        )
        .unwrap();

        let good = learn_then(&path, "bastion.example.com", 22, KEY_A_BASE64, UnknownHostKey::Refuse);
        assert!(matches!(good, HostKeyOutcome::Trusted), "{good:?}");
        let revoked = learn_then(&path, "bastion.example.com", 22, KEY_B_BASE64, UnknownHostKey::Refuse);
        assert!(matches!(revoked, HostKeyOutcome::KnownHostsIo(_)), "{revoked:?}");
    }

    #[test]
    fn a_revoked_hashed_entry_is_matched_too() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        std::fs::write(&path, format!("@revoked {HASHED_BASTION} ssh-ed25519 {KEY_A_BASE64}\n")).unwrap();

        let outcome = learn_then(&path, "bastion.example.com", 22, KEY_A_BASE64, UnknownHostKey::Learn);
        assert!(matches!(outcome, HostKeyOutcome::KnownHostsIo(message) if message.contains("@revoked")));
    }

    #[test]
    fn a_revoked_wildcard_entry_is_matched() {
        for (pattern, host, port) in [
            ("*", "bastion.example.com", 22),
            ("*.example.com", "bastion.example.com", 22),
            ("bastion?.example.com", "bastion1.example.com", 22),
            ("[*.example.com]:2222", "bastion.example.com", 2222),
            ("other.example.com,*.EXAMPLE.com", "bastion.example.com", 22),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("known_hosts");
            std::fs::write(&path, format!("@revoked {pattern} ssh-ed25519 {KEY_A_BASE64}\n")).unwrap();

            let outcome = learn_then(&path, host, port, KEY_A_BASE64, UnknownHostKey::Learn);
            assert!(
                matches!(&outcome, HostKeyOutcome::KnownHostsIo(message) if message.contains("@revoked")),
                "{pattern} for {host}:{port}: {outcome:?}"
            );
        }
    }

    #[test]
    fn a_negated_or_non_matching_revoked_pattern_does_not_block() {
        for (pattern, host, port) in [
            ("*.example.com,!bastion.example.com", "bastion.example.com", 22),
            ("*.example.org", "bastion.example.com", 22),
            ("[*.example.com]:2222", "bastion.example.com", 22),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("known_hosts");
            std::fs::write(&path, format!("@revoked {pattern} ssh-ed25519 {KEY_A_BASE64}\n")).unwrap();

            let outcome = learn_then(&path, host, port, KEY_A_BASE64, UnknownHostKey::Learn);
            assert!(
                matches!(outcome, HostKeyOutcome::LearnedNew { .. }),
                "{pattern} for {host}:{port}: {outcome:?}"
            );
        }
    }

    #[test]
    fn wildcards_follow_openssh_rules() {
        assert!(wildcard_match(b"*", b""));
        assert!(wildcard_match(b"a*c", b"abbbc"));
        assert!(wildcard_match(b"a?c", b"abc"));
        assert!(!wildcard_match(b"a?c", b"ac"));
        assert!(!wildcard_match(b"*.example.com", b"example.com"));
        assert!(wildcard_match(b"*.*.com", b"a.b.com"));
    }

    #[test]
    fn the_scratch_file_is_private_and_removed_when_dropped() {
        use std::os::unix::fs::PermissionsExt;
        let scratch = ScratchFile::create("a line\n").unwrap();
        let path = scratch.0.clone();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "a line\n");
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        drop(scratch);
        assert!(!path.exists());
    }
}
