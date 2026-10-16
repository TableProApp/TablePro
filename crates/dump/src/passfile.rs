use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use secrecy::{ExposeSecret, SecretString};
use zeroize::Zeroizing;

use crate::DumpError;

#[derive(Debug)]
pub(crate) struct PassFile {
    path: PathBuf,
}

impl PassFile {
    pub(crate) fn create(runtime_dir: &Path, password: &SecretString) -> Result<Self, DumpError> {
        let line = Zeroizing::new(passfile_line(password.expose_secret())?);
        let path = runtime_dir.join(format!("bookie-pgpass-{}", uuid::Uuid::new_v4()));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)?;
        let passfile = Self { path };
        file.write_all(line.as_bytes())?;
        file.sync_all()?;
        Ok(passfile)
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for PassFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn passfile_line(password: &str) -> Result<String, DumpError> {
    if password.contains(['\n', '\r']) {
        return Err(DumpError::Unsupported("the password contains a line break"));
    }
    let mut line = String::with_capacity(password.len() + 10);
    line.push_str("*:*:*:*:");
    for ch in password.chars() {
        if matches!(ch, ':' | '\\') {
            line.push('\\');
        }
        line.push(ch);
    }
    line.push('\n');
    Ok(line)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn the_password_is_escaped_for_libpq() {
        assert_eq!(passfile_line(r"a:b\c").unwrap(), "*:*:*:*:a\\:b\\\\c\n");
    }

    #[test]
    fn a_password_with_a_line_break_is_refused() {
        assert!(matches!(passfile_line("a\nb"), Err(DumpError::Unsupported(_))));
    }

    #[test]
    fn the_file_is_owner_only_and_removed_on_drop() {
        let dir = tempfile::tempdir().unwrap();
        let passfile = PassFile::create(dir.path(), &SecretString::from("secret")).unwrap();
        let path = passfile.path().to_path_buf();
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        drop(passfile);
        assert!(!path.exists());
    }
}
