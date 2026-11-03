// The IDE names a secret `IntelliJ Platform <subsystem> \u{2014} <key>`: subsystem `DB` keyed by the data
// source uuid, `SshConfigPassword` and `SshConfigPassphrase` keyed by `<host>:<port> <ssh config id>`.
// The system keychain holds it by default; the "In KeePass" setting writes `c.kdbx` instead, so the
// keychain is asked first and the KeePass file is the fallback.

use std::collections::HashMap;
use std::io::ErrorKind;
use std::path::PathBuf;
use std::sync::Arc;

use aes::Aes128;
use aes::cipher::block_padding::Pkcs7;
use aes::cipher::{BlockDecryptMut, KeyIvInit};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use secrecy::{ExposeSecret, SecretString};

use super::kdbx::{self, KdbxEntry};
use crate::{ForeignKeychain, ForeignPlatform, KeychainRead};

const BUILT_IN_KEY: &[u8; 16] = b"Proxy Config Sec";
const BUILT_IN: &str = "BUILT_IN";
const CRYPT_32: &str = "CRYPT_32";

#[derive(Debug, Clone)]
pub(crate) enum Lookup {
    Found(SecretString),
    NotFound,
    // The user refused the keychain, or the KeePass main key is one this platform cannot open.
    Stopped,
}

enum MainKey {
    Key(Vec<u8>),
    Locked,
    Unreadable,
}

pub(crate) struct CredentialStore {
    config_dir: PathBuf,
    platform: ForeignPlatform,
    keychain: Option<Arc<dyn ForeignKeychain>>,
    entries: Option<HashMap<String, KdbxEntry>>,
    loaded: bool,
    locked: bool,
}

impl CredentialStore {
    pub(crate) fn new(
        config_dir: PathBuf,
        platform: ForeignPlatform,
        keychain: Option<Arc<dyn ForeignKeychain>>,
    ) -> Self {
        Self {
            config_dir,
            platform,
            keychain,
            entries: None,
            loaded: false,
            locked: false,
        }
    }

    pub(crate) fn service_name(uuid: &str) -> String {
        format!("IntelliJ Platform DB \u{2014} {uuid}")
    }

    pub(crate) fn ssh_password_service_name(host: &str, port: u16, config_id: &str) -> String {
        format!("IntelliJ Platform SshConfigPassword \u{2014} {host}:{port} {config_id}")
    }

    pub(crate) fn ssh_passphrase_service_name(host: &str, port: u16, config_id: &str) -> String {
        format!("IntelliJ Platform SshConfigPassphrase \u{2014} {host}:{port} {config_id}")
    }

    pub(crate) fn password(&mut self, uuid: &str) -> Lookup {
        self.secret(&Self::service_name(uuid))
    }

    pub(crate) fn ssh_password(&mut self, host: &str, port: u16, config_id: &str) -> Lookup {
        self.secret(&Self::ssh_password_service_name(host, port, config_id))
    }

    pub(crate) fn ssh_key_passphrase(&mut self, host: &str, port: u16, config_id: &str) -> Lookup {
        self.secret(&Self::ssh_passphrase_service_name(host, port, config_id))
    }

    pub(crate) fn kdbx_loaded(&self) -> bool {
        self.entries.is_some()
    }

    fn secret(&mut self, service: &str) -> Lookup {
        if let Some(keychain) = &self.keychain {
            match keychain.read_password(service, None) {
                KeychainRead::Found(value) => return Lookup::Found(value),
                KeychainRead::Denied => return Lookup::Stopped,
                KeychainRead::NotFound => {}
            }
        }
        let found = self
            .load_entries()
            .and_then(|entries| entries.get(service))
            .filter(|entry| !entry.password.expose_secret().is_empty())
            .map(|entry| entry.password.clone());
        match found {
            Some(password) => Lookup::Found(password),
            None if self.locked => Lookup::Stopped,
            None => Lookup::NotFound,
        }
    }

    fn load_entries(&mut self) -> Option<&HashMap<String, KdbxEntry>> {
        if !self.loaded {
            self.loaded = true;
            self.entries = self.read_entries();
        }
        self.entries.as_ref()
    }

    fn read_entries(&mut self) -> Option<HashMap<String, KdbxEntry>> {
        let path = self.config_dir.join("c.kdbx");
        if !path.exists() {
            return None;
        }
        let file = crate::files::read_capped(&path).ok()?;
        let main_key = self.load_main_key()?;
        match kdbx::read(&file, &main_key) {
            Ok(entries) => {
                let mut by_title = HashMap::with_capacity(entries.len());
                for entry in entries {
                    by_title.entry(entry.title.clone()).or_insert(entry);
                }
                Some(by_title)
            }
            Err(error) => {
                tracing::warn!(?error, "could not read the IDE's KeePass file");
                None
            }
        }
    }

    fn load_main_key(&mut self) -> Option<Vec<u8>> {
        let main_key = match crate::files::read_capped(self.config_dir.join("c.pwd")) {
            Ok(data) => {
                let (encryption, blob) = parse_main_key_file(std::str::from_utf8(&data).ok()?)?;
                decrypt_main_key(&encryption, &blob)
            }
            // The IDE reads the older `pdb.pwd`, raw bytes rather than YAML, only when `c.pwd` is missing.
            Err(error) if error.kind() == ErrorKind::NotFound => {
                let blob = crate::files::read_capped(self.config_dir.join("pdb.pwd")).ok()?;
                decrypt_main_key(legacy_encryption(self.platform), &blob)
            }
            Err(_) => return None,
        };
        match main_key {
            MainKey::Key(key) => Some(key),
            MainKey::Locked => {
                tracing::warn!("the IDE's KeePass main key is not under its built-in key");
                self.locked = true;
                None
            }
            MainKey::Unreadable => None,
        }
    }
}

fn legacy_encryption(platform: ForeignPlatform) -> &'static str {
    match platform {
        ForeignPlatform::Windows => CRYPT_32,
        ForeignPlatform::MacOs | ForeignPlatform::Linux => BUILT_IN,
    }
}

// Every main key is decrypted here. CRYPT_32 is BUILT_IN wrapped in the Windows data protection API.
fn decrypt_main_key(encryption: &str, blob: &[u8]) -> MainKey {
    if encryption != BUILT_IN {
        return MainKey::Locked;
    }
    decrypt_built_in(blob).map_or(MainKey::Unreadable, MainKey::Key)
}

fn decrypt_built_in(blob: &[u8]) -> Option<Vec<u8>> {
    let iv_length = usize::try_from(u32::from_be_bytes(blob.get(..4)?.try_into().ok()?)).ok()?;
    if iv_length != 16 || blob.len() <= 4 + iv_length {
        return None;
    }
    let (iv, ciphertext) = blob.get(4..)?.split_at(iv_length);
    cbc::Decryptor::<Aes128>::new_from_slices(BUILT_IN_KEY, iv)
        .ok()?
        .decrypt_padded_vec_mut::<Pkcs7>(ciphertext)
        .ok()
}

// `c.pwd` is YAML with `encryption:` and a `value: !!binary` that may continue on indented lines.
fn parse_main_key_file(text: &str) -> Option<(String, Vec<u8>)> {
    let mut encryption = BUILT_IN.to_owned();
    let mut parts: Vec<String> = Vec::new();
    let mut capturing = false;
    for line in text.split(is_newline) {
        if capturing {
            if line.starts_with([' ', '\t']) {
                parts.push(line.to_owned());
                continue;
            }
            capturing = false;
        }
        if let Some((_, rest)) = line.split_once("encryption:") {
            rest.trim().clone_into(&mut encryption);
        } else if let Some((_, rest)) = line.split_once("value:") {
            let rest = rest.replace("!!binary", "");
            let rest = rest.trim();
            if matches!(rest, "" | "|" | "|-" | ">") {
                capturing = true;
            } else {
                parts.push(rest.to_owned());
            }
        }
    }
    let base64: String = parts
        .concat()
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || matches!(character, '+' | '/' | '='))
        .collect();
    let blob = STANDARD.decode(base64).ok()?;
    Some((encryption, blob))
}

fn is_newline(character: char) -> bool {
    matches!(
        character,
        '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

#[cfg(test)]
mod tests {
    use std::fs;

    use std::path::Path;
    use std::sync::Mutex;

    use super::super::test_kdbx::{self, KdbxOptions, TestEntry};
    use super::*;

    struct Keychain {
        secrets: HashMap<String, KeychainRead>,
        reads: Mutex<Vec<(String, Option<String>)>>,
    }

    impl ForeignKeychain for Keychain {
        fn read_password(&self, service: &str, account: Option<&str>) -> KeychainRead {
            self.reads
                .lock()
                .expect("a lock")
                .push((service.to_owned(), account.map(str::to_owned)));
            self.secrets.get(service).cloned().unwrap_or(KeychainRead::NotFound)
        }
    }

    fn keychain(secrets: Vec<(String, KeychainRead)>) -> Arc<Keychain> {
        Arc::new(Keychain {
            secrets: secrets.into_iter().collect(),
            reads: Mutex::new(Vec::new()),
        })
    }

    fn write_kdbx(dir: &Path, main_key: &[u8], title: &str, password: &str) {
        let file = test_kdbx::make_kdbx(
            main_key,
            &[TestEntry::new(title, "u", password)],
            KdbxOptions::default(),
        );
        fs::write(dir.join("c.kdbx"), file).expect("c.kdbx");
    }

    fn store(dir: &Path, platform: ForeignPlatform) -> CredentialStore {
        CredentialStore::new(dir.to_path_buf(), platform, None)
    }

    fn found(lookup: Lookup) -> String {
        match lookup {
            Lookup::Found(value) => value.expose_secret().to_owned(),
            other => panic!("expected a secret, got {other:?}"),
        }
    }

    #[test]
    fn the_service_name_uses_the_em_dash_separator() {
        assert_eq!(
            CredentialStore::service_name("abc-123"),
            "IntelliJ Platform DB \u{2014} abc-123"
        );
    }

    #[test]
    fn ssh_service_names_match_the_ides_keychain_format() {
        assert_eq!(
            CredentialStore::ssh_password_service_name("localhost", 22, "cfg"),
            "IntelliJ Platform SshConfigPassword \u{2014} localhost:22 cfg"
        );
        assert_eq!(
            CredentialStore::ssh_passphrase_service_name("h", 2222, "cfg"),
            "IntelliJ Platform SshConfigPassphrase \u{2014} h:2222 cfg"
        );
    }

    #[test]
    fn a_password_is_read_from_c_kdbx_with_the_c_pwd_main_key() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let main_key = test_kdbx::bytes("main key", 64);
        write_kdbx(
            dir.path(),
            &main_key,
            &CredentialStore::service_name("a1b2c3"),
            "kdbx-secret",
        );
        fs::write(dir.path().join("c.pwd"), test_kdbx::main_key_file(&main_key)).expect("c.pwd");
        let mut store = store(dir.path(), ForeignPlatform::MacOs);
        assert_eq!(found(store.password("a1b2c3")), "kdbx-secret");
        assert!(store.kdbx_loaded());
    }

    #[test]
    fn an_ssh_password_is_read_from_c_kdbx() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let main_key = test_kdbx::bytes("main key", 64);
        let service = CredentialStore::ssh_password_service_name("h", 2222, "cfg");
        write_kdbx(dir.path(), &main_key, &service, "ssh-secret");
        fs::write(dir.path().join("c.pwd"), test_kdbx::main_key_file(&main_key)).expect("c.pwd");
        assert_eq!(
            found(store(dir.path(), ForeignPlatform::Linux).ssh_password("h", 2222, "cfg")),
            "ssh-secret"
        );
    }

    #[test]
    fn missing_files_find_nothing() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let mut store = store(dir.path(), ForeignPlatform::MacOs);
        assert!(matches!(store.password("missing"), Lookup::NotFound));
        assert!(!store.kdbx_loaded());
    }

    #[test]
    fn a_main_key_under_a_master_password_stops_the_lookups() {
        let dir = tempfile::tempdir().expect("a temp dir");
        write_kdbx(dir.path(), &test_kdbx::bytes("main key", 64), "x", "p");
        fs::write(
            dir.path().join("c.pwd"),
            "isAutoGenerated: false\nvalue: !!binary AAAA\nencryption: MASTER_KEY\n",
        )
        .expect("c.pwd");
        assert!(matches!(
            store(dir.path(), ForeignPlatform::MacOs).password("any"),
            Lookup::Stopped
        ));
    }

    #[test]
    fn a_crypt_32_main_key_stops_the_lookups() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let main_key = test_kdbx::bytes("main key", 64);
        write_kdbx(dir.path(), &main_key, &CredentialStore::service_name("u"), "p");
        let blob = STANDARD.encode(test_kdbx::built_in_blob(&main_key));
        fs::write(
            dir.path().join("c.pwd"),
            format!("encryption: CRYPT_32\nisAutoGenerated: true\nvalue: !!binary {blob}\n"),
        )
        .expect("c.pwd");
        assert!(matches!(
            store(dir.path(), ForeignPlatform::Windows).password("u"),
            Lookup::Stopped
        ));
    }

    #[test]
    fn a_raw_pdb_pwd_is_read_when_c_pwd_is_missing() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let main_key = test_kdbx::bytes("legacy main key", 64);
        write_kdbx(
            dir.path(),
            &main_key,
            &CredentialStore::service_name("old"),
            "legacy-secret",
        );
        fs::write(dir.path().join("pdb.pwd"), test_kdbx::built_in_blob(&main_key)).expect("pdb.pwd");
        assert_eq!(
            found(store(dir.path(), ForeignPlatform::Linux).password("old")),
            "legacy-secret"
        );
    }

    #[test]
    fn pdb_pwd_is_ignored_while_c_pwd_exists() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let main_key = test_kdbx::bytes("legacy main key", 64);
        write_kdbx(
            dir.path(),
            &main_key,
            &CredentialStore::service_name("old"),
            "legacy-secret",
        );
        fs::write(dir.path().join("pdb.pwd"), test_kdbx::built_in_blob(&main_key)).expect("pdb.pwd");
        fs::write(dir.path().join("c.pwd"), "encryption: BUILT_IN\nvalue: !!binary AAAA\n").expect("c.pwd");
        let mut store = store(dir.path(), ForeignPlatform::Linux);
        assert!(matches!(store.password("old"), Lookup::NotFound));
        assert!(!store.kdbx_loaded());
    }

    #[test]
    fn a_pdb_pwd_on_windows_is_under_crypt_32_and_stops_the_lookups() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let main_key = test_kdbx::bytes("legacy main key", 64);
        write_kdbx(
            dir.path(),
            &main_key,
            &CredentialStore::service_name("old"),
            "legacy-secret",
        );
        fs::write(dir.path().join("pdb.pwd"), test_kdbx::built_in_blob(&main_key)).expect("pdb.pwd");
        assert!(matches!(
            store(dir.path(), ForeignPlatform::Windows).password("old"),
            Lookup::Stopped
        ));
    }

    #[test]
    fn the_keychain_is_asked_first_by_service_name_alone() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let main_key = test_kdbx::bytes("main key", 64);
        write_kdbx(
            dir.path(),
            &main_key,
            &CredentialStore::service_name("both"),
            "from-kdbx",
        );
        fs::write(dir.path().join("c.pwd"), test_kdbx::main_key_file(&main_key)).expect("c.pwd");
        let keychain = keychain(vec![(
            CredentialStore::service_name("both"),
            KeychainRead::Found(SecretString::from("from-keychain")),
        )]);
        let mut store = CredentialStore::new(dir.path().to_path_buf(), ForeignPlatform::MacOs, Some(keychain.clone()));
        assert_eq!(found(store.password("both")), "from-keychain");
        assert!(!store.kdbx_loaded());
        let reads = keychain.reads.lock().expect("a lock").clone();
        assert_eq!(reads, [(CredentialStore::service_name("both"), None)]);
    }

    #[test]
    fn c_kdbx_answers_what_the_keychain_does_not_hold() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let main_key = test_kdbx::bytes("main key", 64);
        write_kdbx(
            dir.path(),
            &main_key,
            &CredentialStore::service_name("kdbx"),
            "from-kdbx",
        );
        fs::write(dir.path().join("c.pwd"), test_kdbx::main_key_file(&main_key)).expect("c.pwd");
        let mut store = CredentialStore::new(
            dir.path().to_path_buf(),
            ForeignPlatform::MacOs,
            Some(keychain(Vec::new())),
        );
        assert_eq!(found(store.password("kdbx")), "from-kdbx");
    }

    #[test]
    fn a_refused_keychain_stops_the_lookups() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let keychain = keychain(vec![(CredentialStore::service_name("x"), KeychainRead::Denied)]);
        let mut store = CredentialStore::new(dir.path().to_path_buf(), ForeignPlatform::MacOs, Some(keychain));
        assert!(matches!(store.password("x"), Lookup::Stopped));
    }

    #[test]
    fn a_main_key_file_value_can_continue_on_indented_lines() {
        let blob = test_kdbx::built_in_blob(b"key");
        let encoded = STANDARD.encode(&blob);
        let (head, tail) = encoded.split_at(10);
        let text =
            format!("encryption: BUILT_IN\nisAutoGenerated: true\nvalue: !!binary |-\n  {head}\n\t{tail}\nnext: 1\n");
        let (encryption, parsed) = parse_main_key_file(&text).expect("a main key file");
        assert_eq!(encryption, "BUILT_IN");
        assert_eq!(parsed, blob);
        assert_eq!(decrypt_built_in(&parsed).as_deref(), Some(b"key".as_slice()));
    }

    #[test]
    fn a_main_key_file_without_an_encryption_line_is_built_in() {
        let (encryption, blob) = parse_main_key_file("value: !!binary AAAA").expect("a main key file");
        assert_eq!(encryption, "BUILT_IN");
        assert_eq!(blob, [0, 0, 0]);
    }
}
