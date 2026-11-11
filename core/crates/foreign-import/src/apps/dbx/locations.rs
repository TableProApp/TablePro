use std::path::PathBuf;

use crate::{ForeignAppDirs, ForeignPlatform};

// Tauri's bundle identifier names the app's data folder on every platform.
const FOLDER: &str = "com.dbx.app";

pub(super) const STORE: &str = "dbx.db";

// Tauri's app data directory: `$XDG_DATA_HOME` on Linux, Application Support on macOS and the
// roaming AppData on Windows. `DBX_DATA_DIR` and the portable build's folder are the app's own
// overrides, which an import does not follow since it cannot tell which one a run used.
pub(super) fn data_dir(dirs: &ForeignAppDirs) -> PathBuf {
    match dirs.platform {
        ForeignPlatform::Windows => dirs.config.join(FOLDER),
        ForeignPlatform::Linux | ForeignPlatform::MacOs => dirs.data.join(FOLDER),
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    #[test]
    fn each_platform_looks_where_tauri_keeps_the_app_data() {
        let home = Path::new("/home/ada");
        let at = |platform| data_dir(&ForeignAppDirs::conventional(platform, home));

        assert_eq!(at(ForeignPlatform::Linux), home.join(".local/share/com.dbx.app"));
        assert_eq!(
            at(ForeignPlatform::MacOs),
            home.join("Library/Application Support/com.dbx.app")
        );
        assert_eq!(at(ForeignPlatform::Windows), home.join("AppData/Roaming/com.dbx.app"));
    }
}
