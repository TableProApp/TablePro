use std::fs;
use std::path::{Path, PathBuf};

use crate::apps::jetbrains::{expand, xml};
use crate::{ForeignAppDirs, ForeignPlatform};

const FLATPAK_ID: &str = "com.jetbrains.DataGrip";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Location {
    pub data_sources: PathBuf,
    pub local: Option<PathBuf>,
    pub config_dir: PathBuf,
}

// The folders that hold `DataGrip<version>` config dirs. On Linux the IDE follows $XDG_CONFIG_HOME,
// and the Flathub build keeps its own under ~/.var/app.
pub(crate) fn jetbrains_roots(dirs: &ForeignAppDirs) -> Vec<PathBuf> {
    let primary = dirs.config.join("JetBrains");
    match dirs.platform {
        ForeignPlatform::MacOs | ForeignPlatform::Windows => vec![primary],
        ForeignPlatform::Linux => {
            let home_config = dirs.home.join(".config").join("JetBrains");
            let flatpak = dirs
                .home
                .join(".var")
                .join("app")
                .join(FLATPAK_ID)
                .join("config")
                .join("JetBrains");
            let mut roots = vec![primary];
            if home_config != roots[0] {
                roots.push(home_config);
            }
            roots.push(flatpak);
            roots
        }
    }
}

// Newest version first across every root, so the first copy of a data source wins; a name in two
// roots keeps the order of the roots.
pub(crate) fn config_dirs(roots: &[PathBuf]) -> Vec<PathBuf> {
    let mut found: Vec<(String, PathBuf)> = Vec::new();
    for root in roots {
        let Ok(children) = fs::read_dir(root) else {
            continue;
        };
        for child in children.filter_map(Result::ok) {
            if let Ok(name) = child.file_name().into_string()
                && name.starts_with("DataGrip")
            {
                found.push((name, child.path()));
            }
        }
    }
    found.sort_by(|left, right| right.0.cmp(&left.0));
    found.into_iter().map(|(_, path)| path).collect()
}

pub(crate) fn locations(config_dirs: &[PathBuf], home: &Path) -> Vec<Location> {
    let mut result = Vec::new();
    for config_dir in config_dirs {
        append(&config_dir.join("options"), config_dir, &mut result);
        for project in project_dirs(&config_dir.join("projects")) {
            append(&project.join(".idea"), config_dir, &mut result);
        }
        for project in recent_project_paths(config_dir, home) {
            append(&PathBuf::from(project).join(".idea"), config_dir, &mut result);
        }
    }
    result
}

fn project_dirs(projects: &Path) -> Vec<PathBuf> {
    let Ok(children) = fs::read_dir(projects) else {
        return Vec::new();
    };
    let mut found: Vec<PathBuf> = children
        .filter_map(Result::ok)
        .filter(|child| !child.file_name().to_string_lossy().starts_with('.'))
        .map(|child| child.path())
        .collect();
    found.sort();
    found
}

fn append(directory: &Path, config_dir: &Path, result: &mut Vec<Location>) {
    let data_sources = directory.join("dataSources.xml");
    if !data_sources.exists() {
        return;
    }
    let local = directory.join("dataSources.local.xml");
    result.push(Location {
        data_sources,
        local: local.exists().then_some(local),
        config_dir: config_dir.to_path_buf(),
    });
}

fn recent_project_paths(config_dir: &Path, home: &Path) -> Vec<String> {
    let Ok(data) = crate::files::read_capped(config_dir.join("options").join("recentProjects.xml")) else {
        return Vec::new();
    };
    let Some(document) = xml::document(&data) else {
        return Vec::new();
    };
    xml::elements(&document, "entry")
        .filter_map(|entry| entry.attribute("key"))
        .map(|key| expand(key, home))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dirs(platform: ForeignPlatform, home: &Path, config: &Path) -> ForeignAppDirs {
        ForeignAppDirs {
            platform,
            home: home.to_path_buf(),
            config: config.to_path_buf(),
            data: home.join("data"),
        }
    }

    #[test]
    fn linux_searches_the_xdg_folder_the_home_config_folder_and_the_flatpak_folder() {
        let home = Path::new("/home/me");
        let roots = jetbrains_roots(&dirs(ForeignPlatform::Linux, home, &home.join("xdg")));
        assert_eq!(
            roots,
            [
                home.join("xdg/JetBrains"),
                home.join(".config/JetBrains"),
                home.join(".var/app/com.jetbrains.DataGrip/config/JetBrains"),
            ]
        );
        let conventional = jetbrains_roots(&ForeignAppDirs::conventional(ForeignPlatform::Linux, home));
        assert_eq!(
            conventional,
            [
                home.join(".config/JetBrains"),
                home.join(".var/app/com.jetbrains.DataGrip/config/JetBrains")
            ]
        );
    }

    #[test]
    fn macos_and_windows_search_the_config_folder_only() {
        let home = Path::new("/Users/me");
        let mac = ForeignAppDirs::conventional(ForeignPlatform::MacOs, home);
        assert_eq!(
            jetbrains_roots(&mac),
            [home.join("Library/Application Support/JetBrains")]
        );
        let windows = ForeignAppDirs::conventional(ForeignPlatform::Windows, home);
        assert_eq!(
            jetbrains_roots(&windows),
            [home.join("AppData").join("Roaming").join("JetBrains")]
        );
    }

    #[test]
    fn config_dirs_run_newest_first_across_roots_and_ties_keep_root_order() {
        let base = tempfile::tempdir().expect("a temp dir");
        let first = base.path().join("first");
        let second = base.path().join("second");
        for path in [
            first.join("DataGrip2025.1"),
            first.join("IntelliJIdea2025.3"),
            second.join("DataGrip2025.3"),
            second.join("DataGrip2025.1"),
        ] {
            fs::create_dir_all(path).expect("a folder");
        }
        let found = config_dirs(&[first.clone(), second.clone(), base.path().join("missing")]);
        assert_eq!(
            found,
            [
                second.join("DataGrip2025.3"),
                first.join("DataGrip2025.1"),
                second.join("DataGrip2025.1")
            ]
        );
    }
}
