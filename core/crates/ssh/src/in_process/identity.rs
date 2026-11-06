use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read};
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
use super::short_scalar;

// OpenSSH's NumberOfPasswordPrompts default, which also bounds a key's passphrase.
pub(crate) const TRIES: usize = 3;

// Keys and certificates need far less space; match the bound for TLS identity files.
const MAX_IDENTITY_BYTES: u64 = 1024 * 1024;

async fn read_identity(path: &Path) -> io::Result<Zeroizing<String>> {
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || read_identity_blocking(&path))
        .await
        .map_err(io::Error::other)?
}

fn read_identity_blocking(path: &Path) -> io::Result<Zeroizing<String>> {
    if !std::fs::metadata(path)?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not a regular identity file",
        ));
    }
    let file = open_identity(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not a regular identity file",
        ));
    }
    if metadata.len() > MAX_IDENTITY_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "identity file is too large"));
    }
    let mut text = Zeroizing::new(String::new());
    // The file can grow after its metadata was read.
    file.take(MAX_IDENTITY_BYTES + 1).read_to_string(&mut text)?;
    if text.len() as u64 > MAX_IDENTITY_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "identity file is too large"));
    }
    Ok(text)
}

#[cfg(unix)]
fn open_identity(path: &Path) -> io::Result<File> {
    use rustix::fs::{Mode, OFlags, open};

    // A FIFO swapped in after metadata must not wait for a writer on the blocking pool.
    open(path, OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NONBLOCK, Mode::empty())
        .map(File::from)
        .map_err(Into::into)
}

#[cfg(not(unix))]
fn open_identity(path: &Path) -> io::Result<File> {
    File::open(path)
}

// The key's public half without its passphrase: the `.pub` beside it, or the
// copy an OpenSSH key file keeps in the clear.
pub(crate) async fn public_half(path: &Path) -> Option<PublicKey> {
    let mut beside = path.as_os_str().to_owned();
    beside.push(".pub");
    if let Ok(text) = read_identity(&PathBuf::from(beside)).await
        && let Ok(key) = PublicKey::from_openssh(text.trim())
    {
        return Some(key);
    }
    let text = read_identity(path).await.ok()?;
    PrivateKey::from_openssh(text.as_bytes())
        .ok()
        .map(|key| key.public_key().clone())
}

// The `-cert.pub` OpenSSH offers beside a key file.
pub(crate) async fn certificate_beside(path: &Path) -> Option<Certificate> {
    let mut beside = path.as_os_str().to_owned();
    beside.push("-cert.pub");
    let text = read_identity(&PathBuf::from(beside)).await.ok()?;
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
    let text = match read_identity(path).await {
        Ok(text) => Arc::new(text),
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

// Opens the key file only once the server says it would take the key, so a passphrase is asked for
// only then, as OpenSSH asks.
pub(crate) struct FileSigner<'a> {
    pub path: &'a Path,
    pub chosen: bool,
    pub stored: &'a mut Option<SecretString>,
    pub prompts: &'a Prompts,
    pub keys: &'a mut HashMap<PathBuf, Arc<PrivateKey>>,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum FileSignError {
    #[error(transparent)]
    Send(#[from] russh::SendError),
    #[error(transparent)]
    Failure(#[from] SshFailure),
    #[error("nobody could give the key's passphrase")]
    Unanswered,
    #[error(transparent)]
    Agent(#[from] russh::AgentAuthError),
}

impl FileSigner<'_> {
    pub async fn key(&mut self) -> Result<Option<Arc<PrivateKey>>, SshFailure> {
        if let Some(key) = self.keys.get(self.path) {
            return Ok(Some(key.clone()));
        }
        let Some(key) = load(self.path, self.chosen, self.stored, self.prompts).await? else {
            return Ok(None);
        };
        let key = Arc::new(key);
        self.keys.insert(self.path.to_owned(), key.clone());
        Ok(Some(key))
    }
}

impl russh::Signer for FileSigner<'_> {
    type Error = FileSignError;

    async fn auth_sign(
        &mut self,
        identity: &AgentIdentity,
        hash_alg: Option<HashAlg>,
        to_sign: Vec<u8>,
    ) -> Result<Vec<u8>, Self::Error> {
        let key = self.key().await?.ok_or(FileSignError::Unanswered)?;
        Ok(KeySigner(key).auth_sign(identity, hash_alg, to_sign).await?)
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
        let passphrase = passphrase.as_ref().map(ExposeSecret::expose_secret);
        russh::keys::decode_secret_key(&text, passphrase).or_else(|error| {
            if short_scalar::is_refusal(&error) {
                short_scalar::decode(&text, passphrase).ok_or(error)
            } else {
                Err(error)
            }
        })
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
    async fn oversized_private_keys_are_refused_before_decoding() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_key(dir.path(), None);
        let mut contents = std::fs::read_to_string(&path).unwrap();
        contents.extend(std::iter::repeat_n('\n', MAX_IDENTITY_BYTES as usize));
        std::fs::write(&path, contents).unwrap();
        let (prompts, prompter) = prompts(Vec::new());

        assert!(matches!(
            load(&path, true, &mut None, &prompts).await,
            Err(SshFailure::IdentityFileUnreadable {
                kind: io::ErrorKind::InvalidData,
                ..
            })
        ));
        assert!(load(&path, false, &mut None, &prompts).await.unwrap().is_none());
        assert!(public_half(&path).await.is_none());
        assert!(prompter.requests().is_empty());
    }

    #[tokio::test]
    async fn oversized_optional_public_keys_and_certificates_are_skipped() {
        use russh::keys::ssh_key::certificate::{Builder, CertType};

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("id_ed25519");
        let public_path = dir.path().join("id_ed25519.pub");
        let certificate_path = dir.path().join("id_ed25519-cert.pub");
        let key = key();
        let public = key.public_key().to_openssh().unwrap();
        let mut builder = Builder::new(vec![7; 16], key.public_key().key_data().clone(), 100, 200).unwrap();
        builder.cert_type(CertType::User).unwrap();
        builder.valid_principal("deploy").unwrap();
        let certificate = builder.sign(&key).unwrap().to_openssh().unwrap();
        std::fs::write(&public_path, &public).unwrap();
        std::fs::write(&certificate_path, &certificate).unwrap();
        assert!(public_half(&path).await.is_some());
        assert!(certificate_beside(&path).await.is_some());

        let padding = " ".repeat(MAX_IDENTITY_BYTES as usize);
        std::fs::write(&public_path, format!("{public}{padding}")).unwrap();
        std::fs::write(&certificate_path, format!("{certificate}{padding}")).unwrap();

        assert!(public_half(&path).await.is_none());
        assert!(certificate_beside(&path).await.is_none());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_fifo_or_device_is_refused_without_reading_it() {
        let dir = tempfile::tempdir().unwrap();
        let fifo = dir.path().join("identity");
        assert!(
            std::process::Command::new("mkfifo")
                .arg("-m")
                .arg("600")
                .arg(&fifo)
                .status()
                .unwrap()
                .success()
        );
        let (prompts, _) = prompts(Vec::new());

        for path in [fifo.as_path(), Path::new("/dev/zero")] {
            assert!(matches!(
                load(path, true, &mut None, &prompts).await,
                Err(SshFailure::IdentityFileUnreadable {
                    kind: io::ErrorKind::InvalidInput,
                    ..
                })
            ));
        }
        // Opening the FIFO alone also cannot wait if it replaces a regular file after metadata.
        let opened = open_identity(&fifo).unwrap();
        assert!(!opened.metadata().unwrap().is_file());
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

    // ssh-keygen keys whose P-256 scalar OpenSSH wrote in 31 bytes: in the clear, under aes256-ctr
    // and under chacha20-poly1305, the last two with PASSPHRASE and 2 KDF rounds.
    const SHORT_SCALAR_PUBLIC: &str = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBPtxmfAPZke6lSSBnPp8bOOeEr96gWuT4Gjw9n1AYPEs3cVPR/ayGF4Lj1/6Vd568nmCdUYGf4JwpPELyzgMcCo= probe";
    const SHORT_SCALAR_PLAIN: &str = "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQT7cZnwD2ZHupUkgZz6fGzjnhK/eoFr
k+Bo8PZ9QGDxLN3FT0f2shheC49f+lXeevJ5gnVGBn+CcKTxC8s4DHAqAAAAoAZrDEYGaw
xGAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBPtxmfAPZke6lSSB
nPp8bOOeEr96gWuT4Gjw9n1AYPEs3cVPR/ayGF4Lj1/6Vd568nmCdUYGf4JwpPELyzgMcC
oAAAAfePaBOK/gAb54F3hqBZlR2PwvlCCwvUHpQInJ8NgNPwAAAAVwcm9iZQECAwQ=
-----END OPENSSH PRIVATE KEY-----
";
    const SHORT_SCALAR_AES: &str = "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABD6Kt/OnH
lAo5qoe2kgnvL2AAAAAgAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
dHAyNTYAAABBBPtxmfAPZke6lSSBnPp8bOOeEr96gWuT4Gjw9n1AYPEs3cVPR/ayGF4Lj1
/6Vd568nmCdUYGf4JwpPELyzgMcCoAAACgGZFLziFb6aNQ4SRHeLlmawkYwI1k9/BVRg2z
WwNac8NVbHN2ZAd1mmL9nwBdes/q0aYJcqGjq23rMfCION36vACeox64Z7PTw36wwRF8Fc
M9yXztHcCHOI0MIemVpe6BLo70vZrN87L3ZiWIOX9yFPNg3EdrZ4LZEmxk0IGGkr2T8yuy
bibtg/rMKIYOrK5+z3DNOTrcWs3pZiu77FbnpQ==
-----END OPENSSH PRIVATE KEY-----
";
    const SHORT_SCALAR_CHACHA: &str = "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAAHWNoYWNoYTIwLXBvbHkxMzA1QG9wZW5zc2guY29tAAAABm
JjcnlwdAAAABgAAAAQnDudaw5DxR8Vu65tVb920QAAAAIAAAABAAAAaAAAABNlY2RzYS1z
aGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQT7cZnwD2ZHupUkgZz6fGzjnhK/eoFrk+
Bo8PZ9QGDxLN3FT0f2shheC49f+lXeevJ5gnVGBn+CcKTxC8s4DHAqAAAAoO9hChkRJ5br
xI7kgxOARBpnY4B6xAHwyvgVeY0/t6mNx6tRz6t8N5TcTQ8VmxS98ZY05Bpg4fhY0R/bUV
dQnPaBvrF2znk64+1b2HUQ/Muyop4NchkTWUcQ+rstWc34fEW6jt76hKiotGJUjMfShaeT
voxi+nT/5duuFMQCTpFqzmHtQbuQYwCk2ZcDJUWOrbEiRX52hcRBEqe/762QnSSdo4f2V1
+H7dbBJfrZ4r6n
-----END OPENSSH PRIVATE KEY-----
";
    const PASSPHRASE: &str = "correct horse battery";

    #[tokio::test]
    async fn a_p256_key_whose_scalar_openssh_wrote_short_opens_and_signs() {
        use russh::keys::signature::Verifier;

        let dir = tempfile::tempdir().unwrap();
        let expected = PublicKey::from_openssh(SHORT_SCALAR_PUBLIC).unwrap();
        for (name, text, passphrase) in [
            ("plain", SHORT_SCALAR_PLAIN, None),
            ("aes256-ctr", SHORT_SCALAR_AES, Some(PASSPHRASE)),
            ("chacha20-poly1305", SHORT_SCALAR_CHACHA, Some(PASSPHRASE)),
        ] {
            let refused = russh::keys::decode_secret_key(text, passphrase).unwrap_err();
            assert!(short_scalar::is_refusal(&refused), "{name}: {refused}");
            let path = dir.path().join(name);
            std::fs::write(&path, text).unwrap();
            let (prompts, prompter) = prompts(Vec::new());
            let mut stored = passphrase.map(SecretString::from);

            let key = load(&path, true, &mut stored, &prompts).await.unwrap().unwrap();

            assert_eq!(key.public_key().key_data(), expected.key_data(), "{name}");
            assert!(prompter.requests().is_empty(), "{name}");
            let signature = sign(&key, None, b"session").unwrap();
            expected.key_data().verify(b"session", &signature).unwrap();
        }
    }

    #[tokio::test]
    async fn a_wrong_passphrase_does_not_open_a_key_with_a_short_scalar() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("id_ecdsa");
        std::fs::write(&path, SHORT_SCALAR_AES).unwrap();
        let (prompts, prompter) = prompts(vec![typed(PASSPHRASE)]);
        let mut stored = Some(SecretString::from("wrong"));

        let key = load(&path, true, &mut stored, &prompts).await.unwrap().unwrap();

        assert_eq!(
            key.public_key().key_data(),
            PublicKey::from_openssh(SHORT_SCALAR_PUBLIC).unwrap().key_data()
        );
        assert_eq!(
            prompter.requests()[0].purpose,
            PromptPurpose::SshPassphrase {
                path: path.clone(),
                reason: PromptReason::Rejected,
            }
        );
    }
}
