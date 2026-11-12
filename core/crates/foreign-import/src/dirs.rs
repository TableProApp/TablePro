use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ForeignPlatform {
    MacOs,
    Linux,
    Windows,
}

impl ForeignPlatform {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Self::MacOs
        } else if cfg!(windows) {
            Self::Windows
        } else {
            Self::Linux
        }
    }
}

// Where other apps keep their files. The app fills it from the platform's own directories; a
// sandboxed Linux app passes the host's XDG directories, not its own.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignAppDirs {
    pub platform: ForeignPlatform,
    pub home: PathBuf,
    // Linux: $XDG_CONFIG_HOME. Windows: %APPDATA%. macOS: ~/Library/Application Support.
    pub config: PathBuf,
    // Linux: $XDG_DATA_HOME. Windows: %LOCALAPPDATA%. macOS: ~/Library/Application Support.
    pub data: PathBuf,
}

impl ForeignAppDirs {
    pub fn conventional(platform: ForeignPlatform, home: &Path) -> Self {
        let (config, data) = match platform {
            ForeignPlatform::MacOs => {
                let support = home.join("Library").join("Application Support");
                (support.clone(), support)
            }
            ForeignPlatform::Linux => (home.join(".config"), home.join(".local").join("share")),
            ForeignPlatform::Windows => {
                let app_data = home.join("AppData");
                (app_data.join("Roaming"), app_data.join("Local"))
            }
        };
        Self {
            platform,
            home: home.to_path_buf(),
            config,
            data,
        }
    }

    // `~/` as the other app wrote it, against the home folder these directories belong to.
    pub fn expand_home(&self, path: &str) -> PathBuf {
        match path.strip_prefix("~/") {
            Some(rest) => self.home.join(rest),
            None => PathBuf::from(path),
        }
    }
}
