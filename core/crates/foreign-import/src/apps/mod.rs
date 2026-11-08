pub(crate) mod beekeeper;
pub(crate) mod datagrip;
pub(crate) mod dbeaver;
pub(crate) mod dbx;
pub(crate) mod jdbc;
pub(crate) mod jetbrains;
pub(crate) mod navicat;
pub(crate) mod sequel_ace;
pub(crate) mod sqlite;
pub(crate) mod tableplus;

// A key path the app saved as a bare file name lives in `~/.ssh`, as ssh reads it.
pub(crate) fn resolve_key_path(path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    if path.starts_with('/') || path.starts_with("~/") || is_windows_absolute(path) {
        return path.to_owned();
    }
    format!("~/.ssh/{path}")
}

fn is_windows_absolute(path: &str) -> bool {
    let bytes = path.as_bytes();
    path.starts_with("\\\\")
        || (bytes.len() > 2
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && (bytes[2] == b'\\' || bytes[2] == b'/'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bare_key_name_is_read_from_the_ssh_folder() {
        assert_eq!(resolve_key_path(""), "");
        assert_eq!(resolve_key_path("id_ed25519"), "~/.ssh/id_ed25519");
        assert_eq!(resolve_key_path("/keys/id"), "/keys/id");
        assert_eq!(resolve_key_path("~/keys/id"), "~/keys/id");
        assert_eq!(resolve_key_path("C:\\Users\\me\\.ssh\\id"), "C:\\Users\\me\\.ssh\\id");
    }
}
