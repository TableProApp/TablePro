use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use secrecy::{ExposeSecret, SecretString};
use serde::ser::{SerializeStruct, Serializer};
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use zeroize::Zeroizing;

use tablepro_core::{AuthMode, Environment, TlsMode};

use crate::connection_bundle_crypto::{
    CipherHeader, EnvelopeHeader, KdfHeader, SealedBundle, check_kdf_parameters, open, seal,
};
use crate::connection_organization::ConnectionOrganization;
use crate::connections::{SavedConnection, SavedSshConfig};

#[path = "connection_bundle_secret_transaction.rs"]
mod secret_transaction;

pub const BUNDLE_FORMAT: &str = "tablepro.connection-bundle";
pub const BUNDLE_VERSION: u32 = 2;
const LEGACY_BUNDLE_VERSION: u32 = 1;

pub const MAX_BUNDLE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_BUNDLE_CONNECTIONS: usize = 1_000;
/// Hops a bundled SSH chain may declare. Deserialising `jump` is
/// recursive, so without a cap the only defence is serde_json's default
/// 128-level nesting limit.
pub const MAX_SSH_HOPS: usize = 8;

const KIND_PLAINTEXT: &str = "plaintext";
const KIND_ENCRYPTED: &str = "encrypted";

/// Fields of a saved connection that a bundle carries.
pub const BUNDLE_INCLUDED_FIELDS: &[&str] = &[
    "id",
    "name",
    "driver_id",
    "host",
    "port",
    "socket_dir",
    "database",
    "username",
    "tls_mode",
    "tls_root_cert",
    "tls_client_cert",
    "tls_client_key",
    "read_only",
    "auth_mode",
    "environment",
    "ssh",
];

/// Fields a bundle deliberately drops. `use_tls` is the legacy boolean
/// that `tls_mode` replaced, so exporting it would let a bundle claim
/// `use_tls: true, tls_mode: disabled`. `last_opened_at` is local
/// telemetry that would tell a recipient when each production database
/// was last touched.
pub const BUNDLE_EXCLUDED_FIELDS: &[&str] = &["use_tls", "last_opened_at"];

#[derive(Debug, thiserror::Error)]
pub enum BundleError {
    #[error("this file is not a BookiE connection bundle")]
    NotABundle,
    #[error("this bundle was written by a newer version of BookiE (format version {0})")]
    UnsupportedVersion(u32),
    #[error("the bundle is not valid JSON")]
    Malformed,
    #[error("the bundle field {0} is missing or malformed")]
    Field(&'static str),
    #[error("a bundle without a passphrase cannot carry saved passwords")]
    PlaintextSecrets,
    #[error("the bundle is {got} bytes, over the {limit} byte limit")]
    TooLarge { got: usize, limit: usize },
    #[error("the bundle holds {got} connections, over the limit of {limit}")]
    TooManyConnections { got: usize, limit: usize },
    #[error("an SSH chain in the bundle is {got} hops deep, over the limit of {limit}")]
    SshChainTooDeep { got: usize, limit: usize },
    #[error("the bundle lists the same connection twice")]
    DuplicateConnectionId,
    #[error("the key-derivation settings in this bundle are outside the accepted range")]
    KdfParameters,
    #[error("The passphrase is wrong, or the file was changed after it was exported.")]
    DecryptionFailed,
    #[error("the bundle could not be encrypted")]
    EncryptionFailed,
    #[error("a passphrase is required")]
    EmptyPassphrase,
    #[error("the saved password for connection {0} could not be read")]
    SecretUnavailable(Uuid),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BundleConnection {
    pub id: Uuid,
    pub name: String,
    pub driver_id: String,
    pub host: String,
    pub port: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub socket_dir: Option<PathBuf>,
    pub database: String,
    pub username: String,
    pub tls_mode: TlsMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tls_root_cert: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tls_client_cert: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tls_client_key: Option<PathBuf>,
    pub read_only: bool,
    pub auth_mode: AuthMode,
    pub environment: Environment,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<SavedSshConfig>,
}

impl BundleConnection {
    pub fn from_saved(saved: &SavedConnection) -> Self {
        Self {
            id: saved.id,
            name: saved.name.clone(),
            driver_id: saved.driver_id.clone(),
            host: saved.host.clone(),
            port: saved.port,
            socket_dir: saved.socket_dir.clone(),
            database: saved.database.clone(),
            username: saved.username.clone(),
            tls_mode: saved.effective_tls_mode(),
            tls_root_cert: saved.tls_root_cert.clone(),
            tls_client_cert: saved.tls_client_cert.clone(),
            tls_client_key: saved.tls_client_key.clone(),
            read_only: saved.read_only,
            auth_mode: saved.auth_mode,
            environment: saved.environment,
            ssh: saved.ssh.clone(),
        }
    }

    pub fn to_saved(&self) -> SavedConnection {
        SavedConnection {
            id: self.id,
            name: self.name.clone(),
            driver_id: self.driver_id.clone(),
            host: self.host.clone(),
            port: self.port,
            socket_dir: self.socket_dir.clone(),
            database: self.database.clone(),
            username: self.username.clone(),
            use_tls: self.tls_mode.encrypts(),
            tls_mode: Some(self.tls_mode),
            tls_root_cert: self.tls_root_cert.clone(),
            tls_client_cert: self.tls_client_cert.clone(),
            tls_client_key: self.tls_client_key.clone(),
            read_only: self.read_only,
            auth_mode: self.auth_mode,
            environment: self.environment,
            ssh: self.ssh.clone(),
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BundleOrganization {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
}

/// Credentials for one connection. Never derives `Debug` or
/// `Serialize`: both are written by hand so a stray `{:?}` or a future
/// field cannot put a password in a log line or on disk unencrypted.
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BundleSecrets {
    pub connection_id: Uuid,
    #[serde(default)]
    db_password: Option<SecretString>,
    #[serde(default)]
    ssh_password: Option<SecretString>,
    #[serde(default)]
    ssh_passphrase: Option<SecretString>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    ssh_hops: Vec<BundleSshSecret>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BundleSshSecretKind {
    Password,
    Passphrase,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BundleSshSecret {
    hop_id: Uuid,
    credential_revision: u64,
    kind: BundleSshSecretKind,
    secret: SecretString,
}

impl BundleSshSecret {
    pub fn new(hop_id: Uuid, credential_revision: u64, kind: BundleSshSecretKind, secret: SecretString) -> Self {
        Self {
            hop_id,
            credential_revision,
            kind,
            secret,
        }
    }

    pub fn hop_id(&self) -> Uuid {
        self.hop_id
    }

    pub fn credential_revision(&self) -> u64 {
        self.credential_revision
    }

    pub fn kind(&self) -> BundleSshSecretKind {
        self.kind
    }

    pub fn secret(&self) -> &SecretString {
        &self.secret
    }
}

impl std::fmt::Debug for BundleSshSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BundleSshSecret")
            .field("hop_id", &self.hop_id)
            .field("credential_revision", &self.credential_revision)
            .field("kind", &self.kind)
            .finish_non_exhaustive()
    }
}

impl Serialize for BundleSshSecret {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut state = serializer.serialize_struct("BundleSshSecret", 4)?;
        state.serialize_field("hop_id", &self.hop_id)?;
        state.serialize_field("credential_revision", &self.credential_revision)?;
        state.serialize_field("kind", &self.kind)?;
        state.serialize_field("secret", &self.secret.expose_secret())?;
        state.end()
    }
}

impl BundleSecrets {
    pub fn new(
        connection_id: Uuid,
        db_password: Option<SecretString>,
        ssh_password: Option<SecretString>,
        ssh_passphrase: Option<SecretString>,
    ) -> Self {
        Self {
            connection_id,
            db_password,
            ssh_password,
            ssh_passphrase,
            ssh_hops: Vec::new(),
        }
    }

    pub fn set_ssh_hop_secrets(&mut self, secrets: Vec<BundleSshSecret>) {
        self.ssh_hops = secrets;
    }

    pub fn is_empty(&self) -> bool {
        self.db_password.is_none()
            && self.ssh_password.is_none()
            && self.ssh_passphrase.is_none()
            && self.ssh_hops.is_empty()
    }

    pub fn db_password(&self) -> Option<&SecretString> {
        self.db_password.as_ref()
    }

    pub fn ssh_password(&self) -> Option<&SecretString> {
        self.ssh_password.as_ref()
    }

    pub fn ssh_passphrase(&self) -> Option<&SecretString> {
        self.ssh_passphrase.as_ref()
    }

    pub fn ssh_hop_secrets(&self) -> &[BundleSshSecret] {
        &self.ssh_hops
    }
}

impl std::fmt::Debug for BundleSecrets {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BundleSecrets")
            .field("connection_id", &self.connection_id)
            .finish_non_exhaustive()
    }
}

impl Serialize for BundleSecrets {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let field_count = if self.ssh_hops.is_empty() { 4 } else { 5 };
        let mut state = serializer.serialize_struct("BundleSecrets", field_count)?;
        state.serialize_field("connection_id", &self.connection_id)?;
        state.serialize_field("db_password", &self.db_password.as_ref().map(|v| v.expose_secret()))?;
        state.serialize_field("ssh_password", &self.ssh_password.as_ref().map(|v| v.expose_secret()))?;
        state.serialize_field(
            "ssh_passphrase",
            &self.ssh_passphrase.as_ref().map(|v| v.expose_secret()),
        )?;
        if !self.ssh_hops.is_empty() {
            state.serialize_field("ssh_hops", &self.ssh_hops)?;
        }
        state.end()
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BundleBody {
    pub connections: Vec<BundleConnection>,
    #[serde(default)]
    pub organization: BTreeMap<Uuid, BundleOrganization>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub secrets: Vec<BundleSecrets>,
}

/// `#[serde(deny_unknown_fields)]` does not reach through
/// `#[serde(tag = ...)]` (serde#1358), so the payload keeps an explicit
/// `kind` string that `parse` matches by hand instead of an internally
/// tagged enum.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BundlePayload {
    kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    body: Option<BundleBody>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    kdf: Option<KdfHeader>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cipher: Option<CipherHeader>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ciphertext: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BundleDocument {
    format: String,
    version: u32,
    producer: String,
    exported_at: String,
    payload: BundlePayload,
}

/// Everything a bundle export needs that is not a policy decision.
pub struct BundleExport {
    pub producer: String,
    pub exported_at: String,
    pub connections: Vec<SavedConnection>,
    pub organization: Vec<(Uuid, ConnectionOrganization)>,
    pub secrets: Vec<BundleSecrets>,
}

impl BundleExport {
    fn body(&self, include_secrets: bool) -> BundleBody {
        BundleBody {
            connections: self.connections.iter().map(BundleConnection::from_saved).collect(),
            organization: self
                .organization
                .iter()
                .map(|(id, entry)| (*id, bundle_organization(entry)))
                .collect(),
            secrets: if include_secrets {
                self.secrets.clone()
            } else {
                Vec::new()
            },
        }
    }

    fn envelope(&self) -> EnvelopeHeader {
        EnvelopeHeader {
            version: BUNDLE_VERSION,
            producer: self.producer.clone(),
            exported_at: self.exported_at.clone(),
        }
    }
}

pub fn bundle_organization(entry: &ConnectionOrganization) -> BundleOrganization {
    BundleOrganization {
        group: entry.group.clone(),
        tags: entry.tags.clone(),
        color: entry.color.clone(),
    }
}

/// A bundle nobody has to type a passphrase for. It carries no
/// credentials at all: `secrets` is not populated on this path, and
/// `parse` rejects a plaintext payload that arrives with any.
pub fn export_plaintext(export: &BundleExport) -> Result<Vec<u8>, BundleError> {
    let payload = BundlePayload {
        kind: KIND_PLAINTEXT.to_owned(),
        body: Some(export.body(false)),
        kdf: None,
        cipher: None,
        ciphertext: None,
    };
    finish(export, payload)
}

pub fn export_encrypted(export: &BundleExport, passphrase: &str) -> Result<Vec<u8>, BundleError> {
    let body = export.body(true);
    let mut plaintext = Zeroizing::new(Vec::new());
    serde_json::to_writer(&mut *plaintext, &body).map_err(|_| BundleError::EncryptionFailed)?;
    let sealed = seal(&plaintext, passphrase, &export.envelope())?;
    drop(plaintext);
    let payload = BundlePayload {
        kind: KIND_ENCRYPTED.to_owned(),
        body: None,
        kdf: Some(sealed.kdf),
        cipher: Some(sealed.cipher),
        ciphertext: Some(BASE64.encode(&sealed.ciphertext)),
    };
    finish(export, payload)
}

fn finish(export: &BundleExport, payload: BundlePayload) -> Result<Vec<u8>, BundleError> {
    let document = BundleDocument {
        format: BUNDLE_FORMAT.to_owned(),
        version: BUNDLE_VERSION,
        producer: export.producer.clone(),
        exported_at: export.exported_at.clone(),
        payload,
    };
    let json = serde_json::to_vec_pretty(&document).map_err(|_| BundleError::Malformed)?;
    if json.len() > MAX_BUNDLE_BYTES {
        return Err(BundleError::TooLarge {
            got: json.len(),
            limit: MAX_BUNDLE_BYTES,
        });
    }
    Ok(json)
}

/// A parsed bundle whose body is either already available or still
/// waiting on a passphrase.
pub enum ParsedBundle {
    Plaintext(BundleBody),
    Encrypted(EncryptedBundle),
}

pub struct EncryptedBundle {
    envelope: EnvelopeHeader,
    sealed: SealedBundle,
}

impl std::fmt::Debug for EncryptedBundle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EncryptedBundle").finish_non_exhaustive()
    }
}

pub fn parse_bundle(bytes: &[u8]) -> Result<ParsedBundle, BundleError> {
    if bytes.len() > MAX_BUNDLE_BYTES {
        return Err(BundleError::TooLarge {
            got: bytes.len(),
            limit: MAX_BUNDLE_BYTES,
        });
    }
    let document: BundleDocument = serde_json::from_slice(bytes).map_err(|_| BundleError::Malformed)?;
    if document.format != BUNDLE_FORMAT {
        return Err(BundleError::NotABundle);
    }
    if document.version != BUNDLE_VERSION && document.version != LEGACY_BUNDLE_VERSION {
        return Err(BundleError::UnsupportedVersion(document.version));
    }
    let envelope = EnvelopeHeader {
        version: document.version,
        producer: document.producer,
        exported_at: document.exported_at,
    };
    match document.payload.kind.as_str() {
        KIND_PLAINTEXT => parse_plaintext(document.payload),
        KIND_ENCRYPTED => parse_encrypted(envelope, document.payload),
        _ => Err(BundleError::Field("payload.kind")),
    }
}

fn parse_plaintext(payload: BundlePayload) -> Result<ParsedBundle, BundleError> {
    if payload.kdf.is_some() || payload.cipher.is_some() || payload.ciphertext.is_some() {
        return Err(BundleError::Field("payload.body"));
    }
    let body = payload.body.ok_or(BundleError::Field("payload.body"))?;
    if !body.secrets.is_empty() {
        return Err(BundleError::PlaintextSecrets);
    }
    check_body_bounds(&body)?;
    Ok(ParsedBundle::Plaintext(body))
}

fn parse_encrypted(envelope: EnvelopeHeader, payload: BundlePayload) -> Result<ParsedBundle, BundleError> {
    if payload.body.is_some() {
        return Err(BundleError::Field("payload.body"));
    }
    let kdf = payload.kdf.ok_or(BundleError::Field("payload.kdf"))?;
    let cipher = payload.cipher.ok_or(BundleError::Field("payload.cipher"))?;
    let encoded = payload.ciphertext.ok_or(BundleError::Field("payload.ciphertext"))?;
    check_kdf_parameters(&kdf)?;
    let ciphertext = BASE64
        .decode(encoded)
        .map_err(|_| BundleError::Field("payload.ciphertext"))?;
    if ciphertext.len() > MAX_BUNDLE_BYTES {
        return Err(BundleError::TooLarge {
            got: ciphertext.len(),
            limit: MAX_BUNDLE_BYTES,
        });
    }
    Ok(ParsedBundle::Encrypted(EncryptedBundle {
        envelope,
        sealed: SealedBundle {
            kdf,
            cipher,
            ciphertext,
        },
    }))
}

impl EncryptedBundle {
    pub fn unlock(&self, passphrase: &str) -> Result<BundleBody, BundleError> {
        let plaintext = open(&self.sealed, passphrase, &self.envelope)?;
        let body: BundleBody = serde_json::from_slice(&plaintext).map_err(|_| BundleError::Malformed)?;
        drop(plaintext);
        if self.envelope.version == LEGACY_BUNDLE_VERSION
            && body.secrets.iter().any(|secrets| !secrets.ssh_hops.is_empty())
        {
            return Err(BundleError::Field("secrets.ssh_hops"));
        }
        check_body_bounds(&body)?;
        Ok(body)
    }
}

fn check_body_bounds(body: &BundleBody) -> Result<(), BundleError> {
    if body.connections.len() > MAX_BUNDLE_CONNECTIONS {
        return Err(BundleError::TooManyConnections {
            got: body.connections.len(),
            limit: MAX_BUNDLE_CONNECTIONS,
        });
    }
    for connection in &body.connections {
        check_ssh_depth(connection.ssh.as_ref())?;
        if let Some(ssh) = &connection.ssh {
            let mut hop_ids = HashSet::new();
            if ssh.flatten_hops().into_iter().any(|hop| !hop_ids.insert(hop.hop_id)) {
                return Err(BundleError::Field("connections.ssh.hop_id"));
            }
        }
    }
    let mut secret_connections = HashSet::new();
    for secrets in &body.secrets {
        if !secret_connections.insert(secrets.connection_id) {
            return Err(BundleError::Field("secrets.connection_id"));
        }
        let Some(connection) = body.connections.iter().find(|entry| entry.id == secrets.connection_id) else {
            return Err(BundleError::Field("secrets.connection_id"));
        };
        let hops = connection
            .ssh
            .as_ref()
            .map(SavedSshConfig::flatten_hops)
            .unwrap_or_default();
        let mut seen = HashSet::new();
        for secret in &secrets.ssh_hops {
            if !seen.insert((secret.hop_id, secret.credential_revision, secret.kind)) {
                return Err(BundleError::Field("secrets.ssh_hops"));
            }
            let Some(hop) = hops.iter().find(|hop| hop.hop_id == secret.hop_id) else {
                return Err(BundleError::Field("secrets.ssh_hops"));
            };
            let expected = matches!(
                (&hop.auth, secret.kind),
                (
                    crate::connections::SavedSshAuth::Password,
                    BundleSshSecretKind::Password
                ) | (
                    crate::connections::SavedSshAuth::PrivateKey {
                        has_passphrase: true,
                        ..
                    },
                    BundleSshSecretKind::Passphrase,
                )
            );
            if secret.credential_revision == 0
                || hop.credential_revision != secret.credential_revision
                || hop.agent
                || !expected
            {
                return Err(BundleError::Field("secrets.ssh_hops"));
            }
        }
    }
    Ok(())
}

pub fn check_ssh_depth(ssh: Option<&SavedSshConfig>) -> Result<(), BundleError> {
    let Some(root) = ssh else {
        return Ok(());
    };
    let mut hops = 0usize;
    let mut cursor = Some(root);
    while let Some(hop) = cursor {
        hops += 1;
        if hops > MAX_SSH_HOPS {
            return Err(BundleError::SshChainTooDeep {
                got: hops,
                limit: MAX_SSH_HOPS,
            });
        }
        cursor = hop.jump.as_deref();
    }
    Ok(())
}

/// Read every credential a bundle may carry for these connections.
/// Fails closed: a keyring that cannot answer for one connection aborts
/// the whole export, because a bundle quietly missing passwords the user
/// believed were in it is worse than no bundle.
pub async fn collect_bundle_secrets(connections: &[SavedConnection]) -> Result<Vec<BundleSecrets>, BundleError> {
    let mut collected = Vec::with_capacity(connections.len());
    for connection in connections {
        if let Some(secrets) = collect_connection_bundle_secrets(connection).await? {
            collected.push(secrets);
        }
    }
    Ok(collected)
}

async fn collect_connection_bundle_secrets(connection: &SavedConnection) -> Result<Option<BundleSecrets>, BundleError> {
    let id = connection.id;
    let mut secrets = BundleSecrets::new(
        id,
        crate::secrets::load_password(id)
            .await
            .map_err(|_| BundleError::SecretUnavailable(id))?,
        None,
        None,
    );
    if let Some(ssh) = &connection.ssh {
        collect_ssh_bundle_secrets(id, ssh, &mut secrets).await?;
    }
    Ok((!secrets.is_empty()).then_some(secrets))
}

async fn collect_ssh_bundle_secrets(
    connection_id: Uuid,
    ssh: &SavedSshConfig,
    secrets: &mut BundleSecrets,
) -> Result<(), BundleError> {
    let mut hop_secrets = Vec::new();
    for (index, hop) in ssh.flatten_hops().into_iter().enumerate() {
        if hop.agent {
            continue;
        }
        if hop.credential_revision == 0 {
            if index == 0 {
                collect_legacy_ssh_secret(connection_id, hop, secrets).await?;
            }
            continue;
        }
        if let Some(secret) = collect_versioned_ssh_secret(connection_id, hop).await? {
            hop_secrets.push(secret);
        }
    }
    secrets.set_ssh_hop_secrets(hop_secrets);
    Ok(())
}

async fn collect_legacy_ssh_secret(
    connection_id: Uuid,
    hop: &SavedSshConfig,
    secrets: &mut BundleSecrets,
) -> Result<(), BundleError> {
    match &hop.auth {
        crate::connections::SavedSshAuth::Password => {
            secrets.ssh_password = crate::secrets::load_ssh_password(connection_id)
                .await
                .map_err(|_| BundleError::SecretUnavailable(connection_id))?;
        }
        crate::connections::SavedSshAuth::PrivateKey {
            has_passphrase: true, ..
        } => {
            secrets.ssh_passphrase = crate::secrets::load_ssh_passphrase(connection_id)
                .await
                .map_err(|_| BundleError::SecretUnavailable(connection_id))?;
        }
        crate::connections::SavedSshAuth::PrivateKey {
            has_passphrase: false, ..
        } => {}
    }
    Ok(())
}

async fn collect_versioned_ssh_secret(
    connection_id: Uuid,
    hop: &SavedSshConfig,
) -> Result<Option<BundleSshSecret>, BundleError> {
    let (kind, secret) = match &hop.auth {
        crate::connections::SavedSshAuth::Password => (
            BundleSshSecretKind::Password,
            crate::secrets::load_ssh_hop_password(connection_id, hop.hop_id, hop.credential_revision)
                .await
                .map_err(|_| BundleError::SecretUnavailable(connection_id))?,
        ),
        crate::connections::SavedSshAuth::PrivateKey {
            has_passphrase: true, ..
        } => (
            BundleSshSecretKind::Passphrase,
            crate::secrets::load_ssh_hop_passphrase(connection_id, hop.hop_id, hop.credential_revision)
                .await
                .map_err(|_| BundleError::SecretUnavailable(connection_id))?,
        ),
        crate::connections::SavedSshAuth::PrivateKey {
            has_passphrase: false, ..
        } => return Ok(None),
    };
    let secret = secret.ok_or(BundleError::SecretUnavailable(connection_id))?;
    Ok(Some(BundleSshSecret::new(
        hop.hop_id,
        hop.credential_revision,
        kind,
        secret,
    )))
}

/// Write an imported connection's credentials under `target`. An
/// existing local secret is kept unless `replace_existing` is set, so an
/// import cannot silently swap a password the user still relies on.
pub async fn store_bundle_secrets(
    target: Uuid,
    secrets: &BundleSecrets,
    label: &str,
    replace_existing: bool,
) -> Result<(), crate::error::StorageError> {
    secret_transaction::store_bundle_secrets(target, secrets, label, replace_existing).await
}

pub(crate) fn should_write(existing: Option<SecretString>, replace_existing: bool) -> bool {
    existing.is_none() || replace_existing
}

/// Best-effort removal of the credentials an import wrote for a
/// connection it created. Used only on the rollback path for a `New`
/// item, never for one that existed before the import.
pub async fn forget_imported_secrets(target: Uuid) {
    for outcome in [
        crate::secrets::delete_password(target).await,
        crate::secrets::delete_ssh_password(target).await,
        crate::secrets::delete_ssh_passphrase(target).await,
    ] {
        if let Err(error) = outcome {
            tracing::warn!(error = %error, "removing a partially imported credential failed");
        }
    }
}

pub async fn forget_imported_bundle_secrets(target: Uuid, secrets: &BundleSecrets) {
    forget_imported_secrets(target).await;
    for secret in secrets.ssh_hop_secrets() {
        let result = match secret.kind {
            BundleSshSecretKind::Password => {
                crate::secrets::delete_ssh_hop_password(target, secret.hop_id, secret.credential_revision).await
            }
            BundleSshSecretKind::Passphrase => {
                crate::secrets::delete_ssh_hop_passphrase(target, secret.hop_id, secret.credential_revision).await
            }
        };
        if let Err(error) = result {
            tracing::warn!(error = %error, "removing a partially imported SSH hop credential failed");
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportDisposition {
    /// The id is free. Keep it, so a restored backup lines up with a
    /// restored keyring, organisation file, favourites and history.
    New,
    /// The id is taken by the same endpoint. Update the settings.
    UpdateInPlace,
    /// The id is taken by a different server. The audit journal,
    /// history rows and policy overrides already bind that id, so the
    /// incoming record gets a fresh one instead of repointing it.
    Remapped,
}

#[derive(Debug, Clone)]
pub struct ImportItem {
    pub disposition: ImportDisposition,
    pub source_id: Uuid,
    pub connection: SavedConnection,
    pub previous: Option<SavedConnection>,
    pub organization: Option<BundleOrganization>,
}

#[derive(Debug, Clone, Default)]
pub struct ImportPlan {
    pub items: Vec<ImportItem>,
}

pub fn plan_import(local: &[SavedConnection], body: &BundleBody) -> Result<ImportPlan, BundleError> {
    check_body_bounds(body)?;
    let mut seen: HashSet<Uuid> = HashSet::new();
    let mut items = Vec::with_capacity(body.connections.len());
    for incoming in &body.connections {
        if !seen.insert(incoming.id) {
            return Err(BundleError::DuplicateConnectionId);
        }
        items.push(plan_one(local, incoming, body.organization.get(&incoming.id)));
    }
    Ok(ImportPlan { items })
}

fn plan_one(
    local: &[SavedConnection],
    incoming: &BundleConnection,
    organization: Option<&BundleOrganization>,
) -> ImportItem {
    let organization = organization.cloned();
    let candidate = incoming.to_saved();
    let Some(existing) = local.iter().find(|saved| saved.id == incoming.id) else {
        return ImportItem {
            disposition: ImportDisposition::New,
            source_id: incoming.id,
            connection: candidate,
            previous: None,
            organization,
        };
    };
    if endpoint_key(existing) != endpoint_key(&candidate) {
        let mut remapped = candidate;
        remapped.id = Uuid::new_v4();
        return ImportItem {
            disposition: ImportDisposition::Remapped,
            source_id: incoming.id,
            connection: remapped,
            previous: None,
            organization,
        };
    }
    ImportItem {
        disposition: ImportDisposition::UpdateInPlace,
        source_id: incoming.id,
        connection: merge_without_downgrade(existing, candidate),
        previous: Some(existing.clone()),
        organization,
    }
}

/// Settings a bundle may change, with the safety ones ratcheted: an
/// import can tighten a local connection and never loosen it.
fn merge_without_downgrade(local: &SavedConnection, incoming: SavedConnection) -> SavedConnection {
    let tls_mode = stricter_tls(local.effective_tls_mode(), incoming.effective_tls_mode());
    SavedConnection {
        read_only: local.read_only || incoming.read_only,
        environment: higher_environment(local.environment, incoming.environment),
        use_tls: tls_mode.encrypts(),
        tls_mode: Some(tls_mode),
        last_opened_at: local.last_opened_at,
        ..incoming
    }
}

fn tls_rank(mode: TlsMode) -> u8 {
    match mode {
        TlsMode::Disabled => 0,
        TlsMode::Prefer => 1,
        TlsMode::Require => 2,
        TlsMode::VerifyCa => 3,
        TlsMode::VerifyFull => 4,
    }
}

fn stricter_tls(left: TlsMode, right: TlsMode) -> TlsMode {
    if tls_rank(right) > tls_rank(left) { right } else { left }
}

fn environment_rank(environment: Environment) -> u8 {
    match environment {
        Environment::Local => 0,
        Environment::Dev => 1,
        Environment::Staging => 2,
        Environment::Prod => 3,
    }
}

fn higher_environment(left: Environment, right: Environment) -> Environment {
    if environment_rank(right) > environment_rank(left) {
        right
    } else {
        left
    }
}

type EndpointKey = (String, String, u16, Option<PathBuf>, String, String, Vec<SshHopKey>);
type SshHopKey = (String, u16, String);

/// What makes two records the same server reached the same way. Name,
/// TLS mode, read-only, environment and auth mode are settings, not
/// identity, so a bundle may change them in place.
fn endpoint_key(saved: &SavedConnection) -> EndpointKey {
    let hops = saved
        .ssh
        .as_ref()
        .map(|root| {
            root.flatten_hops()
                .into_iter()
                .map(|hop| (hop.host.to_lowercase(), hop.port, hop.username.clone()))
                .collect()
        })
        .unwrap_or_default();
    (
        saved.driver_id.clone(),
        saved.host.to_lowercase(),
        saved.port,
        saved.socket_dir.clone(),
        saved.database.clone(),
        saved.username.clone(),
        hops,
    )
}

#[cfg(test)]
#[path = "connection_bundle_tests.rs"]
mod tests;

#[cfg(test)]
pub(crate) fn ssh_chain_for_test(depth: usize) -> SavedSshConfig {
    tests::ssh_chain(depth)
}
