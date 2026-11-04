use std::collections::BTreeMap;
use std::path::Path;

use serde_json::Value;
use tokio_util::sync::CancellationToken;

use crate::app::check_cancel;
use crate::sql_file_tree::{self, SqlFileEntry};
use crate::{ForeignImportError, ForeignSavedQuery};

const SCRIPTS_FOLDER: &str = "Scripts";

pub(super) fn saved_queries(
    project: &Path,
    limit: u64,
    cancel: &CancellationToken,
) -> Result<Vec<ForeignSavedQuery>, ForeignImportError> {
    let bindings = data_source_bindings(project);
    let entries = script_entries(project, cancel);
    check_cancel(cancel)?;
    let mut queries = Vec::with_capacity(entries.len());
    for entry in entries {
        check_cancel(cancel)?;
        let Some(content) = sql_file_tree::content(&entry, limit) else {
            continue;
        };
        let name = entry.stem();
        // DBeaver keys a script's settings by its path from the project, always with `/`.
        let resource_path = std::iter::once(SCRIPTS_FOLDER)
            .chain(entry.folder_path.iter().map(String::as_str))
            .chain(std::iter::once(entry.file_name.as_str()))
            .collect::<Vec<_>>()
            .join("/");
        queries.push(ForeignSavedQuery {
            is_auto_named: is_auto_named(&name),
            name,
            content,
            keyword: None,
            folder_path: entry.folder_path,
            source_connection_id: bindings.get(&resource_path).cloned(),
        });
    }
    Ok(queries)
}

pub(super) fn count(project: &Path) -> usize {
    script_entries(project, &CancellationToken::new())
        .iter()
        .filter(|entry| sql_file_tree::is_countable(entry))
        .count()
}

// DBeaver names a new script `Script`, then `Script-1`, `Script-2` and so on.
pub(super) fn is_auto_named(name: &str) -> bool {
    let lowered = name.to_lowercase();
    if lowered == "script" {
        return true;
    }
    lowered
        .strip_prefix("script-")
        .is_some_and(|number| !number.is_empty() && number.chars().all(|c| c.is_ascii_digit()))
}

fn script_entries(project: &Path, cancel: &CancellationToken) -> Vec<SqlFileEntry> {
    sql_file_tree::entries(
        &project.join(SCRIPTS_FOLDER),
        &|name| name.to_lowercase().ends_with(".sql"),
        cancel,
    )
}

fn data_source_bindings(project: &Path) -> BTreeMap<String, String> {
    let path = project.join(".dbeaver").join("project-metadata.json");
    let Some(resources) = crate::files::read_capped(path)
        .ok()
        .and_then(|data| serde_json::from_slice::<BTreeMap<String, Value>>(&data).ok())
        .and_then(|mut metadata| metadata.remove("resources"))
        .and_then(|resources| serde_json::from_value::<BTreeMap<String, Value>>(resources).ok())
    else {
        return BTreeMap::new();
    };
    resources
        .into_iter()
        .filter_map(|(path, properties)| {
            let id = properties.get("default-datasource")?.as_str()?;
            (!id.is_empty()).then(|| (path, id.to_owned()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn script_names_dbeaver_generates_are_recognized() {
        assert!(is_auto_named("Script"));
        assert!(is_auto_named("Script-12"));
        assert!(is_auto_named("script-2"));
        assert!(!is_auto_named("Script-"));
        assert!(!is_auto_named("Script-2b"));
        assert!(!is_auto_named("Scripts"));
        assert!(!is_auto_named("Monthly report"));
    }
}
