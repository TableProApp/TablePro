use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::app::check_cancel;
use crate::apps::jetbrains::xml;
use crate::sql_file_tree::{self, SqlFileEntry};
use crate::{ForeignImportError, ForeignSavedQuery};

const DEFAULT_BASE_NAME: &str = "console";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ConsoleSource {
    pub uuid: String,
    pub is_mongo: bool,
}

struct ConsoleFolder<'a> {
    source: &'a ConsoleSource,
    path: PathBuf,
    base_name: String,
}

pub(crate) fn saved_queries(
    sources: &[ConsoleSource],
    config_dirs: &[PathBuf],
    limit: u64,
    cancel: &CancellationToken,
) -> Result<Vec<ForeignSavedQuery>, ForeignImportError> {
    let mut queries = Vec::new();
    for folder in console_folders(sources, config_dirs) {
        for entry in entries(&folder, cancel) {
            check_cancel(cancel)?;
            let Some(content) = sql_file_tree::content(&entry, limit) else {
                continue;
            };
            let name = entry.stem();
            queries.push(ForeignSavedQuery {
                is_auto_named: is_auto_named(&name, &folder.base_name),
                name,
                content,
                keyword: None,
                folder_path: entry.folder_path,
                source_connection_id: Some(folder.source.uuid.clone()),
            });
        }
    }
    Ok(queries)
}

pub(crate) fn count(sources: &[ConsoleSource], config_dirs: &[PathBuf]) -> usize {
    let cancel = CancellationToken::new();
    console_folders(sources, config_dirs)
        .iter()
        .map(|folder| {
            entries(folder, &cancel)
                .iter()
                .filter(|entry| sql_file_tree::is_countable(entry))
                .count()
        })
        .sum()
}

// DataGrip names consoles `<base>`, `<base>_1`, `<base>_2`; the base is a setting that defaults to `console`.
pub(crate) fn is_auto_named(name: &str, base_name: &str) -> bool {
    let lowered = name.to_lowercase();
    let base = base_name.to_lowercase();
    if lowered == base {
        return true;
    }
    let Some(number) = lowered.strip_prefix(&base).and_then(|rest| rest.strip_prefix('_')) else {
        return false;
    };
    !number.is_empty()
        && !number.starts_with('0')
        && number.len() <= 5
        && number.bytes().all(|byte| byte.is_ascii_digit())
}

fn base_name(config_dir: &Path) -> String {
    let Ok(data) = crate::files::read_capped(config_dir.join("options").join("QueryFileSettings.xml")) else {
        return DEFAULT_BASE_NAME.to_owned();
    };
    let Some(document) = xml::document(&data) else {
        return DEFAULT_BASE_NAME.to_owned();
    };
    xml::elements(&document, "option")
        .filter(|option| option.attribute("name") == Some("scratchesName"))
        .find_map(|option| option.attribute("value"))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map_or_else(|| DEFAULT_BASE_NAME.to_owned(), str::to_owned)
}

// An IDE upgrade copies consoles into the new config dir, so only the newest copy of each data source
// counts. The uuid comes from a project's dataSources.xml, which a repository can carry, so it becomes
// a path only when it is a UUID.
fn console_folders<'a>(sources: &'a [ConsoleSource], config_dirs: &[PathBuf]) -> Vec<ConsoleFolder<'a>> {
    let mut seen: HashSet<&str> = HashSet::new();
    let mut base_names: HashMap<&Path, String> = HashMap::new();
    let mut folders = Vec::new();
    for source in sources {
        if !is_uuid(&source.uuid) || !seen.insert(source.uuid.as_str()) {
            continue;
        }
        for config_dir in config_dirs {
            let path = config_dir.join("consoles").join("db").join(&source.uuid);
            if !path.is_dir() {
                continue;
            }
            let base_name = base_names
                .entry(config_dir.as_path())
                .or_insert_with(|| base_name(config_dir))
                .clone();
            folders.push(ConsoleFolder {
                source,
                path,
                base_name,
            });
            break;
        }
    }
    folders
}

// Only the hyphenated form, as Foundation's UUID parser takes it.
fn is_uuid(value: &str) -> bool {
    value.len() == 36 && Uuid::try_parse(value).is_ok()
}

fn entries(folder: &ConsoleFolder<'_>, cancel: &CancellationToken) -> Vec<SqlFileEntry> {
    let is_mongo = folder.source.is_mongo;
    let accepts = move |file_name: &str| match Path::new(file_name)
        .extension()
        .and_then(|extension| extension.to_str())
    {
        Some(extension) if extension.eq_ignore_ascii_case("sql") => true,
        Some(extension) if extension.eq_ignore_ascii_case("js") => is_mongo,
        _ => false,
    };
    sql_file_tree::entries(&folder.path, &accepts, cancel)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn console_names_datagrip_generates_are_recognized() {
        assert!(is_auto_named("console", "console"));
        assert!(is_auto_named("console_1", "console"));
        assert!(is_auto_named("Console_99999", "console"));
        assert!(!is_auto_named("console_0", "console"));
        assert!(!is_auto_named("console_100000", "console"));
        assert!(!is_auto_named("console_", "console"));
        assert!(!is_auto_named("consoles", "console"));
    }

    #[test]
    fn only_a_hyphenated_uuid_names_a_console_folder() {
        assert!(is_uuid("11111111-1111-4111-8111-111111111111"));
        assert!(!is_uuid("11111111111141118111111111111111"));
        assert!(!is_uuid("{11111111-1111-4111-8111-111111111111}"));
        assert!(!is_uuid("../escape"));
    }
}
