use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::StorageError;
use crate::file_access::{lock_path, read_bounded, write_atomically};

const CURRENT_VERSION: u32 = 1;
const MAX_FAVORITES: usize = 500;
const MAX_FAVORITES_FILE_BYTES: usize = 16 * 1024 * 1024;
const MAX_FAVORITE_NAME_BYTES: usize = 512;
const MAX_FAVORITE_SQL_BYTES: usize = 1024 * 1024;
const MAX_DRIVER_ID_BYTES: usize = 128;
const KNOWN_FILE_FIELDS: &[&str] = &["version", "favorites"];
const KNOWN_FAVORITE_FIELDS: &[&str] = &[
    "id",
    "name",
    "sql",
    "driver_id",
    "connection_id",
    "created_at",
    "last_used_at",
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedQuery {
    pub id: Uuid,
    pub name: String,
    pub sql: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub driver_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub connection_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<DateTime<Utc>>,
}

impl SavedQuery {
    pub fn new(name: String, sql: String, driver_id: Option<String>, connection_id: Option<Uuid>) -> Self {
        Self {
            id: Uuid::new_v4(),
            name,
            sql,
            driver_id,
            connection_id,
            created_at: Utc::now(),
            last_used_at: None,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct FavoritesFile {
    version: u32,
    #[serde(default)]
    favorites: Vec<SavedQuery>,
}

pub async fn load_favorites() -> Result<Vec<SavedQuery>, StorageError> {
    load_from(&favorites_path()?).await
}

pub async fn save_favorite(favorite: SavedQuery) -> Result<Vec<SavedQuery>, StorageError> {
    save_favorite_to(&favorites_path()?, favorite).await
}

pub async fn delete_favorite(id: Uuid) -> Result<Vec<SavedQuery>, StorageError> {
    delete_favorite_from(&favorites_path()?, id).await
}

pub async fn touch_favorite(id: Uuid) -> Result<(), StorageError> {
    touch_favorite_from(&favorites_path()?, id).await
}

async fn save_favorite_to(path: &Path, favorite: SavedQuery) -> Result<Vec<SavedQuery>, StorageError> {
    validate_favorite(&favorite)?;
    let _guard = lock_path(path).await?;
    let (mut existing, stored) = load_document(path).await?;
    upsert(&mut existing, favorite)?;
    save_to_unlocked(path, &existing, stored.as_ref()).await?;
    Ok(existing)
}

async fn delete_favorite_from(path: &Path, id: Uuid) -> Result<Vec<SavedQuery>, StorageError> {
    let _guard = lock_path(path).await?;
    let (mut existing, stored) = load_document(path).await?;
    existing.retain(|favorite| favorite.id != id);
    save_to_unlocked(path, &existing, stored.as_ref()).await?;
    Ok(existing)
}

async fn touch_favorite_from(path: &Path, id: Uuid) -> Result<(), StorageError> {
    let _guard = lock_path(path).await?;
    let (mut existing, stored) = load_document(path).await?;
    let Some(favorite) = existing.iter_mut().find(|favorite| favorite.id == id) else {
        return Ok(());
    };
    favorite.last_used_at = Some(Utc::now());
    save_to_unlocked(path, &existing, stored.as_ref()).await
}

pub(crate) fn upsert(existing: &mut Vec<SavedQuery>, favorite: SavedQuery) -> Result<(), StorageError> {
    validate_favorite(&favorite)?;
    if let Some(slot) = existing.iter_mut().find(|candidate| candidate.id == favorite.id) {
        *slot = favorite;
        return Ok(());
    }
    if let Some(slot) = existing
        .iter_mut()
        .find(|candidate| candidate.name.eq_ignore_ascii_case(favorite.name.trim()))
    {
        let id = slot.id;
        *slot = SavedQuery { id, ..favorite };
        return Ok(());
    }
    if existing.len() >= MAX_FAVORITES {
        return Err(StorageError::Schema(format!(
            "favorites are limited to {MAX_FAVORITES} entries"
        )));
    }
    existing.push(favorite);
    Ok(())
}

fn validate_favorite(favorite: &SavedQuery) -> Result<(), StorageError> {
    validate_required_text(
        &favorite.name,
        MAX_FAVORITE_NAME_BYTES,
        "a favorite needs a name",
        "favorite name",
    )?;
    validate_required_text(
        &favorite.sql,
        MAX_FAVORITE_SQL_BYTES,
        "a favorite needs a statement",
        "favorite statement",
    )?;
    if let Some(driver_id) = favorite.driver_id.as_deref()
        && driver_id.len() > MAX_DRIVER_ID_BYTES
    {
        return Err(StorageError::TooLarge {
            got: driver_id.len(),
            limit: MAX_DRIVER_ID_BYTES,
        });
    }
    Ok(())
}

fn validate_required_text(value: &str, limit: usize, empty_error: &str, field: &str) -> Result<(), StorageError> {
    if value.trim().is_empty() {
        return Err(StorageError::Schema(empty_error.into()));
    }
    if value.len() > limit {
        return Err(StorageError::Schema(format!("{field} exceeds {limit} bytes")));
    }
    Ok(())
}

pub fn rank_favorites(favorites: &[SavedQuery]) -> Vec<SavedQuery> {
    let mut ordered = favorites.to_vec();
    ordered.sort_by(|left, right| {
        right
            .last_used_at
            .cmp(&left.last_used_at)
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
    });
    ordered
}

pub fn matches_filter(favorite: &SavedQuery, filter: &str) -> bool {
    let needle = filter.trim().to_lowercase();
    if needle.is_empty() {
        return true;
    }
    favorite.name.to_lowercase().contains(&needle) || favorite.sql.to_lowercase().contains(&needle)
}

pub(crate) async fn load_from(path: &Path) -> Result<Vec<SavedQuery>, StorageError> {
    load_document(path).await.map(|(favorites, _)| favorites)
}

async fn load_document(
    path: &Path,
) -> Result<(Vec<SavedQuery>, Option<serde_json::Map<String, serde_json::Value>>), StorageError> {
    let Some(bytes) = read_bounded(path, MAX_FAVORITES_FILE_BYTES).await? else {
        return Ok((Vec::new(), None));
    };
    let stored: serde_json::Value = serde_json::from_slice(&bytes)?;
    let stored = stored
        .as_object()
        .cloned()
        .ok_or_else(|| StorageError::Schema("favorites.json must contain an object".into()))?;
    let file: FavoritesFile = serde_json::from_value(serde_json::Value::Object(stored.clone()))?;
    if file.version != CURRENT_VERSION {
        return Err(StorageError::Schema(format!(
            "favorites.json version {} not supported (expected {})",
            file.version, CURRENT_VERSION,
        )));
    }
    if file.favorites.len() > MAX_FAVORITES {
        return Err(StorageError::Schema(format!(
            "favorites are limited to {MAX_FAVORITES} entries"
        )));
    }
    for favorite in &file.favorites {
        validate_favorite(favorite)?;
    }
    Ok((file.favorites, Some(stored)))
}

#[cfg(test)]
pub(crate) async fn save_to(path: &Path, favorites: &[SavedQuery]) -> Result<(), StorageError> {
    for favorite in favorites {
        validate_favorite(favorite)?;
    }
    if favorites.len() > MAX_FAVORITES {
        return Err(StorageError::Schema(format!(
            "favorites are limited to {MAX_FAVORITES} entries"
        )));
    }
    let _guard = lock_path(path).await?;
    let (_, stored) = load_document(path).await?;
    save_to_unlocked(path, favorites, stored.as_ref()).await
}

async fn save_to_unlocked(
    path: &Path,
    favorites: &[SavedQuery],
    stored: Option<&serde_json::Map<String, serde_json::Value>>,
) -> Result<(), StorageError> {
    let file = FavoritesFile {
        version: CURRENT_VERSION,
        favorites: favorites.to_vec(),
    };
    let mut document = serde_json::to_value(file)?;
    if let Some(stored) = stored {
        carry_unknown_fields(&mut document, stored);
    }
    let json = serde_json::to_vec_pretty(&document)?;
    if json.len() > MAX_FAVORITES_FILE_BYTES {
        return Err(StorageError::TooLarge {
            got: json.len(),
            limit: MAX_FAVORITES_FILE_BYTES,
        });
    }
    write_atomically(path, &json).await
}

fn carry_unknown_fields(document: &mut serde_json::Value, stored: &serde_json::Map<String, serde_json::Value>) {
    let Some(fresh) = document.as_object_mut() else {
        return;
    };
    for (key, value) in stored {
        if !KNOWN_FILE_FIELDS.contains(&key.as_str()) {
            fresh.insert(key.clone(), value.clone());
        }
    }
    let Some(stored_entries) = stored.get("favorites").and_then(serde_json::Value::as_array) else {
        return;
    };
    let Some(fresh_entries) = fresh.get_mut("favorites").and_then(serde_json::Value::as_array_mut) else {
        return;
    };
    for entry in fresh_entries {
        let Some(id) = entry.get("id").and_then(serde_json::Value::as_str).map(str::to_owned) else {
            continue;
        };
        let Some(previous) = stored_entries
            .iter()
            .filter_map(serde_json::Value::as_object)
            .find(|candidate| candidate.get("id").and_then(serde_json::Value::as_str) == Some(id.as_str()))
        else {
            continue;
        };
        let Some(target) = entry.as_object_mut() else {
            continue;
        };
        for (key, value) in previous {
            if !KNOWN_FAVORITE_FIELDS.contains(&key.as_str()) {
                target.insert(key.clone(), value.clone());
            }
        }
    }
}

fn favorites_path() -> Result<PathBuf, StorageError> {
    crate::config_path("favorites.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn favorite(name: &str, sql: &str) -> SavedQuery {
        SavedQuery::new(name.to_string(), sql.to_string(), Some("postgres".into()), None)
    }

    #[test]
    fn a_favorite_needs_a_name_and_a_statement() {
        let mut existing = Vec::new();
        assert!(upsert(&mut existing, favorite("  ", "SELECT 1")).is_err());
        assert!(upsert(&mut existing, favorite("name", "   ")).is_err());
        assert!(existing.is_empty());
    }

    #[test]
    fn saving_the_same_name_replaces_the_statement_and_keeps_the_id() {
        let mut existing = Vec::new();
        upsert(&mut existing, favorite("Daily", "SELECT 1")).expect("first save");
        let id = existing[0].id;

        upsert(&mut existing, favorite("daily", "SELECT 2")).expect("second save");

        assert_eq!(existing.len(), 1);
        assert_eq!(existing[0].id, id);
        assert_eq!(existing[0].sql, "SELECT 2");
    }

    #[test]
    fn saving_the_same_id_updates_in_place() {
        let mut existing = Vec::new();
        upsert(&mut existing, favorite("Daily", "SELECT 1")).expect("first save");
        let mut edited = existing[0].clone();
        edited.name = "Renamed".into();

        upsert(&mut existing, edited).expect("edit");

        assert_eq!(existing.len(), 1);
        assert_eq!(existing[0].name, "Renamed");
    }

    #[test]
    fn favorites_are_capped() {
        let mut existing: Vec<SavedQuery> = (0..MAX_FAVORITES)
            .map(|index| favorite(&format!("q{index}"), "SELECT 1"))
            .collect();
        assert!(upsert(&mut existing, favorite("one more", "SELECT 1")).is_err());
        assert_eq!(existing.len(), MAX_FAVORITES);
    }

    #[test]
    fn ranking_puts_recently_used_first_then_sorts_by_name() {
        let mut recent = favorite("zeta", "SELECT 1");
        recent.last_used_at = Some(Utc::now());
        let older = favorite("alpha", "SELECT 2");
        let middle = favorite("beta", "SELECT 3");

        let ranked = rank_favorites(&[older, middle, recent]);

        assert_eq!(ranked[0].name, "zeta");
        assert_eq!(ranked[1].name, "alpha");
        assert_eq!(ranked[2].name, "beta");
    }

    #[test]
    fn filtering_matches_name_and_statement_case_insensitively() {
        let entry = favorite("Daily revenue", "SELECT sum(total) FROM orders");
        assert!(matches_filter(&entry, ""));
        assert!(matches_filter(&entry, "daily"));
        assert!(matches_filter(&entry, "ORDERS"));
        assert!(!matches_filter(&entry, "customers"));
    }

    #[tokio::test]
    async fn favorites_round_trip_through_a_file() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let path = dir.path().join("favorites.json");

        let entries = vec![favorite("Daily", "SELECT 1")];
        save_to(&path, &entries).await.expect("save");
        let loaded = load_from(&path).await.expect("load");

        assert_eq!(loaded, entries);
    }

    #[tokio::test]
    async fn a_missing_file_loads_as_empty() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let loaded = load_from(&dir.path().join("favorites.json")).await.expect("load");
        assert!(loaded.is_empty());
    }

    #[tokio::test]
    async fn an_unsupported_version_is_rejected() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let path = dir.path().join("favorites.json");
        tokio::fs::write(&path, br#"{"version":99,"favorites":[]}"#)
            .await
            .expect("write");

        assert!(load_from(&path).await.is_err());
    }

    #[tokio::test]
    async fn a_malformed_file_is_preserved_and_blocks_a_save() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let path = dir.path().join("favorites.json");
        let malformed = b"{not valid json";
        tokio::fs::write(&path, malformed).await.expect("write");

        assert!(save_favorite_to(&path, favorite("Daily", "SELECT 1")).await.is_err());
        assert_eq!(tokio::fs::read(&path).await.expect("read"), malformed);
    }

    #[tokio::test]
    async fn unknown_file_and_favorite_fields_survive_an_update() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let path = dir.path().join("favorites.json");
        let mut entry = favorite("Daily", "SELECT 1");
        save_to(&path, std::slice::from_ref(&entry))
            .await
            .expect("initial save");
        let mut document: serde_json::Value =
            serde_json::from_slice(&tokio::fs::read(&path).await.expect("read")).expect("json");
        document["future_section"] = serde_json::json!({ "keep": true });
        document["favorites"][0]["display_color"] = serde_json::json!("teal");
        tokio::fs::write(&path, serde_json::to_vec_pretty(&document).expect("serialize"))
            .await
            .expect("write");
        entry.sql = "SELECT 2".into();

        save_favorite_to(&path, entry).await.expect("update");

        let rewritten: serde_json::Value =
            serde_json::from_slice(&tokio::fs::read(&path).await.expect("read")).expect("json");
        assert_eq!(rewritten["future_section"]["keep"], true);
        assert_eq!(rewritten["favorites"][0]["display_color"], "teal");
        assert_eq!(rewritten["favorites"][0]["sql"], "SELECT 2");
    }
}
