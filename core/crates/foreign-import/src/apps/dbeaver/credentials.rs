use std::collections::BTreeMap;
use std::path::Path;

use aes::cipher::block_padding::Pkcs7;
use aes::cipher::{BlockDecryptMut, KeyIvInit};
use secrecy::SecretString;
use serde_json::Value;

use crate::ForeignCredentials;

// DBeaver encrypts every project's credentials with this one key, on every platform.
const KEY: [u8; 16] = [
    0xBA, 0xBB, 0x4A, 0x9F, 0x77, 0x4A, 0xB8, 0x53, 0xC9, 0x6C, 0x2D, 0x65, 0x3D, 0xFE, 0x54, 0x4A,
];
const IV_LENGTH: usize = 16;

type Decryptor = cbc::Decryptor<aes::Aes128>;

// Holds decrypted passwords, so it is never logged.
pub(super) struct Credentials {
    entries: BTreeMap<String, Value>,
}

impl Credentials {
    pub(super) fn load(path: &Path) -> Self {
        let entries = crate::files::read_capped(path)
            .ok()
            .and_then(|data| decrypt(&data))
            .and_then(|plain| serde_json::from_slice::<BTreeMap<String, Value>>(&plain).ok())
            .map(|mut entries| {
                entries.retain(|_, entry| entry.is_object());
                entries
            })
            .unwrap_or_default();
        Self { entries }
    }

    pub(super) fn username(&self, id: &str) -> Option<&str> {
        self.entries.get(id)?.get("#connection")?.get("user")?.as_str()
    }

    pub(super) fn secrets(&self, id: &str) -> Option<ForeignCredentials> {
        let entry = self.entries.get(id)?;
        let password = entry
            .get("#connection")
            .and_then(|block| block.get("password"))
            .and_then(Value::as_str);
        let ssh_password = entry
            .get("ssh_tunnel")
            .and_then(|block| block.get("password"))
            .and_then(Value::as_str);
        if password.is_none() && ssh_password.is_none() {
            return None;
        }
        Some(ForeignCredentials {
            password: password.map(secret),
            ssh_password: ssh_password.map(secret),
            key_passphrase: None,
        })
    }
}

fn secret(value: &str) -> SecretString {
    SecretString::from(value.to_owned())
}

// The file is a 16-byte IV followed by AES-128-CBC with PKCS#7 padding.
pub(super) fn decrypt(data: &[u8]) -> Option<Vec<u8>> {
    if data.len() <= IV_LENGTH {
        return None;
    }
    let (iv, ciphertext) = data.split_at(IV_LENGTH);
    let decryptor = Decryptor::new_from_slices(&KEY, iv).ok()?;
    match decryptor.decrypt_padded_vec_mut::<Pkcs7>(ciphertext) {
        Ok(plain) => Some(plain),
        Err(_) => {
            tracing::warn!("could not decrypt a DBeaver credentials file");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use aes::cipher::BlockEncryptMut;
    use secrecy::ExposeSecret;

    use super::*;

    fn encrypt(plain: &[u8], iv: [u8; 16]) -> Vec<u8> {
        let ciphertext =
            cbc::Encryptor::<aes::Aes128>::new(&KEY.into(), &iv.into()).encrypt_padded_vec_mut::<Pkcs7>(plain);
        [iv.as_slice(), &ciphertext].concat()
    }

    #[test]
    fn a_file_encrypted_with_the_fixed_key_decrypts() {
        let file = encrypt(br#"{"a":1}"#, [7; 16]);
        assert_eq!(decrypt(&file).as_deref(), Some(br#"{"a":1}"#.as_slice()));
    }

    #[test]
    fn a_short_truncated_or_tampered_file_decrypts_to_nothing() {
        let file = encrypt(b"0123456789abcdef0123", [1; 16]);
        assert_eq!(decrypt(&file[..16]), None);
        assert_eq!(decrypt(&file[..file.len() - 1]), None);
        let mut tampered = file.clone();
        if let Some(last) = tampered.last_mut() {
            *last ^= 0xFF;
        }
        assert_eq!(decrypt(&tampered), None);
    }

    #[test]
    fn every_fixture_credentials_file_matches_its_plain_copy() {
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/dbeaver");
        let pairs = [
            "macos/Library/DBeaverData/workspace6/General/.dbeaver/credentials-config",
            "linux/.local/share/DBeaverData/workspace6/General/.dbeaver/credentials-config",
            "linux/.local/share/DBeaverData/workspace6/General/.dbeaver/credentials-config-2",
            "windows/AppData/Roaming/DBeaverData/workspace6/General/.dbeaver/credentials-config",
        ];
        for stem in pairs {
            let encrypted = fs::read(fixtures.join(format!("{stem}.json"))).expect("an encrypted file");
            let plain = fs::read(fixtures.join(format!("{stem}.plain.json"))).expect("a plain copy");
            assert_eq!(decrypt(&encrypted), Some(plain), "{stem}");
        }
    }

    #[test]
    fn the_username_and_passwords_come_from_their_own_blocks() {
        let directory = tempfile::tempdir().expect("a temp dir");
        let path = directory.path().join("credentials-config.json");
        let plain = br##"{
            "both": {"#connection": {"user": "u", "password": "p"}, "ssh_tunnel": {"password": "t"}},
            "user-only": {"#connection": {"user": "u"}},
            "empty-password": {"#connection": {"password": ""}},
            "not-an-object": "x"
        }"##;
        fs::write(&path, encrypt(plain, [3; 16])).expect("a file");
        let credentials = Credentials::load(&path);

        let both = credentials.secrets("both").expect("secrets");
        assert_eq!(both.password.as_ref().map(|s| s.expose_secret()), Some("p"));
        assert_eq!(both.ssh_password.as_ref().map(|s| s.expose_secret()), Some("t"));
        assert_eq!(credentials.username("both"), Some("u"));
        assert!(credentials.secrets("user-only").is_none());
        assert_eq!(credentials.username("user-only"), Some("u"));
        let empty = credentials.secrets("empty-password").expect("secrets");
        assert_eq!(empty.password.as_ref().map(|s| s.expose_secret()), Some(""));
        assert!(credentials.secrets("not-an-object").is_none());
        assert!(credentials.secrets("missing").is_none());
    }

    #[test]
    fn a_missing_or_undecryptable_file_reads_as_empty() {
        let directory = tempfile::tempdir().expect("a temp dir");
        let path = directory.path().join("credentials-config.json");
        assert!(Credentials::load(&path).entries.is_empty());
        fs::write(&path, br##"{"plain":{"#connection":{"password":"p"}}}"##).expect("a file");
        assert!(Credentials::load(&path).entries.is_empty());
    }
}
