use std::collections::{HashMap, HashSet};

use serde::Deserialize;
use tokio_util::sync::CancellationToken;

use super::config::Layer;
use crate::app::check_cancel;
use crate::apps::sqlite::Database;
use crate::{ForeignImportError, ForeignSavedQuery, SavedQueryContent};

const BLANKS: [char; 4] = [' ', '\t', '\n', '\r'];

pub(super) fn connection_rows(db: &Database) -> Result<Vec<String>, ForeignImportError> {
    let Some(mut statement) = db.prepare("SELECT config_json FROM connections ORDER BY rowid") else {
        return Err(ForeignImportError::parse("dbx.db has no connections table"));
    };
    let mut rows = Vec::new();
    while let Some(row) = statement.next_row() {
        rows.extend(row.text(0));
    }
    Ok(rows)
}

pub(super) fn tunnel_profiles(db: &Database) -> HashMap<String, Layer> {
    let mut profiles = HashMap::new();
    let Some(mut statement) = db.prepare("SELECT id, config_json FROM tunnel_profiles") else {
        return profiles;
    };
    while let Some(row) = statement.next_row() {
        let (Some(id), Some(json)) = (row.text(0), row.text(1)) else {
            continue;
        };
        match serde_json::from_str::<Layer>(&json) {
            Ok(layer) => {
                profiles.insert(id, layer);
            }
            Err(error) => tracing::warn!(%error, "skipping a DBX tunnel profile that does not parse"),
        }
    }
    profiles
}

// The names of the settings each connection keeps among its secrets, such as `init_script`. Only the
// names are read, never a value.
pub(super) fn secret_names(db: &Database) -> HashMap<String, HashSet<String>> {
    let mut names: HashMap<String, HashSet<String>> = HashMap::new();
    let Some(mut statement) = db.prepare("SELECT connection_id, key FROM connection_secrets") else {
        return names;
    };
    while let Some(row) = statement.next_row() {
        if let (Some(connection), Some(key)) = (row.text(0), row.text(1)) {
            names.entry(connection).or_default().insert(key);
        }
    }
    names
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct Layout {
    groups: Vec<Group>,
    order: Vec<Entry>,
}

#[derive(Deserialize)]
struct Group {
    id: String,
    name: String,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Entry {
    Group {
        id: String,
        children: Option<Vec<Entry>>,
        // The first layouts listed a group's connections flat.
        #[serde(rename = "connectionIds")]
        connection_ids: Option<Vec<String>>,
    },
    Connection {
        id: String,
    },
}

// The group path of each connection in DBX's sidebar.
pub(super) fn group_paths(db: &Database) -> HashMap<String, Vec<String>> {
    let mut paths = HashMap::new();
    let Some(mut statement) = db.prepare("SELECT layout_json FROM sidebar_layout WHERE id = 1") else {
        return paths;
    };
    let Some(json) = statement.next_row().and_then(|row| row.text(0)) else {
        return paths;
    };
    match serde_json::from_str::<Layout>(&json) {
        Ok(layout) => {
            let names: HashMap<&str, &str> = layout
                .groups
                .iter()
                .map(|group| (group.id.as_str(), group.name.as_str()))
                .collect();
            walk(&layout.order, &names, &mut Vec::new(), &mut paths);
        }
        Err(error) => tracing::warn!(%error, "skipping a DBX sidebar layout that does not parse"),
    }
    paths
}

fn walk(
    entries: &[Entry],
    names: &HashMap<&str, &str>,
    path: &mut Vec<String>,
    paths: &mut HashMap<String, Vec<String>>,
) {
    for entry in entries {
        match entry {
            Entry::Connection { id } => {
                paths.insert(id.clone(), path.clone());
            }
            Entry::Group {
                id,
                children,
                connection_ids,
            } => {
                // A group the layout has no name for adds no level.
                let name = names.get(id.as_str()).map(|name| (*name).to_owned());
                path.extend(name.clone());
                if let Some(children) = children {
                    walk(children, names, path, paths);
                } else {
                    for connection in connection_ids.iter().flatten() {
                        paths.insert(connection.clone(), path.clone());
                    }
                }
                if name.is_some() {
                    path.pop();
                }
            }
        }
    }
}

pub(super) fn saved_sql_count(db: &Database) -> usize {
    let columns = db.columns("saved_sql_files");
    if !columns.contains("sql_text") {
        return 0;
    }
    let Some(mut statement) = db.prepare(
        "SELECT COUNT(*) FROM saved_sql_files \
         WHERE trim(COALESCE(sql_text, ''), ' ' || char(9) || char(10) || char(13)) != ''",
    ) else {
        return 0;
    };
    statement
        .next_row()
        .map_or(0, |row| usize::try_from(row.int64(0)).unwrap_or(0))
}

// Each saved SQL file with the connection it runs on; the default query DBX opens for a database
// counts as named by the app.
pub(super) fn saved_sql(
    db: &Database,
    limit: u64,
    cancel: &CancellationToken,
) -> Result<Vec<ForeignSavedQuery>, ForeignImportError> {
    let columns = db.columns("saved_sql_files");
    if !["connection_id", "name", "sql_text"]
        .iter()
        .all(|column| columns.contains(*column))
    {
        return Ok(Vec::new());
    }
    let column = |name: &'static str| if columns.contains(name) { name } else { "NULL" };
    let sql = format!(
        "SELECT connection_id, {}, name, CASE WHEN length(CAST(sql_text AS BLOB)) > ?1 THEN NULL ELSE sql_text END, \
         length(CAST(sql_text AS BLOB)), {} FROM saved_sql_files ORDER BY rowid",
        column("folder_id"),
        column("is_default_query"),
    );
    let Some(mut statement) = db.prepare(&sql) else {
        return Ok(Vec::new());
    };
    statement.bind_int64(1, i64::try_from(limit).unwrap_or(i64::MAX));
    let folders = folders(db);

    let mut queries = Vec::new();
    while let Some(row) = statement.next_row() {
        check_cancel(cancel)?;
        let byte_count = u64::try_from(row.int64(4)).unwrap_or(0);
        let content = if byte_count > limit {
            SavedQueryContent::Oversized { byte_count }
        } else {
            match row.text(3) {
                Some(sql) if !sql.trim_matches(BLANKS).is_empty() => SavedQueryContent::Text(sql),
                _ => continue,
            }
        };
        queries.push(ForeignSavedQuery {
            name: row.text(2).unwrap_or_default(),
            content,
            keyword: None,
            folder_path: folder_path(row.text(1), &folders),
            source_connection_id: row.text(0).filter(|id| !id.is_empty()),
            is_auto_named: row.optional_int64(5).is_some_and(|flag| flag != 0),
        });
    }
    Ok(queries)
}

struct Folder {
    name: String,
    parent: Option<String>,
}

fn folders(db: &Database) -> HashMap<String, Folder> {
    let columns = db.columns("saved_sql_folders");
    if !columns.contains("id") || !columns.contains("name") {
        return HashMap::new();
    }
    let parent = if columns.contains("parent_folder_id") {
        "parent_folder_id"
    } else {
        "NULL"
    };
    let Some(mut statement) = db.prepare(&format!("SELECT id, name, {parent} FROM saved_sql_folders")) else {
        return HashMap::new();
    };
    let mut folders = HashMap::new();
    while let Some(row) = statement.next_row() {
        if let Some(id) = row.text(0) {
            folders.insert(
                id,
                Folder {
                    name: row.text(1).unwrap_or_default(),
                    parent: row.text(2).filter(|parent| !parent.is_empty()),
                },
            );
        }
    }
    folders
}

// A parent chain that loops ends at the first folder seen twice.
fn folder_path(folder: Option<String>, folders: &HashMap<String, Folder>) -> Vec<String> {
    let mut path = Vec::new();
    let mut seen = HashSet::new();
    let mut current = folder;
    while let Some(id) = current
        && let Some(folder) = folders.get(&id)
        && seen.insert(id)
    {
        path.push(folder.name.clone());
        current = folder.parent.clone();
    }
    path.reverse();
    path
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str, parent: Option<&str>) -> Folder {
        Folder {
            name: name.to_owned(),
            parent: parent.map(str::to_owned),
        }
    }

    #[test]
    fn a_folder_path_runs_from_the_root_down_and_stops_on_a_loop() {
        let folders = HashMap::from([
            ("f1".to_owned(), folder("Reports", None)),
            ("f2".to_owned(), folder("Daily", Some("f1"))),
            ("a".to_owned(), folder("A", Some("b"))),
            ("b".to_owned(), folder("B", Some("a"))),
        ]);

        assert_eq!(folder_path(Some("f2".to_owned()), &folders), ["Reports", "Daily"]);
        assert_eq!(folder_path(Some("a".to_owned()), &folders), ["B", "A"]);
        assert!(folder_path(Some("gone".to_owned()), &folders).is_empty());
        assert!(folder_path(None, &folders).is_empty());
    }

    #[test]
    fn a_layout_nests_groups_and_reads_the_first_flat_form() {
        let layout: Layout = serde_json::from_str(
            r#"{"groups":[{"id":"g1","name":"Prod"},{"id":"g2","name":"EU"},{"id":"g3","name":"Old"}],
                "order":[{"type":"connection","id":"top"},
                    {"type":"group","id":"g1","children":[{"type":"group","id":"g2","children":[
                        {"type":"connection","id":"deep"}]}]},
                    {"type":"group","id":"g3","connectionIds":["flat"]},
                    {"type":"group","id":"nameless","children":[{"type":"connection","id":"loose"}]}]}"#,
        )
        .expect("a layout");
        let names: HashMap<&str, &str> = layout
            .groups
            .iter()
            .map(|group| (group.id.as_str(), group.name.as_str()))
            .collect();
        let mut paths = HashMap::new();

        walk(&layout.order, &names, &mut Vec::new(), &mut paths);

        assert_eq!(paths["top"], Vec::<String>::new());
        assert_eq!(paths["deep"], ["Prod", "EU"]);
        assert_eq!(paths["flat"], ["Old"]);
        assert_eq!(paths["loose"], Vec::<String>::new());
    }
}
