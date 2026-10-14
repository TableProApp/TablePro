use std::path::{Path, PathBuf};

/// The filesystem a database file is on, as far as SQLite's locking
/// can trust it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileLocationKind {
    Local,
    /// A network filesystem, whose locks SQLite cannot rely on.
    Remote {
        fs_type: String,
    },
    /// A file the document portal hands over. `host_is_local` is true
    /// only when the file behind it is visible here and on a local
    /// filesystem.
    Portal {
        host_path: Option<PathBuf>,
        host_is_local: bool,
    },
    /// A FUSE filesystem whose locking is not known.
    Unknown {
        fs_type: String,
    },
}

impl FileLocationKind {
    /// A portal file, checked through `visible` and `classify` for the
    /// file it stands for. `classify` looks one level deep: a host path
    /// that is itself behind a portal never counts as local.
    pub fn portal(
        host_path: Option<PathBuf>,
        visible: impl FnOnce(&Path) -> bool,
        classify: impl FnOnce(&Path) -> FileLocationKind,
    ) -> Self {
        let host_is_local = host_path
            .as_deref()
            .is_some_and(|host| visible(host) && classify(host) == Self::Local);
        Self::Portal {
            host_path,
            host_is_local,
        }
    }

    /// SQLite locking through the portal's FUSE layer is not
    /// established, and the host file may be on a network share.
    pub fn requires_read_only_prompt(&self) -> bool {
        match self {
            Self::Local => false,
            Self::Remote { .. } | Self::Unknown { .. } => true,
            Self::Portal { host_is_local, .. } => !host_is_local,
        }
    }
}
