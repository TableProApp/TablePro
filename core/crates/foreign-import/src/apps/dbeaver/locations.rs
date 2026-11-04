use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::{ForeignAppDirs, ForeignPlatform};

const DATA_FOLDER: &str = "DBeaverData";
// Older Linux builds used this name, and DBeaver still reads it when `DBeaverData` is missing.
const HIDDEN_DATA_FOLDER: &str = ".DBeaverData";
const FLATPAK_ID: &str = "io.dbeaver.DBeaverCommunity";
const SNAP_NAME: &str = "dbeaver-ce";
const WORKSPACE_PREFIX: &str = "workspace";
const METADATA_FOLDER: &str = ".dbeaver";
const CONFIG_PREFIX: &str = "data-sources";
const CREDENTIALS_PREFIX: &str = "credentials-config";
const JSON_EXTENSION: &str = ".json";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Project {
    pub(super) path: PathBuf,
    pub(super) configs: Vec<ConfigFile>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ConfigFile {
    pub(super) name: String,
    pub(super) path: PathBuf,
    // DBeaver pairs `data-sources<sub>.json` with `credentials-config<sub>.json`.
    pub(super) credentials_path: PathBuf,
    pub(super) is_default: bool,
}

// The Flatpak comes first to win a tie: it copies the native folder, times included, when it moves.
pub(super) fn data_roots(dirs: &ForeignAppDirs) -> Vec<PathBuf> {
    match dirs.platform {
        ForeignPlatform::MacOs => vec![dirs.home.join("Library").join(DATA_FOLDER)],
        ForeignPlatform::Windows => vec![dirs.config.join(DATA_FOLDER)],
        ForeignPlatform::Linux => {
            let local_share = dirs.home.join(".local").join("share");
            let mut roots = vec![
                dirs.home
                    .join(".var")
                    .join("app")
                    .join(FLATPAK_ID)
                    .join("data")
                    .join(DATA_FOLDER),
                dirs.data.join(DATA_FOLDER),
            ];
            // DBeaver reads XDG_DATA_HOME only as a Java property, so a native install keeps `~/.local/share`.
            if dirs.data != local_share {
                roots.push(local_share.join(DATA_FOLDER));
            }
            roots.push(local_share.join(HIDDEN_DATA_FOLDER));
            roots.push(
                dirs.home
                    .join("snap")
                    .join(SNAP_NAME)
                    .join("current")
                    .join(".local")
                    .join("share")
                    .join(DATA_FOLDER),
            );
            roots
        }
    }
}

// Moving between packages leaves two roots behind; the one DBeaver wrote last is the live one.
pub(super) fn find_project(roots: &[PathBuf]) -> Option<Project> {
    let mut chosen: Option<(Project, Option<SystemTime>)> = None;
    for root in roots {
        let Some(project) = project_in(root) else {
            continue;
        };
        let modified = project.last_modified();
        if chosen.as_ref().is_none_or(|(_, newest)| modified > *newest) {
            chosen = Some((project, modified));
        }
    }
    chosen.map(|(project, _)| project)
}

fn project_in(root: &Path) -> Option<Project> {
    let mut workspaces: Vec<(String, PathBuf)> = children(root)
        .into_iter()
        .filter(|(name, _)| name.starts_with(WORKSPACE_PREFIX))
        .collect();
    // A later `workspace7` sorts ahead of `workspace6`.
    workspaces.sort_by(|left, right| right.0.cmp(&left.0));
    workspaces.into_iter().find_map(|(_, workspace)| {
        let mut projects = children(&workspace);
        projects.sort_by(|left, right| left.0.cmp(&right.0));
        projects.into_iter().find_map(|(_, path)| Project::at(path))
    })
}

impl Project {
    fn at(path: PathBuf) -> Option<Self> {
        let configs = config_files(&path.join(METADATA_FOLDER));
        if configs.is_empty() {
            None
        } else {
            Some(Self { path, configs })
        }
    }

    fn last_modified(&self) -> Option<SystemTime> {
        self.configs
            .iter()
            .filter_map(|config| fs::metadata(&config.path).and_then(|metadata| metadata.modified()).ok())
            .max()
    }
}

fn config_files(metadata_folder: &Path) -> Vec<ConfigFile> {
    let mut configs: Vec<ConfigFile> = children(metadata_folder)
        .into_iter()
        .filter_map(|(name, path)| {
            let sub_id = name.strip_prefix(CONFIG_PREFIX)?.strip_suffix(JSON_EXTENSION)?;
            if !fs::metadata(&path).is_ok_and(|metadata| metadata.is_file()) {
                return None;
            }
            let credentials_path = metadata_folder.join(format!("{CREDENTIALS_PREFIX}{sub_id}{JSON_EXTENSION}"));
            let is_default = sub_id.is_empty();
            Some(ConfigFile {
                name,
                path,
                credentials_path,
                is_default,
            })
        })
        .collect();
    configs.sort_by(|left, right| (!left.is_default, &left.name).cmp(&(!right.is_default, &right.name)));
    configs
}

fn children(directory: &Path) -> Vec<(String, PathBuf)> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    entries
        .filter_map(Result::ok)
        .filter_map(|entry| entry.file_name().into_string().ok().map(|name| (name, entry.path())))
        .collect()
}

#[cfg(test)]
mod tests {
    use std::fs::File;
    use std::time::Duration;

    use super::*;

    fn write(path: &Path, contents: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("a folder");
        }
        fs::write(path, contents).expect("a file");
    }

    fn touch(path: &Path, modified: SystemTime) {
        File::options()
            .write(true)
            .open(path)
            .and_then(|file| file.set_modified(modified))
            .expect("a modification time");
    }

    fn names(project: &Project) -> Vec<&str> {
        project.configs.iter().map(|config| config.name.as_str()).collect()
    }

    #[test]
    fn the_newest_workspace_name_wins_and_other_folders_are_ignored() {
        let root = tempfile::tempdir().expect("a temp dir");
        write(&root.path().join("workspace5/General/.dbeaver/data-sources.json"), "{}");
        write(&root.path().join("workspace6/Second/.dbeaver/data-sources.json"), "{}");
        write(&root.path().join("workspace6/First/.dbeaver/data-sources.json"), "{}");
        write(
            &root.path().join("workspace6/Empty/.dbeaver/project-metadata.json"),
            "{}",
        );
        write(&root.path().join("zz-backup/General/.dbeaver/data-sources.json"), "{}");
        let project = find_project(&[root.path().to_path_buf()]).expect("a project");
        assert_eq!(project.path, root.path().join("workspace6/First"));
    }

    #[test]
    fn a_workspace_without_a_data_file_falls_through_to_an_older_one() {
        let root = tempfile::tempdir().expect("a temp dir");
        write(
            &root.path().join("workspace6/General/.dbeaver/project-metadata.json"),
            "{}",
        );
        write(&root.path().join("workspace5/General/.dbeaver/data-sources.json"), "{}");
        let project = find_project(&[root.path().to_path_buf()]).expect("a project");
        assert_eq!(project.path, root.path().join("workspace5/General"));
    }

    #[test]
    fn every_data_sources_file_is_listed_default_first_with_its_own_credentials_file() {
        let root = tempfile::tempdir().expect("a temp dir");
        let metadata = root.path().join("workspace6/General/.dbeaver");
        write(&metadata.join("data-sources-b.json"), "{}");
        write(&metadata.join("data-sources.json"), "{}");
        write(&metadata.join("data-sources-a.json"), "{}");
        write(&metadata.join("data-sources.json.bak"), "{}");
        write(&metadata.join("credentials-config.json"), "");
        fs::create_dir_all(metadata.join("data-sources-folder.json")).expect("a folder");
        let project = find_project(&[root.path().to_path_buf()]).expect("a project");
        assert_eq!(
            names(&project),
            ["data-sources.json", "data-sources-a.json", "data-sources-b.json"]
        );
        assert!(project.configs[0].is_default);
        assert!(!project.configs[1].is_default);
        assert_eq!(
            project.configs[0].credentials_path,
            metadata.join("credentials-config.json")
        );
        assert_eq!(
            project.configs[1].credentials_path,
            metadata.join("credentials-config-a.json")
        );
    }

    #[test]
    fn a_project_with_only_an_extra_data_sources_file_is_found() {
        let root = tempfile::tempdir().expect("a temp dir");
        write(
            &root.path().join("workspace6/General/.dbeaver/data-sources-team.json"),
            "{}",
        );
        let project = find_project(&[root.path().to_path_buf()]).expect("a project");
        assert_eq!(names(&project), ["data-sources-team.json"]);
    }

    #[test]
    fn the_root_whose_data_file_changed_last_wins_and_a_tie_keeps_the_first() {
        let first = tempfile::tempdir().expect("a temp dir");
        let second = tempfile::tempdir().expect("a temp dir");
        let first_file = first.path().join("workspace6/General/.dbeaver/data-sources.json");
        let second_file = second.path().join("workspace6/General/.dbeaver/data-sources.json");
        write(&first_file, "{}");
        write(&second_file, "{}");
        let roots = [first.path().to_path_buf(), second.path().to_path_buf()];
        let earlier = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        let later = earlier + Duration::from_secs(60);

        touch(&first_file, earlier);
        touch(&second_file, later);
        assert_eq!(
            find_project(&roots).map(|p| p.path),
            Some(second.path().join("workspace6/General"))
        );

        touch(&first_file, later);
        assert_eq!(
            find_project(&roots).map(|p| p.path),
            Some(first.path().join("workspace6/General"))
        );
    }

    #[test]
    fn linux_searches_the_flatpak_the_data_folder_the_old_names_and_the_snap() {
        let home = Path::new("/home/me");
        let mut dirs = ForeignAppDirs::conventional(ForeignPlatform::Linux, home);
        assert_eq!(
            data_roots(&dirs),
            [
                home.join(".var/app/io.dbeaver.DBeaverCommunity/data/DBeaverData"),
                home.join(".local/share/DBeaverData"),
                home.join(".local/share/.DBeaverData"),
                home.join("snap/dbeaver-ce/current/.local/share/DBeaverData"),
            ]
        );
        dirs.data = PathBuf::from("/data/me");
        assert_eq!(
            data_roots(&dirs)[1..3],
            [
                PathBuf::from("/data/me/DBeaverData"),
                home.join(".local/share/DBeaverData")
            ]
        );
    }

    #[test]
    fn macos_and_windows_have_one_root_each() {
        let home = Path::new("/Users/me");
        assert_eq!(
            data_roots(&ForeignAppDirs::conventional(ForeignPlatform::MacOs, home)),
            [home.join("Library/DBeaverData")]
        );
        let home = Path::new("C:/Users/me");
        assert_eq!(
            data_roots(&ForeignAppDirs::conventional(ForeignPlatform::Windows, home)),
            [home.join("AppData").join("Roaming").join("DBeaverData")]
        );
    }
}
