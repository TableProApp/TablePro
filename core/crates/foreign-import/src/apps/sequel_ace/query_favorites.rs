use std::path::Path;

use plist::{Dictionary, Value};
use tokio_util::sync::CancellationToken;

use super::{read_dictionary, text};
use crate::app::check_cancel;
use crate::{ForeignImportError, ForeignSavedQuery, SavedQueryContent};

pub(super) fn saved_queries(
    preferences: &Path,
    limit: u64,
    cancel: &CancellationToken,
) -> Result<Vec<ForeignSavedQuery>, ForeignImportError> {
    let mut queries = Vec::new();
    for favorite in favorites(preferences) {
        check_cancel(cancel)?;
        let Some(sql) = query_text(&favorite) else {
            continue;
        };
        let byte_count = u64::try_from(sql.len()).unwrap_or(u64::MAX);
        queries.push(ForeignSavedQuery {
            name: text(&favorite, "name").unwrap_or_default().to_owned(),
            content: if byte_count > limit {
                SavedQueryContent::Oversized { byte_count }
            } else {
                SavedQueryContent::Text(sql.to_owned())
            },
            keyword: text(&favorite, "tabtrigger").map(str::to_owned),
            folder_path: Vec::new(),
            source_connection_id: None,
            is_auto_named: false,
        });
    }
    Ok(queries)
}

pub(super) fn count(preferences: &Path) -> usize {
    favorites(preferences)
        .iter()
        .filter(|favorite| query_text(favorite).is_some())
        .count()
}

fn query_text(favorite: &Dictionary) -> Option<&str> {
    text(favorite, "query").filter(|sql| !sql.trim().is_empty())
}

fn favorites(preferences: &Path) -> Vec<Dictionary> {
    let Some(Value::Array(items)) = read_dictionary(preferences).and_then(|mut root| root.remove("queryFavorites"))
    else {
        return Vec::new();
    };
    items
        .into_iter()
        .map(Value::into_dictionary)
        .collect::<Option<Vec<_>>>()
        .unwrap_or_default()
}
