use std::path::{Path, PathBuf};
use std::sync::Arc;

use russh::keys::agent::AgentIdentity;
use russh::keys::ssh_encoding::Encode;
use russh::keys::ssh_key::private::KeypairData;
use russh::keys::ssh_key::{Algorithm, Certificate, HashAlg, PrivateKey, PublicKey, Signature};
use secrecy::{ExposeSecret, SecretString};
use tablepro_core::SshFailure;
use tablepro_core::credentials::PromptReason;
use zeroize::Zeroizing;

use super::prompts::Prompts;

// OpenSSH's NumberOfPasswordPrompts default, which also bounds a key's passphrase.
pub(crate) const TRIES: usize = 3;

// The key's public half without its passphrase: the `.pub` beside it, or the
// copy an OpenSSH key file keeps in the clear.
pub(crate) async fn public_half(path: &Path) -> Option<PublicKey> {
    let mut beside = path.as_os_str().to_owned();
    beside.push(".pub");
    if let Ok(text) = tokio::fs::read_to_string(PathBuf::from(beside)).await
        && let Ok(key) = PublicKey::from_openssh(text.trim())
    {
        return Some(key);
    }
    let text = Zeroizing::new(tokio::fs::read_to_string(path).await.ok()?);
    PrivateKey::from_openssh(text.as_bytes())
        .ok()
        .map(|key| key.public_key().clone())
}

// The `-cert.pub` OpenSSH offers beside a key file.
pub(crate) async fn certificate_beside(path: &Path) -> Option<Certificate> {
    let mut beside = path.as_os_str().to_owned();
    beside.push("-cert.pub");
    let text = tokio::fs::read_to_string(PathBuf::from(beside)).await.ok()?;
    Certificate::from_openssh(text.trim()).ok()
}

// `chosen` is the file the connection names: what is wrong with it is the
// error, where a default identity that cannot be used is skipped as ssh skips it.
// `None` means nobody could give the passphrase.
pub(crate) async fn load(
    path: &Path,
    chosen: bool,
    stored: &mut Option<SecretString>,
    prompts: &Prompts,
) -> Result<Option<PrivateKey>, SshFailure> {
    let text = match tokio::fs::read_to_string(path).await {
        Ok(text) => Arc::new(Zeroizing::new(text)),
        Err(error) if chosen => {
            return Err(SshFailure::IdentityFileUnreadable {
                path: path.to_owned(),
                kind: error.kind(),
            });
        }
        Err(error) => {
            tracing::debug!(%error, path = %path.display(), "a default identity could not be read");
            return Ok(None);
        }
    };
    match decode(&text, None).await {
        Ok(key) => return usable(key, path, chosen),
        Err(russh::keys::Error::KeyIsEncrypted) => {}
        Err(_) if encrypted(&text) => {}
        Err(error) => return unusable(&error, path, chosen),
    }
    let mut reason = PromptReason::NotStored;
    for _ in 0..TRIES {
        let passphrase = match stored.take() {
            Some(passphrase) => passphrase,
            None => match prompts.passphrase(path, reason.clone()).await? {
                Some(passphrase) => passphrase,
                None => return Ok(None),
            },
        };
        match decode(&text, Some(passphrase)).await {
            Ok(key) => return usable(key, path, chosen),
            Err(error) => {
                tracing::debug!(%error, path = %path.display(), "the passphrase did not open the key");
                reason = PromptReason::Rejected;
            }
        }
    }
    Ok(None)
}

// Signs as an agent does, so a certificate beside a key file goes out with the RSA hash the server
// takes, which russh's own certificate login does not choose.
pub(crate) struct KeySigner(pub Arc<PrivateKey>);

impl russh::Signer for KeySigner {
    type Error = russh::AgentAuthError;

    async fn auth_sign(
        &mut self,
        _identity: &AgentIdentity,
        hash_alg: Option<HashAlg>,
        mut to_sign: Vec<u8>,
    ) -> Result<Vec<u8>, Self::Error> {
        let signature = sign(&self.0, hash_alg, &to_sign).map_err(russh::keys::Error::SshKey)?;
        let blob = signature.encode_vec().map_err(russh::keys::Error::SshEncoding)?;
        blob.encode(&mut to_sign).map_err(russh::keys::Error::SshEncoding)?;
        Ok(to_sign)
    }
}

fn sign(key: &PrivateKey, hash_alg: Option<HashAlg>, data: &[u8]) -> Result<Signature, russh::keys::ssh_key::Error> {
    use russh::keys::signature::Signer;
    Ok(match key.key_data() {
        KeypairData::Rsa(rsa) => (rsa, hash_alg).try_sign(data)?,
        keypair => keypair.try_sign(data)?,
    })
}

// Only OpenSSH and PKCS#5 files report themselves encrypted when opened without a passphrase.
fn encrypted(text: &str) -> bool {
    if text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") {
        return true;
    }
    text.trim_start().starts_with("PuTTY-User-Key-File-")
        && text
            .lines()
            .filter_map(|line| line.strip_prefix("Encryption:"))
            .any(|cipher| cipher.trim() != "none")
}

async fn decode(
    text: &Arc<Zeroizing<String>>,
    passphrase: Option<SecretString>,
) -> Result<PrivateKey, russh::keys::Error> {
    let text = text.clone();
    // A key's KDF rounds take a while, so they run off the runtime.
    tokio::task::spawn_blocking(move || {
        russh::keys::decode_secret_key(&text, passphrase.as_ref().map(ExposeSecret::expose_secret))
    })
    .await
    .map_err(|_| russh::keys::Error::CouldNotReadKey)?
}

fn usable(key: PrivateKey, path: &Path, chosen: bool) -> Result<Option<PrivateKey>, SshFailure> {
    // A security key signs on the device, which nothing in process can reach.
    if matches!(key.algorithm(), Algorithm::SkEd25519 | Algorithm::SkEcdsaSha2NistP256) {
        return unusable(&russh::keys::Error::CouldNotReadKey, path, chosen);
    }
    Ok(Some(key))
}

fn unusable(error: &russh::keys::Error, path: &Path, chosen: bool) -> Result<Option<PrivateKey>, SshFailure> {
    tracing::debug!(%error, path = %path.display(), "not a private key this transport can use");
    if chosen {
        return Err(SshFailure::IdentityFileInvalid { path: path.to_owned() });
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use russh::keys::ssh_key::private::Ed25519Keypair;
    use russh::keys::ssh_key::{Cipher, Kdf, LineEnding};
    use tablepro_core::credentials::{CredentialInteraction, PromptPurpose, PromptReply};
    use tablepro_test_support::FakePrompter;

    use super::super::clock::PromptClock;
    use super::*;

    fn key() -> PrivateKey {
        PrivateKey::from(Ed25519Keypair::from_seed(&[3; 32]))
    }

    fn write_key(dir: &Path, passphrase: Option<&str>) -> PathBuf {
        let path = dir.join("id_ed25519");
        let key = match passphrase {
            Some(passphrase) => {
                let kdf = Kdf::Bcrypt {
                    salt: vec![5; 16],
                    rounds: 4,
                };
                key().encrypt_with(Cipher::Aes256Ctr, kdf, 7, passphrase).unwrap()
            }
            None => key(),
        };
        std::fs::write(&path, key.to_openssh(LineEnding::LF).unwrap().as_bytes()).unwrap();
        path
    }

    fn prompts(replies: Vec<PromptReply>) -> (Prompts, Arc<FakePrompter>) {
        let prompter = Arc::new(FakePrompter::new(replies));
        let prompts = Prompts::new(
            CredentialInteraction::Attended(prompter.clone()),
            Arc::new(PromptClock::new(Duration::from_secs(20))),
            "db".to_owned(),
            tokio_util::sync::CancellationToken::new(),
        );
        (prompts, prompter)
    }

    fn typed(text: &str) -> PromptReply {
        PromptReply::Submitted {
            values: vec![SecretString::from(text)],
            remember: false,
        }
    }

    #[tokio::test]
    async fn the_stored_passphrase_goes_first_and_a_wrong_one_asks_again() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_key(dir.path(), Some("right"));
        let (prompts, prompter) = prompts(vec![typed("right")]);
        let mut stored = Some(SecretString::from("wrong"));

        let loaded = load(&path, true, &mut stored, &prompts).await.unwrap();

        assert_eq!(loaded.unwrap().public_key(), key().public_key());
        let requests = prompter.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0].purpose,
            PromptPurpose::SshPassphrase {
                path: path.clone(),
                reason: PromptReason::Rejected,
            }
        );
    }

    #[tokio::test]
    async fn the_signer_appends_a_signature_the_key_verifies_as_an_agent_does() {
        use russh::keys::signature::Verifier;
        use russh::keys::ssh_encoding::Decode;

        let key = Arc::new(key());
        let data = b"session and request".to_vec();
        let identity = AgentIdentity::from(key.public_key().clone());

        let signed = russh::Signer::auth_sign(&mut KeySigner(key.clone()), &identity, None, data.clone())
            .await
            .unwrap();

        assert!(signed.starts_with(&data));
        let mut appended = &signed[data.len()..];
        let blob = Vec::<u8>::decode(&mut appended).unwrap();
        let signature = Signature::decode(&mut blob.as_slice()).unwrap();
        assert!(appended.is_empty());
        key.public_key().key_data().verify(&data, &signature).unwrap();
    }

    #[test]
    fn pkcs8_and_putty_files_say_when_they_are_encrypted() {
        let pkcs8 = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIB\n-----END ENCRYPTED PRIVATE KEY-----\n";
        let putty = "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: aes256-cbc\nComment: deploy\n";
        let plain_putty = "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: deploy\n";

        assert!(encrypted(pkcs8));
        assert!(encrypted(putty));
        assert!(!encrypted(plain_putty));
        assert!(!encrypted("-----BEGIN PRIVATE KEY-----\n"));
    }

    #[tokio::test]
    async fn the_public_half_of_an_encrypted_key_reads_without_its_passphrase() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_key(dir.path(), Some("right"));

        assert_eq!(public_half(&path).await.as_ref(), Some(key().public_key()));
    }

    #[tokio::test]
    async fn a_chosen_file_that_is_missing_or_not_a_key_is_the_error_and_a_default_one_is_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("missing");
        let garbage = dir.path().join("garbage");
        std::fs::write(&garbage, "not a key").unwrap();
        let (prompts, _) = prompts(Vec::new());

        assert!(matches!(
            load(&missing, true, &mut None, &prompts).await,
            Err(SshFailure::IdentityFileUnreadable {
                kind: std::io::ErrorKind::NotFound,
                ..
            })
        ));
        assert_eq!(
            load(&garbage, true, &mut None, &prompts).await.unwrap_err(),
            SshFailure::IdentityFileInvalid { path: garbage.clone() }
        );
        assert!(load(&missing, false, &mut None, &prompts).await.unwrap().is_none());
        assert!(load(&garbage, false, &mut None, &prompts).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn an_encrypted_key_with_nobody_to_ask_is_not_used() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_key(dir.path(), Some("right"));
        let unattended = Prompts::new(
            CredentialInteraction::Unattended,
            Arc::new(PromptClock::new(Duration::from_secs(20))),
            "db".to_owned(),
            tokio_util::sync::CancellationToken::new(),
        );

        assert!(load(&path, true, &mut None, &unattended).await.unwrap().is_none());
    }
}
