use std::fs::File;
use std::io::Read;
use std::path::Path;

use secrecy::{ExposeSecret, SecretString};
use sha2::{Digest, Sha256};
use tablepro_storage::{SavedConnection, SavedSshAuth, load_password};

use crate::{TransportError, jump_hop_password_refused, loads_database_password};

const MAX_MATERIAL_FILE_BYTES: u64 = 1024 * 1024;

pub async fn session_material_digest(saved: &SavedConnection) -> Result<[u8; 32], TransportError> {
    let mut hasher = MaterialHasher::new();
    append_db_password(&mut hasher, saved).await?;
    append_ssh_material(&mut hasher, saved).await?;
    append_tls_ca(&mut hasher, saved)?;
    append_tls_client_identity(&mut hasher, saved)?;
    Ok(hasher.finish())
}

struct MaterialHasher(Sha256);

impl MaterialHasher {
    fn new() -> Self {
        Self(Sha256::new())
    }

    fn tag(&mut self, tag: &[u8], bytes: &[u8]) {
        self.0.update((tag.len() as u64).to_le_bytes());
        self.0.update(tag);
        self.0.update((bytes.len() as u64).to_le_bytes());
        self.0.update(bytes);
    }

    fn finish(self) -> [u8; 32] {
        self.0.finalize().into()
    }
}

async fn append_db_password(hasher: &mut MaterialHasher, saved: &SavedConnection) -> Result<(), TransportError> {
    let password = if loads_database_password(saved) {
        load_password(saved.id)
            .await
            .map_err(|error| crate::secret_error("load database password", error))?
            .unwrap_or_else(|| SecretString::new(String::new().into()))
    } else {
        SecretString::new(String::new().into())
    };
    hasher.tag(b"db_password", password.expose_secret().as_bytes());
    Ok(())
}

async fn append_ssh_material(hasher: &mut MaterialHasher, saved: &SavedConnection) -> Result<(), TransportError> {
    let Some(ssh) = &saved.ssh else {
        return Ok(());
    };
    for (index, hop) in ssh.flatten_hops().into_iter().enumerate() {
        hasher.tag(b"ssh_hop_id", hop.hop_id.as_bytes());
        hasher.tag(b"ssh_credential_revision", &hop.credential_revision.to_le_bytes());
        if hop.agent {
            hasher.tag(b"ssh_auth", b"agent");
            continue;
        }
        match &hop.auth {
            SavedSshAuth::Password => {
                if hop.credential_revision == 0 && index > 0 {
                    return Err(jump_hop_password_refused(index));
                }
                let password = crate::saved_ssh_password(saved.id, hop, index).await?;
                hasher.tag(b"ssh_password", password.expose_secret().as_bytes());
            }
            SavedSshAuth::PrivateKey { path, has_passphrase } => {
                hasher.tag(b"ssh_key", &read_material_file(path)?);
                if *has_passphrase {
                    match crate::saved_ssh_passphrase(saved.id, hop, index, *has_passphrase).await? {
                        Some(passphrase) => hasher.tag(b"ssh_passphrase", passphrase.expose_secret().as_bytes()),
                        None => hasher.tag(b"ssh_passphrase", &[]),
                    }
                }
            }
        }
    }
    Ok(())
}

fn append_tls_ca(hasher: &mut MaterialHasher, saved: &SavedConnection) -> Result<(), TransportError> {
    let Some(path) = saved.tls_root_cert.as_deref() else {
        return Ok(());
    };
    hasher.tag(b"tls_ca", &read_material_file(path)?);
    Ok(())
}

fn append_tls_client_identity(hasher: &mut MaterialHasher, saved: &SavedConnection) -> Result<(), TransportError> {
    match (saved.tls_client_cert.as_deref(), saved.tls_client_key.as_deref()) {
        (None, None) => Ok(()),
        (Some(cert), Some(key)) => {
            hasher.tag(b"tls_client_cert", &read_material_file(cert)?);
            hasher.tag(b"tls_client_key", &read_material_file(key)?);
            Ok(())
        }
        _ => Err(TransportError::Driver(tablepro_core::DriverError::Unsupported(
            "TLS client authentication requires both a certificate and a private key".into(),
        ))),
    }
}

fn read_material_file(path: &Path) -> Result<Vec<u8>, TransportError> {
    let file =
        File::open(path).map_err(|error| TransportError::Secret(format!("cannot read {}: {error}", path.display())))?;
    let metadata = file
        .metadata()
        .map_err(|error| TransportError::Secret(format!("cannot inspect {}: {error}", path.display())))?;
    if !metadata.is_file() {
        return Err(TransportError::Secret(format!(
            "{} is not a regular file",
            path.display()
        )));
    }
    if metadata.len() > MAX_MATERIAL_FILE_BYTES {
        return Err(TransportError::Secret(format!(
            "{} exceeds the {}-byte material limit",
            path.display(),
            MAX_MATERIAL_FILE_BYTES
        )));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_MATERIAL_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| TransportError::Secret(format!("cannot read {}: {error}", path.display())))?;
    if bytes.len() as u64 > MAX_MATERIAL_FILE_BYTES {
        return Err(TransportError::Secret(format!(
            "{} exceeds the {}-byte material limit",
            path.display(),
            MAX_MATERIAL_FILE_BYTES
        )));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    use tablepro_core::{AuthMode, Environment, TlsMode};
    use tablepro_storage::{SavedSshAuth, SavedSshConfig};
    use uuid::Uuid;

    fn sqlite_saved() -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Local".into(),
            driver_id: "sqlite".into(),
            host: String::new(),
            port: 0,
            socket_dir: None,
            database: ":memory:".into(),
            username: String::new(),
            use_tls: false,
            tls_mode: Some(TlsMode::Disabled),
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            read_only: true,
            auth_mode: AuthMode::Password,
            environment: Environment::Local,
            ssh: None,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }

    fn key_hop(path: PathBuf) -> SavedSshConfig {
        SavedSshConfig {
            hop_id: uuid::Uuid::new_v4(),
            credential_revision: 0,
            host: "bastion.example".into(),
            port: 22,
            username: "jump".into(),
            auth: SavedSshAuth::PrivateKey {
                path,
                has_passphrase: false,
            },
            jump: None,
            client: Default::default(),
            agent: false,
        }
    }

    #[test]
    fn length_prefix_avoids_tag_ambiguity() {
        let mut left = MaterialHasher::new();
        left.tag(b"ab", b"c");
        left.tag(b"d", b"e");
        let mut right = MaterialHasher::new();
        right.tag(b"a", b"bc");
        right.tag(b"d", b"e");
        assert_ne!(left.finish(), right.finish());
    }

    #[test]
    fn password_bytes_change_the_digest() {
        let mut old = MaterialHasher::new();
        old.tag(b"db_password", b"old");
        let mut new = MaterialHasher::new();
        new.tag(b"db_password", b"new");
        assert_ne!(old.finish(), new.finish());
    }

    #[tokio::test]
    async fn sqlite_digest_is_stable_without_secret_service() {
        let saved = sqlite_saved();
        let first = session_material_digest(&saved).await.expect("sqlite digest");
        let second = session_material_digest(&saved).await.expect("sqlite digest");
        assert_eq!(first, second);
    }

    #[tokio::test]
    async fn rotating_tls_ca_bytes_changes_the_digest() {
        let directory = tempfile::tempdir().unwrap();
        let ca = directory.path().join("ca.pem");
        std::fs::write(&ca, b"old-ca").unwrap();
        let mut saved = sqlite_saved();
        saved.tls_root_cert = Some(ca.clone());

        let first = session_material_digest(&saved).await.expect("digest with old ca");
        std::fs::write(&ca, b"new-ca").unwrap();
        let second = session_material_digest(&saved).await.expect("digest with new ca");
        assert_ne!(first, second);
    }

    #[tokio::test]
    async fn rotating_tls_client_certificate_or_key_changes_the_digest() {
        let directory = tempfile::tempdir().unwrap();
        let cert = directory.path().join("client.crt");
        let key = directory.path().join("client.key");
        std::fs::write(&cert, b"old-certificate").unwrap();
        std::fs::write(&key, b"old-private-key").unwrap();
        let mut saved = sqlite_saved();
        saved.tls_client_cert = Some(cert.clone());
        saved.tls_client_key = Some(key.clone());

        let initial = session_material_digest(&saved).await.expect("initial identity digest");
        std::fs::write(&cert, b"rotated-certificate").unwrap();
        let rotated_cert = session_material_digest(&saved)
            .await
            .expect("rotated certificate digest");
        assert_ne!(initial, rotated_cert);

        std::fs::write(&cert, b"old-certificate").unwrap();
        std::fs::write(&key, b"rotated-private-key").unwrap();
        let rotated_key = session_material_digest(&saved).await.expect("rotated key digest");
        assert_ne!(initial, rotated_key);
    }

    #[tokio::test]
    async fn a_missing_tls_client_identity_file_fails_closed() {
        let directory = tempfile::tempdir().unwrap();
        let cert = directory.path().join("client.crt");
        let key = directory.path().join("client.key");
        std::fs::write(&cert, b"certificate").unwrap();
        let mut saved = sqlite_saved();
        saved.tls_client_cert = Some(cert);
        saved.tls_client_key = Some(key);

        let error = session_material_digest(&saved)
            .await
            .expect_err("missing client key must fail before cache reuse");
        assert!(matches!(error, TransportError::Secret(_)));
    }

    #[tokio::test]
    async fn rotating_ssh_key_bytes_changes_the_digest() {
        let directory = tempfile::tempdir().unwrap();
        let key = directory.path().join("id_ed25519");
        std::fs::write(&key, b"old-key").unwrap();
        let mut saved = sqlite_saved();
        saved.ssh = Some(key_hop(key.clone()));

        let first = session_material_digest(&saved).await.expect("digest with old key");
        std::fs::write(&key, b"new-key").unwrap();
        let second = session_material_digest(&saved).await.expect("digest with new key");
        assert_ne!(first, second);
    }

    #[tokio::test]
    async fn missing_tls_ca_file_fails_closed() {
        let mut saved = sqlite_saved();
        saved.tls_root_cert = Some(PathBuf::from("/no/such/tablepro-ca.pem"));
        let error = session_material_digest(&saved).await.expect_err("missing ca must fail");
        assert!(matches!(error, TransportError::Secret(_)));
    }

    #[tokio::test]
    async fn missing_ssh_key_file_fails_closed() {
        let mut saved = sqlite_saved();
        saved.ssh = Some(key_hop(PathBuf::from("/no/such/id_ed25519")));
        let error = session_material_digest(&saved)
            .await
            .expect_err("missing ssh key must fail");
        assert!(matches!(error, TransportError::Secret(_)));
    }

    #[tokio::test]
    async fn oversized_material_file_fails_closed() {
        let directory = tempfile::tempdir().unwrap();
        let ca = directory.path().join("ca.pem");
        std::fs::write(&ca, vec![b'x'; (MAX_MATERIAL_FILE_BYTES as usize) + 1]).unwrap();
        let mut saved = sqlite_saved();
        saved.tls_root_cert = Some(ca);
        let error = session_material_digest(&saved)
            .await
            .expect_err("oversized ca must fail");
        assert!(error.to_string().contains("material limit"));
    }

    #[test]
    fn the_material_file_limit_is_one_mebibyte() {
        assert_eq!(MAX_MATERIAL_FILE_BYTES, 1_048_576);
    }

    #[tokio::test]
    async fn material_file_exactly_at_the_limit_is_accepted() {
        let directory = tempfile::tempdir().unwrap();
        let ca = directory.path().join("ca.pem");
        std::fs::write(&ca, vec![b'x'; MAX_MATERIAL_FILE_BYTES as usize]).unwrap();
        let mut saved = sqlite_saved();
        saved.tls_root_cert = Some(ca);
        session_material_digest(&saved)
            .await
            .expect("a file exactly at the limit must be accepted");
    }

    #[tokio::test]
    async fn hop_zero_password_auth_is_not_refused_by_the_jump_guard() {
        let mut saved = sqlite_saved();
        saved.ssh = Some(SavedSshConfig {
            auth: SavedSshAuth::Password,
            ..key_hop(PathBuf::from("/unused"))
        });
        if let Err(error) = session_material_digest(&saved).await {
            let message = error.to_string();
            assert!(
                !message.contains("uses password auth"),
                "hop 0 must not be refused by the jump-hop guard: {message}"
            );
        }
    }

    #[tokio::test]
    async fn jump_hop_password_auth_fails_closed() {
        let directory = tempfile::tempdir().unwrap();
        let key = directory.path().join("id_ed25519");
        std::fs::write(&key, b"hop0").unwrap();
        let mut saved = sqlite_saved();
        saved.ssh = Some(SavedSshConfig {
            jump: Some(Box::new(SavedSshConfig {
                auth: SavedSshAuth::Password,
                ..key_hop(key.clone())
            })),
            ..key_hop(key)
        });
        let error = session_material_digest(&saved)
            .await
            .expect_err("jump password must fail");
        let message = error.to_string();
        assert!(message.contains("hop 1"), "unexpected error: {message}");
        assert!(
            !message.contains("not in keyring"),
            "must fail before the keyring: {message}"
        );
    }

    #[tokio::test]
    async fn changing_a_hop_credential_revision_changes_session_material() {
        let directory = tempfile::tempdir().unwrap();
        let key = directory.path().join("id_ed25519");
        std::fs::write(&key, b"same key material").unwrap();
        let mut saved = sqlite_saved();
        saved.ssh = Some(key_hop(key));
        let first = session_material_digest(&saved).await.unwrap();
        saved.ssh.as_mut().unwrap().credential_revision = 1;
        let second = session_material_digest(&saved).await.unwrap();
        assert_ne!(first, second);
    }
}
