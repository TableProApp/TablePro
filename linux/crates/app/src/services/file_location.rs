//! Which filesystem a database file is on, and the file a document
//! portal path stands for. Each `_blocking` call reads the disk through
//! synchronous GIO, with no main context, and runs on the spawner.

use std::ffi::OsString;
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};

use gio::prelude::*;

pub use super::file_location_kind::FileLocationKind;

/// Reads which filesystem a path is on.
pub type LocationClassifier = fn(&Path) -> FileLocationKind;

/// GIO's name for the portal's `user.document-portal.host-path`.
const HOST_PATH_ATTRIBUTE: &str = "xattr::document-portal.host-path";

/// Filesystems whose locks SQLite cannot rely on across machines.
const REMOTE_FILESYSTEMS: &[&str] = &[
    "nfs",
    "nfs4",
    "cifs",
    "smb",
    "smb2",
    "smb3",
    "ceph",
    "9p",
    "afs",
    "glusterfs",
    "lustre",
];

/// `fuseblk` is a block device behind FUSE, such as NTFS through
/// ntfs-3g, so its locks are this machine's own.
pub fn kind_for_fs_type(fs_type: &str) -> FileLocationKind {
    match fs_type {
        "fuseblk" => FileLocationKind::Local,
        "fuse.portal" => FileLocationKind::Portal {
            host_path: None,
            host_is_local: false,
        },
        remote if REMOTE_FILESYSTEMS.contains(&remote) => FileLocationKind::Remote {
            fs_type: remote.to_owned(),
        },
        fuse if fuse == "fuse" || fuse.starts_with("fuse.") => FileLocationKind::Unknown {
            fs_type: fuse.to_owned(),
        },
        _ => FileLocationKind::Local,
    }
}

/// The filesystem `path` is on. A file that does not exist yet is
/// classified by its folder's mount.
pub fn classify_blocking(path: &Path) -> FileLocationKind {
    match mount_kind_blocking(path) {
        FileLocationKind::Portal { .. } => FileLocationKind::portal(
            portal_host_path_blocking(path),
            |host| std::fs::symlink_metadata(host).is_ok(),
            mount_kind_blocking,
        ),
        kind => kind,
    }
}

/// The filesystem's kind, without asking a portal for the file behind
/// it, so a portal path inside a portal is never followed.
fn mount_kind_blocking(path: &Path) -> FileLocationKind {
    if let (Some(entry), _) = gio_unix::MountEntry::for_file_path(path) {
        return kind_for_fs_type(&entry.fs_type());
    }
    let attributes = format!(
        "{},{}",
        gio::FILE_ATTRIBUTE_FILESYSTEM_REMOTE,
        gio::FILE_ATTRIBUTE_FILESYSTEM_TYPE
    );
    match gio::File::for_path(path).query_filesystem_info(&attributes, gio::Cancellable::NONE) {
        Ok(info) => {
            let fs_type = info
                .attribute_string(gio::FILE_ATTRIBUTE_FILESYSTEM_TYPE)
                .map(String::from)
                .unwrap_or_default();
            if info.boolean(gio::FILE_ATTRIBUTE_FILESYSTEM_REMOTE) {
                FileLocationKind::Remote { fs_type }
            } else {
                kind_for_fs_type(&fs_type)
            }
        }
        // The open that follows reports a file it cannot reach in its
        // own words.
        Err(error) => {
            tracing::debug!(%error, path = %path.display(), "could not read the file's filesystem");
            FileLocationKind::Local
        }
    }
}

/// The file a document portal path stands for, when the portal says.
pub fn portal_host_path_blocking(path: &Path) -> Option<PathBuf> {
    let info = gio::File::for_path(path)
        .query_info(
            HOST_PATH_ATTRIBUTE,
            gio::FileQueryInfoFlags::NONE,
            gio::Cancellable::NONE,
        )
        .ok()?;
    host_path_from_xattr(&info.attribute_string(HOST_PATH_ATTRIBUTE)?)
}

/// GIO escapes every xattr byte outside printable ASCII, and the
/// backslash, as `\xNN`.
fn host_path_from_xattr(escaped: &str) -> Option<PathBuf> {
    let mut bytes = Vec::with_capacity(escaped.len());
    let mut rest = escaped.as_bytes();
    while let Some((&byte, tail)) = rest.split_first() {
        match (byte, tail) {
            (b'\\', [b'x', high, low, after @ ..]) => {
                let hex = [*high, *low];
                let hex = std::str::from_utf8(&hex).ok()?;
                bytes.push(u8::from_str_radix(hex, 16).ok()?);
                rest = after;
            }
            _ => {
                bytes.push(byte);
                rest = tail;
            }
        }
    }
    while bytes.last() == Some(&0) {
        bytes.pop();
    }
    let path = PathBuf::from(OsString::from_vec(bytes));
    path.is_absolute().then_some(path)
}

/// A path under the document portal's mount, whose folder is an id
/// that means nothing to the user.
pub fn is_portal_path(path: &Path) -> bool {
    if let Ok(rest) = path.strip_prefix("/run/user") {
        let mut parts = rest.iter();
        let uid = parts.next().and_then(|uid| uid.to_str());
        return uid.is_some_and(|uid| !uid.is_empty() && uid.bytes().all(|byte| byte.is_ascii_digit()))
            && parts.next().is_some_and(|doc| doc == "doc")
            && parts.next().is_some();
    }
    path.strip_prefix("/run/flatpak/doc")
        .is_ok_and(|rest| rest.iter().next().is_some())
}

/// How a database path reads to the user: the file a portal stands for
/// when it is known, the name alone for any other portal path, and the
/// path itself otherwise.
pub fn display_path(path: &Path, host_path: Option<&Path>) -> String {
    if let Some(host) = host_path {
        return host.display().to_string();
    }
    match path.file_name() {
        Some(name) if is_portal_path(path) => name.to_string_lossy().into_owned(),
        _ => path.display().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn remote(fs_type: &str) -> FileLocationKind {
        FileLocationKind::Remote {
            fs_type: fs_type.to_owned(),
        }
    }

    fn unknown(fs_type: &str) -> FileLocationKind {
        FileLocationKind::Unknown {
            fs_type: fs_type.to_owned(),
        }
    }

    #[test]
    fn fs_type_table() {
        let portal = FileLocationKind::Portal {
            host_path: None,
            host_is_local: false,
        };
        let cases = [
            ("nfs4", remote("nfs4")),
            ("smb3", remote("smb3")),
            ("cifs", remote("cifs")),
            ("9p", remote("9p")),
            ("fuse.sshfs", unknown("fuse.sshfs")),
            ("fuse.gvfsd-fuse", unknown("fuse.gvfsd-fuse")),
            ("fuse", unknown("fuse")),
            ("fuseblk", FileLocationKind::Local),
            ("fuse.portal", portal),
            ("ext4", FileLocationKind::Local),
            ("btrfs", FileLocationKind::Local),
        ];

        for (fs_type, expected) in cases {
            assert_eq!(kind_for_fs_type(fs_type), expected, "{fs_type}");
        }
    }

    #[test]
    fn portal_without_host_path_requires_prompt() {
        let kind = FileLocationKind::portal(None, |_| true, |_| FileLocationKind::Local);

        assert!(kind.requires_read_only_prompt());
    }

    #[test]
    fn portal_with_invisible_host_path_requires_prompt() {
        let kind = FileLocationKind::portal(
            Some(PathBuf::from("/srv/data/app.db")),
            |_| false,
            |_| FileLocationKind::Local,
        );

        assert!(kind.requires_read_only_prompt());
        assert!(matches!(
            kind,
            FileLocationKind::Portal { host_path: Some(host), .. } if host == Path::new("/srv/data/app.db")
        ));
    }

    #[test]
    fn portal_with_local_host_path_skips_prompt() {
        let host = PathBuf::from("/home/me/app.db");
        let seen = host.clone();

        let kind = FileLocationKind::portal(Some(host), |path| path == seen, |_| FileLocationKind::Local);

        assert!(!kind.requires_read_only_prompt());
    }

    #[test]
    fn portal_with_host_on_a_share_or_another_portal_requires_prompt() {
        let on_share = FileLocationKind::portal(Some(PathBuf::from("/mnt/share/app.db")), |_| true, |_| remote("nfs"));
        let nested = FileLocationKind::portal(
            Some(PathBuf::from("/run/user/1000/doc/1a2b/app.db")),
            |_| true,
            |_| kind_for_fs_type("fuse.portal"),
        );

        assert!(on_share.requires_read_only_prompt());
        assert!(nested.requires_read_only_prompt());
    }

    #[test]
    fn only_a_local_file_opens_without_asking() {
        assert!(!FileLocationKind::Local.requires_read_only_prompt());
        assert!(remote("nfs").requires_read_only_prompt());
        assert!(unknown("fuse.sshfs").requires_read_only_prompt());
    }

    #[test]
    fn tempdir_is_local() {
        let root = tempfile::tempdir().expect("tempdir");
        let database = root.path().join("app.db");
        std::fs::write(&database, b"").expect("seed");

        assert_eq!(classify_blocking(&database), FileLocationKind::Local);
        assert_eq!(
            classify_blocking(&root.path().join("not-created-yet.db")),
            FileLocationKind::Local
        );
        assert_eq!(portal_host_path_blocking(&database), None);
    }

    #[test]
    fn the_host_path_comes_back_unescaped() {
        assert_eq!(
            host_path_from_xattr("/home/me/T\\xc3\\xa0i li\\xe1\\xbb\\x87u/app.db\\x00"),
            Some(PathBuf::from("/home/me/Tài liệu/app.db"))
        );
        assert_eq!(
            host_path_from_xattr("/srv/a\\x5cb.db"),
            Some(PathBuf::from("/srv/a\\b.db"))
        );
        assert_eq!(host_path_from_xattr("relative.db"), None);
        assert_eq!(host_path_from_xattr("/srv/\\xzz.db"), None);
    }

    #[test]
    fn portal_paths_are_told_apart() {
        assert!(is_portal_path(Path::new("/run/user/1000/doc/1a2b3c/app.db")));
        assert!(is_portal_path(Path::new("/run/flatpak/doc/1a2b3c/app.db")));
        assert!(!is_portal_path(Path::new("/run/user/1000/doc")));
        assert!(!is_portal_path(Path::new("/run/user/me/doc/1a2b3c/app.db")));
        assert!(!is_portal_path(Path::new("/home/me/doc/app.db")));
    }

    #[test]
    fn a_portal_path_reads_as_its_host_path_or_its_name() {
        let portal = Path::new("/run/user/1000/doc/1a2b3c/app.db");

        assert_eq!(
            display_path(portal, Some(Path::new("/srv/data/app.db"))),
            "/srv/data/app.db"
        );
        assert_eq!(display_path(portal, None), "app.db");
        assert_eq!(display_path(Path::new("/home/me/app.db"), None), "/home/me/app.db");
    }
}
