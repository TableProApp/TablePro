use std::collections::{HashMap, HashSet};

use tokio_util::sync::CancellationToken;

use crate::app::check_cancel;
use crate::apps::sqlite::Database;
use crate::{ForeignImportError, ForeignSavedQuery, SavedQueryContent};

// Every install seeds this example, so importing it would add noise to every library.
const SEEDED_DEMO_TITLE: &str = "Demo Query";

struct Folder {
    name: String,
    parent_id: Option<i64>,
}

pub(super) fn read(
    db: &Database,
    limit: u64,
    cancel: &CancellationToken,
) -> Result<Vec<ForeignSavedQuery>, ForeignImportError> {
    let columns = column_names(db, "favorite_query");
    if !columns.contains("title") || !columns.contains("text") {
        return Ok(Vec::new());
    }

    let folders = if columns.contains("queryFolderId") {
        read_folders(db)
    } else {
        HashMap::new()
    };
    let folder_column = if folders.is_empty() { "NULL" } else { "queryFolderId" };
    let sql = format!(
        "SELECT title, CASE WHEN length(CAST(text AS BLOB)) > ? THEN NULL ELSE text END, \
         length(CAST(text AS BLOB)), {folder_column} FROM favorite_query {} ORDER BY id",
        where_clause(&columns, &[])
    );
    let Some(mut statement) = db.prepare(&sql) else {
        return Ok(Vec::new());
    };
    statement.bind_int64(1, i64::try_from(limit).unwrap_or(i64::MAX));

    let mut queries = Vec::new();
    while let Some(row) = statement.next_row() {
        check_cancel(cancel)?;
        let title = row.text(0).unwrap_or_default();
        if title == SEEDED_DEMO_TITLE {
            continue;
        }
        let byte_count = u64::try_from(row.int64(2)).unwrap_or(0);
        let content = if byte_count > limit {
            SavedQueryContent::Oversized { byte_count }
        } else {
            match row.text(1) {
                // The blanks `count` trims in SQL, so the two agree on what a blank query is.
                Some(sql) if !sql.trim_matches([' ', '\t', '\n', '\r']).is_empty() => SavedQueryContent::Text(sql),
                _ => continue,
            }
        };
        queries.push(ForeignSavedQuery {
            name: title,
            content,
            keyword: None,
            folder_path: folder_path(row.optional_int64(3), &folders),
            source_connection_id: None,
            is_auto_named: false,
        });
    }
    Ok(queries)
}

pub(super) fn count(db: &Database) -> usize {
    let columns = column_names(db, "favorite_query");
    if !columns.contains("title") || !columns.contains("text") {
        return 0;
    }
    let conditions = [
        "title IS NOT ?",
        "trim(COALESCE(text, ''), ' ' || char(9) || char(10) || char(13)) != ''",
    ];
    let sql = format!(
        "SELECT COUNT(*) FROM favorite_query {}",
        where_clause(&columns, &conditions)
    );
    let Some(mut statement) = db.prepare(&sql) else {
        return 0;
    };
    statement.bind_text(1, SEEDED_DEMO_TITLE);
    statement
        .next_row()
        .map_or(0, |row| usize::try_from(row.int64(0)).unwrap_or(0))
}

// Rows of a cloud workspace belong to that workspace's server copy, as for connections.
fn where_clause(columns: &HashSet<String>, conditions: &[&str]) -> String {
    let all: Vec<&str> = columns
        .contains("workspaceId")
        .then_some("workspaceId = -1")
        .into_iter()
        .chain(conditions.iter().copied())
        .collect();
    if all.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", all.join(" AND "))
    }
}

fn read_folders(db: &Database) -> HashMap<i64, Folder> {
    let columns = column_names(db, "query_folder");
    if !columns.contains("id") || !columns.contains("name") {
        return HashMap::new();
    }
    let parent_column = if columns.contains("parentId") {
        "parentId"
    } else {
        "NULL"
    };
    let Some(mut statement) = db.prepare(&format!("SELECT id, name, {parent_column} FROM query_folder")) else {
        return HashMap::new();
    };

    let mut folders = HashMap::new();
    while let Some(row) = statement.next_row() {
        folders.insert(
            row.int64(0),
            Folder {
                name: row.text(1).unwrap_or_default(),
                parent_id: row.optional_int64(2),
            },
        );
    }
    folders
}

// A parent chain that loops ends at the first folder seen twice.
fn folder_path(folder_id: Option<i64>, folders: &HashMap<i64, Folder>) -> Vec<String> {
    let mut path = Vec::new();
    let mut visited = HashSet::new();
    let mut current = folder_id;
    while let Some(id) = current
        && visited.insert(id)
        && let Some(folder) = folders.get(&id)
    {
        path.push(folder.name.clone());
        current = folder.parent_id;
    }
    path.reverse();
    path
}

fn column_names(db: &Database, table: &str) -> HashSet<String> {
    let Some(mut statement) = db.prepare(&format!("PRAGMA table_info({table})")) else {
        return HashSet::new();
    };
    let mut names = HashSet::new();
    while let Some(row) = statement.next_row() {
        if let Some(name) = row.text(1) {
            names.insert(name);
        }
    }
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str, parent_id: Option<i64>) -> Folder {
        Folder {
            name: name.to_owned(),
            parent_id,
        }
    }

    #[test]
    fn a_folder_path_runs_from_the_root_down() {
        let folders = HashMap::from([(1, folder("Reports", None)), (2, folder("Daily", Some(1)))]);
        assert_eq!(folder_path(Some(2), &folders), ["Reports", "Daily"]);
        assert_eq!(folder_path(None, &folders), Vec::<String>::new());
        assert_eq!(folder_path(Some(9), &folders), Vec::<String>::new());
    }

    #[test]
    fn a_parent_chain_that_loops_stops_at_the_first_folder_seen_twice() {
        let folders = HashMap::from([
            (1, folder("A", Some(2))),
            (2, folder("B", Some(1))),
            (3, folder("C", Some(3))),
        ]);
        assert_eq!(folder_path(Some(1), &folders), ["B", "A"]);
        assert_eq!(folder_path(Some(3), &folders), ["C"]);
    }

    #[test]
    fn a_missing_parent_ends_the_path() {
        let folders = HashMap::from([(2, folder("Daily", Some(7)))]);
        assert_eq!(folder_path(Some(2), &folders), ["Daily"]);
    }

    #[test]
    fn the_workspace_filter_applies_only_when_the_column_exists() {
        let with = HashSet::from(["workspaceId".to_owned()]);
        assert_eq!(where_clause(&HashSet::new(), &[]), "");
        assert_eq!(where_clause(&with, &[]), "WHERE workspaceId = -1");
        assert_eq!(where_clause(&with, &["a", "b"]), "WHERE workspaceId = -1 AND a AND b");
    }
}
