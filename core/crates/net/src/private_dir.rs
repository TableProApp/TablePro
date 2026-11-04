use std::io;

use tempfile::TempDir;

/// A directory only the user can open, in the runtime directory where
/// there is one.
#[cfg(unix)]
pub fn private_dir(prefix: &str) -> io::Result<TempDir> {
    use std::os::unix::fs::PermissionsExt;

    let builder = || {
        let mut builder = tempfile::Builder::new();
        // The default follows the umask, which leaves the directory
        // listable by anyone.
        builder
            .prefix(prefix)
            .permissions(std::fs::Permissions::from_mode(0o700));
        builder
    };
    match std::env::var_os("XDG_RUNTIME_DIR").filter(|dir| !dir.is_empty()) {
        Some(runtime) => builder().tempdir_in(runtime).or_else(|_| builder().tempdir()),
        None => builder().tempdir(),
    }
}

/// A directory in the user's own temporary folder, which only they and
/// the system can open.
#[cfg(not(unix))]
pub fn private_dir(prefix: &str) -> io::Result<TempDir> {
    tempfile::Builder::new().prefix(prefix).tempdir()
}
