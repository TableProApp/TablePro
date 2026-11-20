// Where an installed DBX keeps the key it encrypts its secrets under, looked up in DBX's own order: the key file an
// older DBX wrote, then the platform's store (`SecretCodec::resolve_platform_default` in
// crates/dbx-core/src/persistence/secret_codec.rs). A portable build's `data/.dbx/secret.key` and the
// `DBX_SECRET_KEY` variables belong to builds this import does not read.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use secrecy::ExposeSecret;
use secrecy::zeroize::Zeroizing;

use crate::{
    DataProtection, ForeignCredentialManager, ForeignHost, ForeignKeychain, ForeignPlatform, ForeignSecretService,
    KeychainRead, SecretScope,
};

// `KEYRING_SERVICE` and `KEYRING_USER`.
const SERVICE: &str = "com.dbx.app.secret-store.v1";
const ACCOUNT: &str = "local-data-encryption-key";
// The keyring crate names a Windows credential `<user>.<service>`, and files a Secret Service item under a `target`
// that DBX leaves at `default`.
const CREDENTIAL: &str = "local-data-encryption-key.com.dbx.app.secret-store.v1";
const TARGET: &str = "default";

// `default_key_path`, under the config folder on every platform.
const FOLDER: &str = "dbx";
const KEY_FILE: &str = "secret.key";
// Windows only: the store's key sealed to the user, kept in case a cleaner empties Credential Manager.
const MIRROR_FILE: &str = "secret-store.key.dpapi";
const MIRROR_MAGIC: &[u8] = b"DBXDPAPI1";

pub(super) type Key = Zeroizing<[u8; 32]>;

// The store DBX keeps its key in on this platform, as the host hands it over.
#[derive(Clone)]
pub(super) enum Store {
    Keychain(Arc<dyn ForeignKeychain>),
    CredentialManager {
        credentials: Arc<dyn ForeignCredentialManager>,
        protection: Option<Arc<dyn DataProtection>>,
    },
    SecretService(Arc<dyn ForeignSecretService>),
}

impl Store {
    pub(super) fn of(platform: ForeignPlatform, host: &dyn ForeignHost) -> Option<Self> {
        match platform {
            ForeignPlatform::MacOs => host.keychain().map(Self::Keychain),
            ForeignPlatform::Windows => host.credential_manager().map(|credentials| Self::CredentialManager {
                credentials,
                protection: host.data_protection(),
            }),
            ForeignPlatform::Linux => host.secret_service().map(Self::SecretService),
        }
    }

    fn read(&self, config_dir: &Path) -> Option<Key> {
        let found = match self {
            Self::Keychain(keychain) => keychain.read_password(SERVICE, Some(ACCOUNT)),
            Self::CredentialManager {
                credentials,
                protection,
            } => match credentials.read_generic(CREDENTIAL) {
                KeychainRead::NotFound => return read_mirror(&mirror_path(config_dir), protection.as_deref()),
                read => read,
            },
            Self::SecretService(service) => {
                match service.search(
                    SecretScope::Everywhere,
                    &[("target", TARGET), ("service", SERVICE), ("username", ACCOUNT)],
                ) {
                    // An item an older keyring crate wrote has no `target`.
                    KeychainRead::NotFound => service.search(
                        SecretScope::DefaultCollection,
                        &[("service", SERVICE), ("username", ACCOUNT)],
                    ),
                    read => read,
                }
            }
        };
        match found {
            KeychainRead::Found(material) => {
                let key = key_from(material.expose_secret());
                if key.is_none() {
                    tracing::warn!("DBX's key in the platform's store is not one it writes");
                }
                key
            }
            KeychainRead::NotFound => None,
            KeychainRead::Denied => {
                tracing::warn!("the platform's store did not hand over DBX's key");
                None
            }
        }
    }
}

// DBX takes a key file that reads, and falls through to the store when there is none or it does not read.
pub(super) fn find(config_dir: &Path, store: &Store) -> Option<Key> {
    let path = config_dir.join(FOLDER).join(KEY_FILE);
    if path.exists() {
        match crate::files::read_capped_string(&path).map(Zeroizing::new) {
            Ok(material) => match key_from(&material) {
                Some(key) => return Some(key),
                None => tracing::warn!("DBX's key file holds no key it writes"),
            },
            Err(error) => tracing::warn!(%error, "DBX's key file does not read"),
        }
    }
    store.read(config_dir)
}

fn mirror_path(config_dir: &Path) -> PathBuf {
    config_dir.join(FOLDER).join(MIRROR_FILE)
}

// The mirror is sealed with the service's name, in UTF-16, as its entropy.
fn read_mirror(path: &Path, protection: Option<&dyn DataProtection>) -> Option<Key> {
    let protection = protection?;
    let contents = crate::files::read_capped(path).ok()?;
    let sealed = contents.strip_prefix(MIRROR_MAGIC)?;
    let entropy: Vec<u8> = SERVICE.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let material = Zeroizing::new(protection.unprotect(sealed, &entropy)?);
    key_from(std::str::from_utf8(&material).ok()?)
}

// `SecretCodec::from_key_material`: DBX writes 32 bytes in unpadded URL-safe base64, and reads 64 hex digits too.
// Anything else it stretches with Argon2id, which only a key written by hand holds, so it reads as no key.
fn key_from(material: &str) -> Option<Key> {
    let material = material.trim();
    if let Ok(bytes) = URL_SAFE_NO_PAD.decode(material).map(Zeroizing::new)
        && let Ok(key) = <[u8; 32]>::try_from(bytes.as_slice())
    {
        return Some(Zeroizing::new(key));
    }
    if !material.is_ascii() || material.len() != 64 {
        return None;
    }
    let mut key = Zeroizing::new([0u8; 32]);
    for (index, byte) in key.iter_mut().enumerate() {
        *byte = u8::from_str_radix(material.get(index * 2..index * 2 + 2)?, 16).ok()?;
    }
    Some(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE64: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";

    fn bytes() -> [u8; 32] {
        std::array::from_fn(|index| u8::try_from(index).expect("a byte"))
    }

    #[test]
    fn key_material_reads_as_dbx_reads_it() {
        assert_eq!(key_from(BASE64).as_deref(), Some(&bytes()));
        assert_eq!(key_from(&format!(" {BASE64}\n")).as_deref(), Some(&bytes()));
        let hex = "000102030405060708090a0b0c0d0e0f101112131415161718191A1B1C1D1E1F";
        assert_eq!(key_from(hex).as_deref(), Some(&bytes()));

        // Each of these is a passphrase to DBX.
        assert_eq!(key_from(&format!("{BASE64}=")), None);
        assert_eq!(key_from("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHg"), None);
        assert_eq!(key_from("correct horse battery staple"), None);
        assert_eq!(key_from(&"zz".repeat(32)), None, "64 characters that are not hex");
        assert_eq!(key_from(""), None);
    }

    #[test]
    fn the_names_are_dbx_s() {
        assert_eq!(CREDENTIAL, format!("{ACCOUNT}.{SERVICE}"));
        assert_eq!(
            mirror_path(Path::new("/home/ada/AppData/Roaming")),
            Path::new("/home/ada/AppData/Roaming/dbx/secret-store.key.dpapi")
        );
    }
}
