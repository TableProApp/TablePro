use std::collections::HashMap;
use std::ffi::OsString;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::auth::TokenPermissions;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpToken {
    pub id: Uuid,
    pub name: String,
    /// SHA-256 hex of the plaintext token. Plaintext is shown once at
    /// issuance and never stored.
    pub token_hash: String,
    pub permissions: TokenPermissions,
    #[serde(default)]
    pub connection_allowlist: Vec<Uuid>,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub revoked: bool,
}

pub struct TokenStore {
    path: PathBuf,
    tokens: Mutex<HashMap<Uuid, McpToken>>,
}

const MAX_TOKEN_STORE_BYTES: u64 = 1024 * 1024;

struct ProcessLock {
    _file: File,
}

impl TokenStore {
    pub fn open_default() -> Result<Self, String> {
        Self::open(tokens_path()?)
    }

    pub fn open(path: PathBuf) -> Result<Self, String> {
        let path = normalized_store_path(path)?;
        let _lock = acquire_process_lock(&path)?;
        let tokens = load_tokens(&path)?;
        Ok(Self {
            path,
            tokens: Mutex::new(tokens),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn issue(
        &self,
        name: String,
        permissions: TokenPermissions,
        connection_allowlist: Vec<Uuid>,
        expires_at: Option<DateTime<Utc>>,
    ) -> Result<(McpToken, String), String> {
        let plaintext = generate_token();
        let token = McpToken {
            id: Uuid::new_v4(),
            name,
            token_hash: hash_token(&plaintext),
            permissions,
            connection_allowlist,
            created_at: Utc::now(),
            expires_at,
            revoked: false,
        };
        let _lock = acquire_process_lock(&self.path)?;
        let mut map = load_tokens(&self.path)?;
        map.insert(token.id, token.clone());
        persist_tokens(&self.path, &map)?;
        *self.tokens.lock().map_err(|error| error.to_string())? = map;
        Ok((token, plaintext))
    }

    pub fn authenticate(&self, plaintext: &str) -> Result<McpToken, String> {
        let hash = hash_token(plaintext);
        let _lock = acquire_process_lock(&self.path)?;
        let refreshed = load_tokens(&self.path)?;
        let mut map = self.tokens.lock().map_err(|error| error.to_string())?;
        *map = refreshed;
        let token = map
            .values()
            .find(|t| !t.revoked && hashes_match(&t.token_hash, &hash))
            .cloned()
            .ok_or_else(|| "invalid token".to_string())?;
        if let Some(exp) = token.expires_at
            && exp < Utc::now()
        {
            return Err("token expired".into());
        }
        Ok(token)
    }

    pub fn revoke(&self, id: Uuid) -> Result<(), String> {
        let _lock = acquire_process_lock(&self.path)?;
        let mut map = load_tokens(&self.path)?;
        if let Some(token) = map.get_mut(&id) {
            token.revoked = true;
        }
        persist_tokens(&self.path, &map)?;
        *self.tokens.lock().map_err(|error| error.to_string())? = map;
        Ok(())
    }

    pub fn list(&self) -> Vec<McpToken> {
        self.tokens
            .lock()
            .map(|m| m.values().cloned().collect())
            .unwrap_or_default()
    }
}

fn normalized_store_path(path: PathBuf) -> Result<PathBuf, String> {
    let absolute = if path.is_absolute() {
        path
    } else {
        std::env::current_dir().map_err(|error| error.to_string())?.join(path)
    };
    let parent = absolute
        .parent()
        .ok_or_else(|| "token store path has no parent".to_string())?;
    std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let parent = parent.canonicalize().map_err(|error| error.to_string())?;
    let name = absolute
        .file_name()
        .ok_or_else(|| "token store path has no file name".to_string())?;
    Ok(parent.join(name))
}

fn acquire_process_lock(path: &Path) -> Result<ProcessLock, String> {
    let lock_path = lock_path(path)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&lock_path)
        .map_err(|error| format!("cannot open token store lock {}: {error}", lock_path.display()))?;
    validate_opened_file(&file, &lock_path)?;
    file.lock()
        .map_err(|error| format!("cannot lock token store {}: {error}", path.display()))?;
    Ok(ProcessLock { _file: file })
}

fn lock_path(path: &Path) -> Result<PathBuf, String> {
    let mut name = OsString::from(
        path.file_name()
            .ok_or_else(|| "token store path has no file name".to_string())?,
    );
    name.push(".lock");
    Ok(path.with_file_name(name))
}

fn load_tokens(path: &Path) -> Result<HashMap<Uuid, McpToken>, String> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(HashMap::new()),
        Err(error) => return Err(format!("cannot open token store {}: {error}", path.display())),
    };
    let metadata = validate_opened_file(&file, path)?;
    if metadata.len() > MAX_TOKEN_STORE_BYTES {
        return Err(token_store_size_error(path));
    }
    let mut bytes = Vec::new();
    file.take(MAX_TOKEN_STORE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("cannot read token store {}: {error}", path.display()))?;
    if bytes.len() as u64 > MAX_TOKEN_STORE_BYTES {
        return Err(token_store_size_error(path));
    }
    let list: Vec<McpToken> = serde_json::from_slice(&bytes)
        .map_err(|error| format!("{} is not a readable token store: {error}", path.display()))?;
    Ok(list.into_iter().map(|token| (token.id, token)).collect())
}

fn persist_tokens(path: &Path, tokens: &HashMap<Uuid, McpToken>) -> Result<(), String> {
    let list = tokens.values().cloned().collect::<Vec<_>>();
    let json = serde_json::to_vec_pretty(&list).map_err(|error| error.to_string())?;
    if json.len() as u64 > MAX_TOKEN_STORE_BYTES {
        return Err(token_store_size_error(path));
    }
    let mut temporary_name = OsString::from(
        path.file_name()
            .ok_or_else(|| "token store path has no file name".to_string())?,
    );
    temporary_name.push(format!(".tmp.{}", Uuid::new_v4()));
    let temporary_path = path.with_file_name(temporary_name);
    let result = persist_through_temporary(path, &temporary_path, &json);
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary_path);
    }
    result
}

fn persist_through_temporary(path: &Path, temporary_path: &Path, json: &[u8]) -> Result<(), String> {
    let mut handle = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(temporary_path)
        .map_err(|error| error.to_string())?;
    handle
        .set_permissions(std::fs::Permissions::from_mode(0o600))
        .map_err(|error| error.to_string())?;
    validate_opened_file(&handle, temporary_path)?;
    handle.write_all(json).map_err(|error| error.to_string())?;
    handle.sync_all().map_err(|error| error.to_string())?;
    drop(handle);
    std::fs::rename(temporary_path, path).map_err(|error| error.to_string())?;
    File::open(
        path.parent()
            .ok_or_else(|| "token store path has no parent".to_string())?,
    )
    .and_then(|directory| directory.sync_all())
    .map_err(|error| error.to_string())
}

fn token_store_size_error(path: &Path) -> String {
    format!(
        "{} exceeds the maximum token store size of {MAX_TOKEN_STORE_BYTES} bytes",
        path.display()
    )
}

fn validate_opened_file(file: &File, path: &Path) -> Result<std::fs::Metadata, String> {
    let metadata = file
        .metadata()
        .map_err(|error| format!("cannot inspect {}: {error}", path.display()))?;
    if !metadata.file_type().is_file() {
        return Err(format!("{} must be a regular file", path.display()));
    }
    let effective_uid = unsafe { libc::geteuid() };
    if metadata.uid() != effective_uid {
        return Err(format!("{} must be owned by the current user", path.display()));
    }
    let mode = metadata.mode() & 0o7777;
    if mode != 0o600 {
        return Err(format!(
            "{} must have mode 0600 and be accessible only by its owner",
            path.display()
        ));
    }
    Ok(metadata)
}

fn hashes_match(stored: &str, candidate: &str) -> bool {
    let stored = stored.as_bytes();
    let candidate = candidate.as_bytes();
    if stored.len() != candidate.len() {
        return false;
    }
    let mut difference = 0u8;
    for (left, right) in stored.iter().zip(candidate) {
        difference |= left ^ right;
    }
    difference == 0
}

pub fn generate_token() -> String {
    let raw = Uuid::new_v4().to_string() + &Uuid::new_v4().to_string();
    format!("tp_{}", &hex::encode(Sha256::digest(raw.as_bytes()))[..40])
}

fn hash_token(plaintext: &str) -> String {
    hex::encode(Sha256::digest(plaintext.as_bytes()))
}

fn tokens_path() -> Result<PathBuf, String> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|h| {
                let mut p = PathBuf::from(h);
                p.push(".config");
                p
            })
        })
        .ok_or_else(|| "neither XDG_CONFIG_HOME nor HOME is set".to_string())?;
    Ok(base.join("tablepro").join("mcp-tokens.json"))
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::symlink;
    use std::process::Command;
    use std::time::{Duration, Instant};

    use super::*;
    use tempfile::TempDir;

    #[test]
    fn the_token_file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.json");
        let store = TokenStore::open(path.clone()).unwrap();
        store
            .issue("t".into(), TokenPermissions::ReadOnly, vec![Uuid::new_v4()], None)
            .unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "token file mode was {mode:o}");
    }

    #[test]
    fn an_existing_token_file_with_group_or_other_access_is_rejected() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.json");
        std::fs::write(&path, b"[]").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        let Err(error) = TokenStore::open(path) else {
            panic!("a permissive store must not open");
        };
        assert!(error.contains("only by its owner"), "{error}");
    }

    #[test]
    fn an_existing_owner_only_token_file_opens() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.json");
        std::fs::write(&path, b"[]").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        TokenStore::open(path).unwrap();
    }

    #[test]
    fn a_symlink_token_file_is_rejected() {
        let dir = TempDir::new().unwrap();
        let target = dir.path().join("target.json");
        let path = dir.path().join("tokens.json");
        std::fs::write(&target, b"[]").unwrap();
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600)).unwrap();
        symlink(target, &path).unwrap();

        let Err(error) = TokenStore::open(path) else {
            panic!("a symlink store must not open");
        };
        assert!(error.contains("cannot open token store"), "{error}");
    }

    #[test]
    fn a_non_regular_token_file_is_rejected() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.json");
        std::fs::create_dir(&path).unwrap();

        let Err(error) = TokenStore::open(path) else {
            panic!("a non-regular store must not open");
        };
        assert!(error.contains("must be a regular file"), "{error}");
    }

    #[test]
    fn an_oversized_token_file_is_rejected() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.json");
        std::fs::write(&path, vec![b' '; MAX_TOKEN_STORE_BYTES as usize + 1]).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();

        let Err(error) = TokenStore::open(path) else {
            panic!("an oversized store must not open");
        };
        assert!(error.contains("maximum token store size"), "{error}");
    }

    #[test]
    fn a_corrupt_token_file_is_an_error_rather_than_an_empty_store() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.json");
        std::fs::write(&path, b"{ this is not a token list").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let Err(error) = TokenStore::open(path) else {
            panic!("a corrupt store must not open");
        };
        assert!(error.contains("not a readable token store"), "{error}");
    }

    #[test]
    fn issue_and_authenticate() {
        let dir = TempDir::new().unwrap();
        let store = TokenStore::open(dir.path().join("tokens.json")).unwrap();
        let (_meta, plain) = store
            .issue("cursor".into(), TokenPermissions::ReadWrite, vec![], None)
            .unwrap();
        let authed = store.authenticate(&plain).unwrap();
        assert_eq!(authed.name, "cursor");
        assert!(store.authenticate("bogus").is_err());
    }

    #[test]
    fn revoke_blocks() {
        let dir = TempDir::new().unwrap();
        let store = TokenStore::open(dir.path().join("tokens.json")).unwrap();
        let (meta, plain) = store
            .issue("x".into(), TokenPermissions::ReadOnly, vec![], None)
            .unwrap();
        store.revoke(meta.id).unwrap();
        assert!(store.authenticate(&plain).is_err());
    }

    #[test]
    fn a_permissive_fixed_temporary_file_is_not_reused() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.json");
        let old_temporary_path = path.with_extension("json.tmp");
        std::fs::write(&old_temporary_path, b"untrusted").unwrap();
        std::fs::set_permissions(&old_temporary_path, std::fs::Permissions::from_mode(0o666)).unwrap();
        let store = TokenStore::open(path.clone()).unwrap();

        store
            .issue("safe".into(), TokenPermissions::ReadOnly, vec![], None)
            .unwrap();

        assert_eq!(std::fs::read(&old_temporary_path).unwrap(), b"untrusted");
        let mode = std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn a_subprocess_issue_cannot_resurrect_a_revoked_token() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.json");
        let issuer_ready = dir.path().join("issuer-ready");
        let revoke_complete = dir.path().join("revoke-complete");
        let store = TokenStore::open(path.clone()).unwrap();
        let (revoked, revoked_plaintext) = store
            .issue("revoked".into(), TokenPermissions::ReadOnly, vec![], None)
            .unwrap();
        drop(store);
        let executable = std::env::current_exe().unwrap();
        let mut issuer = token_subprocess(&executable, "issue", &path, revoked.id, &issuer_ready, &revoke_complete);
        let mut revoker = token_subprocess(
            &executable,
            "revoke",
            &path,
            revoked.id,
            &issuer_ready,
            &revoke_complete,
        );

        assert!(issuer.wait().unwrap().success());
        assert!(revoker.wait().unwrap().success());

        let reopened = TokenStore::open(path).unwrap();
        assert_eq!(reopened.list().len(), 2);
        assert!(reopened.authenticate(&revoked_plaintext).is_err());
    }

    fn token_subprocess(
        executable: &Path,
        action: &str,
        path: &Path,
        token_id: Uuid,
        issuer_ready: &Path,
        revoke_complete: &Path,
    ) -> std::process::Child {
        Command::new(executable)
            .args(["--exact", "tokens::tests::subprocess_mutates_token_store", "--ignored"])
            .env("TABLEPRO_TOKEN_TEST_ACTION", action)
            .env("TABLEPRO_TOKEN_TEST_PATH", path)
            .env("TABLEPRO_TOKEN_TEST_ID", token_id.to_string())
            .env("TABLEPRO_TOKEN_TEST_ISSUER_READY", issuer_ready)
            .env("TABLEPRO_TOKEN_TEST_REVOKE_COMPLETE", revoke_complete)
            .spawn()
            .unwrap()
    }

    fn wait_for_path(path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !path.exists() {
            assert!(Instant::now() < deadline, "timed out waiting for {}", path.display());
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    #[ignore = "helper process spawned by other tests through --exact --ignored, not a standalone test"]
    fn subprocess_mutates_token_store() {
        let action = std::env::var("TABLEPRO_TOKEN_TEST_ACTION").unwrap();
        let path = PathBuf::from(std::env::var_os("TABLEPRO_TOKEN_TEST_PATH").unwrap());
        let token_id = std::env::var("TABLEPRO_TOKEN_TEST_ID").unwrap().parse().unwrap();
        let issuer_ready = PathBuf::from(std::env::var_os("TABLEPRO_TOKEN_TEST_ISSUER_READY").unwrap());
        let revoke_complete = PathBuf::from(std::env::var_os("TABLEPRO_TOKEN_TEST_REVOKE_COMPLETE").unwrap());

        if action == "issue" {
            let store = TokenStore::open(path).unwrap();
            std::fs::write(issuer_ready, b"ready").unwrap();
            wait_for_path(&revoke_complete);
            store
                .issue("issued".into(), TokenPermissions::ReadWrite, vec![], None)
                .unwrap();
            return;
        }

        wait_for_path(&issuer_ready);
        let store = TokenStore::open(path).unwrap();
        store.revoke(token_id).unwrap();
        std::fs::write(revoke_complete, b"revoked").unwrap();
    }
}
