use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::{ForeignAppDirs, ForeignPlatform};

// Electron's userData folder, named after the package name on every platform.
const FOLDER: &str = "beekeeper-studio";

pub(super) const APP_DB: &str = "app.db";

// Linux: the host's config folder, `~/.config` if different, the Flathub and release-page Flatpaks, the Snap.
pub(super) fn candidates(dirs: &ForeignAppDirs) -> Vec<PathBuf> {
    let primary = dirs.config.join(FOLDER);
    if dirs.platform != ForeignPlatform::Linux {
        return vec![primary];
    }
    let home = &dirs.home;
    let home_config = home.join(".config").join(FOLDER);
    let flatpak = |id: &str| home.join(".var").join("app").join(id).join("config").join(FOLDER);
    let mut roots = vec![primary];
    if !roots.contains(&home_config) {
        roots.push(home_config);
    }
    roots.push(flatpak("io.beekeeperstudio.Studio"));
    roots.push(flatpak("io.beekeeperstudio.desktop"));
    roots.push(
        home.join("snap")
            .join("beekeeper-studio")
            .join("current")
            .join(".config")
            .join(FOLDER),
    );
    roots
}

// Several packages can leave a copy behind; the one saved to last is the one in use.
pub(super) fn data_dir(dirs: &ForeignAppDirs) -> PathBuf {
    let candidates = candidates(dirs);
    let mut latest: Option<(SystemTime, &Path)> = None;
    for dir in &candidates {
        let Ok(metadata) = fs::metadata(dir.join(APP_DB)) else {
            continue;
        };
        let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        if latest.is_none_or(|(time, _)| modified > time) {
            latest = Some((modified, dir));
        }
    }
    match latest {
        Some((_, dir)) => dir.to_path_buf(),
        None => candidates
            .into_iter()
            .next()
            .unwrap_or_else(|| dirs.config.join(FOLDER)),
    }
}

#[cfg(test)]
mod tests {
    use std::fs::File;
    use std::time::Duration;

    use super::*;

    fn touch(dir: &Path, age: Duration) {
        fs::create_dir_all(dir).expect("a folder");
        let file = File::create(dir.join(APP_DB)).expect("a file");
        file.set_modified(SystemTime::now() - age).expect("a time");
    }

    #[test]
    fn linux_searches_each_package_in_a_fixed_order() {
        let home = Path::new("/home/me");
        let dirs = ForeignAppDirs::conventional(ForeignPlatform::Linux, home);
        let expected: Vec<PathBuf> = [
            ".config/beekeeper-studio",
            ".var/app/io.beekeeperstudio.Studio/config/beekeeper-studio",
            ".var/app/io.beekeeperstudio.desktop/config/beekeeper-studio",
            "snap/beekeeper-studio/current/.config/beekeeper-studio",
        ]
        .iter()
        .map(|path| home.join(path))
        .collect();
        assert_eq!(candidates(&dirs), expected);

        let custom = ForeignAppDirs {
            config: home.join("xdg"),
            ..dirs
        };
        assert_eq!(
            candidates(&custom)[..2],
            [home.join("xdg/beekeeper-studio"), home.join(".config/beekeeper-studio")]
        );
        assert_eq!(candidates(&custom).len(), 5);
    }

    #[test]
    fn macos_and_windows_have_one_folder() {
        let home = Path::new("/Users/me");
        let mac = ForeignAppDirs::conventional(ForeignPlatform::MacOs, home);
        assert_eq!(
            candidates(&mac),
            [home.join("Library/Application Support/beekeeper-studio")]
        );
        let windows = ForeignAppDirs::conventional(ForeignPlatform::Windows, home);
        assert_eq!(
            candidates(&windows),
            [home.join("AppData").join("Roaming").join("beekeeper-studio")]
        );
    }

    #[test]
    fn the_copy_saved_to_last_wins_and_the_first_folder_stands_in_for_none() {
        let home = tempfile::tempdir().expect("a home");
        let dirs = ForeignAppDirs::conventional(ForeignPlatform::Linux, home.path());
        let [native, flathub, _, snap] = [0, 1, 2, 3].map(|index| candidates(&dirs)[index].clone());
        assert_eq!(data_dir(&dirs), native);

        touch(&native, Duration::from_secs(300));
        touch(&snap, Duration::from_secs(60));
        touch(&flathub, Duration::from_secs(120));
        assert_eq!(data_dir(&dirs), snap);
    }
}
