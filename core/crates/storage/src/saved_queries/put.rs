// Records a pull, a move from iCloud or the Mac's own store bring, each under its own id. Two of them,
// or one of them and one this store holds, can meet in one place under one name or one keyword; every
// device settles that the same way (core ADR 0052, Collisions).

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::SystemTime;

use sqlx::{AssertSqlSafe, SqliteConnection};
use uuid::Uuid;

use crate::StorageError;
use crate::name_rules;
use crate::unix_time::to_unix_millis;

use super::folders::{SavedQueryFolder, name_key};
use super::{MAX_QUERY_BYTES, SavedQuery, keyword_key};

const IDS_PER_STATEMENT: usize = 500;

// The record created first keeps the place: the earliest `created_at`, then the lowest id compared as
// bytes, which orders the upper-case text the wire carries the same way.
pub(super) fn holds_first(left: (i64, Uuid), right: (i64, Uuid)) -> Ordering {
    left.0.cmp(&right.0).then_with(|| left.1.as_bytes().cmp(right.1.as_bytes()))
}

// `<name> (2)`, `<name> (3)` and on, the first that nobody in the place holds.
pub(super) fn free_name(name: &str, taken: impl Fn(&str) -> bool) -> String {
    let mut number: u64 = 2;
    loop {
        let candidate = format!("{name} ({number})");
        if !taken(&candidate) {
            return candidate;
        }
        number += 1;
    }
}

// A keyword with no connection expands in every connection, so it meets every other.
fn scopes_meet(left: Option<&str>, right: Option<&str>) -> bool {
    left.is_none() || right.is_none() || left == right
}

struct Query {
    rowid: Option<i64>,
    id: Uuid,
    owner: Option<String>,
    name: String,
    keyword: Option<String>,
    created_at: i64,
    settled: bool,
}

pub(super) async fn put_queries(
    database: &mut SqliteConnection,
    incoming: &[SavedQuery],
    now: SystemTime,
) -> Result<Vec<Uuid>, StorageError> {
    let incoming = latest_versions(incoming, |query| query.id);
    for query in &incoming {
        if query.name.trim().is_empty() {
            return Err(StorageError::EmptyName);
        }
        if query.query.len() > MAX_QUERY_BYTES {
            return Err(StorageError::TooLarge {
                got: query.query.len(),
                limit: MAX_QUERY_BYTES,
            });
        }
    }
    let stored: Vec<(i64, String, Option<String>, String, Option<String>, i64)> =
        sqlx::query_as("SELECT id, record_id, connection_id, name, keyword, created_at FROM saved_queries")
            .fetch_all(&mut *database)
            .await?;
    let mut world: BTreeMap<Uuid, Query> = BTreeMap::new();
    for (rowid, id, owner, name, keyword, created_at) in stored {
        let id = Uuid::parse_str(&id).map_err(|_| StorageError::Schema("record_id is not a UUID".to_owned()))?;
        world.insert(
            id,
            Query {
                rowid: Some(rowid),
                id,
                owner,
                name,
                keyword,
                created_at,
                settled: false,
            },
        );
    }
    for query in &incoming {
        let rowid = world.get(&query.id).and_then(|held| held.rowid);
        world.insert(
            query.id,
            Query {
                rowid,
                id: query.id,
                owner: query.connection_id.map(|id| id.to_string()),
                name: query.name.clone(),
                keyword: query.keyword.clone().filter(|word| !word.trim().is_empty()),
                created_at: to_unix_millis(query.created_at),
                settled: false,
            },
        );
    }
    settle_query_names(&mut world);
    let touched: HashSet<String> = incoming
        .iter()
        .filter_map(|query| world.get(&query.id)?.keyword.as_deref().map(keyword_key))
        .collect();
    settle_keywords(&mut world, &touched);

    let incoming_ids: HashSet<Uuid> = incoming.iter().map(|query| query.id).collect();
    let replaced: Vec<i64> = incoming
        .iter()
        .filter_map(|query| world.get(&query.id)?.rowid)
        .collect();
    delete_rows(database, "saved_queries", &replaced).await?;
    let stamp = to_unix_millis(now);
    for query in world.values().filter(|query| query.settled && !incoming_ids.contains(&query.id)) {
        sqlx::query("UPDATE saved_queries SET name = ?, keyword = ?, updated_at = ? WHERE id = ?")
            .bind(&query.name)
            .bind(&query.keyword)
            .bind(stamp)
            .bind(query.rowid)
            .execute(&mut *database)
            .await?;
    }
    for query in &incoming {
        let Some(settled) = world.get(&query.id) else {
            continue;
        };
        let updated_at = match settled.settled {
            true => stamp,
            false => to_unix_millis(query.updated_at),
        };
        sqlx::query(
            "INSERT INTO saved_queries (id, record_id, name, query, connection_id, connection_name, keyword, \
             folder_record_id, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(settled.rowid)
        .bind(query.id.to_string())
        .bind(&settled.name)
        .bind(&query.query)
        .bind(&settled.owner)
        .bind(&query.connection_name)
        .bind(&settled.keyword)
        .bind(query.folder_id.map(|id| id.to_string()))
        .bind(query.order)
        .bind(settled.created_at)
        .bind(updated_at)
        .execute(&mut *database)
        .await?;
    }
    Ok(world
        .values()
        .filter(|query| query.settled)
        .map(|query| query.id)
        .collect())
}

// The store holds no two queries of one connection, or of none, under one name, so every pair here
// has one of the incoming in it.
fn settle_query_names(world: &mut BTreeMap<Uuid, Query>) {
    let mut places: BTreeMap<(Option<String>, String), Vec<(i64, Uuid)>> = BTreeMap::new();
    let mut held: HashMap<Option<String>, HashSet<String>> = HashMap::new();
    for query in world.values() {
        places
            .entry((query.owner.clone(), query.name.clone()))
            .or_default()
            .push((query.created_at, query.id));
        held.entry(query.owner.clone()).or_default().insert(query.name.clone());
    }
    for ((owner, name), mut contenders) in places {
        if contenders.len() < 2 {
            continue;
        }
        contenders.sort_by(|left, right| holds_first(*left, *right));
        let taken = held.entry(owner).or_default();
        for (_, id) in contenders.into_iter().skip(1) {
            let renamed = free_name(&name, |candidate| taken.contains(candidate));
            taken.insert(renamed.clone());
            if let Some(query) = world.get_mut(&id) {
                query.name = renamed;
                query.settled = true;
            }
        }
    }
}

// In the order the rule gives, a record keeps its keyword unless one that meets it kept it first.
fn settle_keywords(world: &mut BTreeMap<Uuid, Query>, touched: &HashSet<String>) {
    let mut keys: Vec<&String> = touched.iter().collect();
    keys.sort();
    for key in keys {
        let mut holders: Vec<(i64, Uuid, Option<String>)> = world
            .values()
            .filter(|query| query.keyword.as_deref().map(keyword_key).as_ref() == Some(key))
            .map(|query| (query.created_at, query.id, query.owner.clone()))
            .collect();
        holders.sort_by(|left, right| holds_first((left.0, left.1), (right.0, right.1)));
        let mut kept: Vec<Option<String>> = Vec::new();
        for (_, id, owner) in holders {
            if kept.iter().any(|scope| scopes_meet(scope.as_deref(), owner.as_deref())) {
                if let Some(query) = world.get_mut(&id) {
                    query.keyword = None;
                    query.settled = true;
                }
            } else {
                kept.push(owner);
            }
        }
    }
}

struct Folder {
    rowid: Option<i64>,
    id: Uuid,
    owner: Option<String>,
    parent: Option<Uuid>,
    name: String,
    created_at: i64,
    settled: bool,
}

pub(super) async fn put_folders(
    database: &mut SqliteConnection,
    incoming: &[SavedQueryFolder],
    now: SystemTime,
) -> Result<Vec<Uuid>, StorageError> {
    let incoming = latest_versions(incoming, |folder| folder.id);
    if incoming
        .iter()
        .any(|folder| name_rules::shown(&folder.name).is_empty())
    {
        return Err(StorageError::EmptyName);
    }
    let stored: Vec<(i64, String, Option<String>, Option<String>, String, i64)> = sqlx::query_as(
        "SELECT id, record_id, connection_id, parent_record_id, name, created_at FROM saved_query_folders",
    )
    .fetch_all(&mut *database)
    .await?;
    let parse = |text: &str| {
        Uuid::parse_str(text).map_err(|_| StorageError::Schema("saved query folder id is not a UUID".to_owned()))
    };
    let mut world: BTreeMap<Uuid, Folder> = BTreeMap::new();
    for (rowid, id, owner, parent, name, created_at) in stored {
        let id = parse(&id)?;
        world.insert(
            id,
            Folder {
                rowid: Some(rowid),
                id,
                owner,
                parent: parent.as_deref().map(parse).transpose()?,
                name,
                created_at,
                settled: false,
            },
        );
    }
    for folder in &incoming {
        let rowid = world.get(&folder.id).and_then(|held| held.rowid);
        world.insert(
            folder.id,
            Folder {
                rowid,
                id: folder.id,
                owner: folder.connection_id.map(|id| id.to_string()),
                parent: folder.parent_id,
                name: folder.name.clone(),
                created_at: to_unix_millis(folder.created_at),
                settled: false,
            },
        );
    }
    if let Some(id) = incoming.iter().map(|folder| folder.id).find(|id| on_cycle(&world, *id)) {
        return Err(StorageError::FolderCycle { id });
    }
    settle_folder_names(&mut world);

    let incoming_ids: HashSet<Uuid> = incoming.iter().map(|folder| folder.id).collect();
    let replaced: Vec<i64> = incoming
        .iter()
        .filter_map(|folder| world.get(&folder.id)?.rowid)
        .collect();
    delete_rows(database, "saved_query_folders", &replaced).await?;
    let stamp = to_unix_millis(now);
    for folder in world.values().filter(|folder| folder.settled && !incoming_ids.contains(&folder.id)) {
        sqlx::query("UPDATE saved_query_folders SET name = ?, updated_at = ? WHERE id = ?")
            .bind(&folder.name)
            .bind(stamp)
            .bind(folder.rowid)
            .execute(&mut *database)
            .await?;
    }
    for folder in &incoming {
        let Some(settled) = world.get(&folder.id) else {
            continue;
        };
        let updated_at = match settled.settled {
            true => stamp,
            false => to_unix_millis(folder.updated_at),
        };
        sqlx::query(
            "INSERT INTO saved_query_folders (id, record_id, connection_id, name, parent_record_id, sort_order, \
             created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(settled.rowid)
        .bind(folder.id.to_string())
        .bind(&settled.owner)
        .bind(&settled.name)
        .bind(folder.parent_id.map(|id| id.to_string()))
        .bind(folder.order)
        .bind(settled.created_at)
        .bind(updated_at)
        .execute(&mut *database)
        .await?;
    }
    Ok(world
        .values()
        .filter(|folder| folder.settled)
        .map(|folder| folder.id)
        .collect())
}

// A parent this store does not hold ends the walk, as it reads as the top level.
fn on_cycle(world: &BTreeMap<Uuid, Folder>, start: Uuid) -> bool {
    let mut visited = HashSet::from([start]);
    let mut above = world.get(&start).and_then(|folder| folder.parent);
    while let Some(id) = above {
        if !visited.insert(id) {
            return true;
        }
        above = world.get(&id).and_then(|folder| folder.parent);
    }
    false
}

type FolderPlace = (Option<String>, Option<Uuid>);

fn settle_folder_names(world: &mut BTreeMap<Uuid, Folder>) {
    let mut places: BTreeMap<(FolderPlace, String), Vec<(i64, Uuid)>> = BTreeMap::new();
    let mut held: HashMap<FolderPlace, HashSet<String>> = HashMap::new();
    for folder in world.values() {
        let place = (folder.owner.clone(), folder.parent);
        places
            .entry((place.clone(), name_key(&folder.name)))
            .or_default()
            .push((folder.created_at, folder.id));
        held.entry(place).or_default().insert(name_key(&folder.name));
    }
    for ((place, _), mut contenders) in places {
        if contenders.len() < 2 {
            continue;
        }
        contenders.sort_by(|left, right| holds_first(*left, *right));
        let taken = held.entry(place).or_default();
        for (_, id) in contenders.into_iter().skip(1) {
            let Some(folder) = world.get_mut(&id) else {
                continue;
            };
            let renamed = free_name(&folder.name, |candidate| taken.contains(&name_key(candidate)));
            taken.insert(name_key(&renamed));
            folder.name = renamed;
            folder.settled = true;
        }
    }
}

// A record listed twice is written once, as its last version, in the place its first came.
fn latest_versions<T: Clone>(records: &[T], id: impl Fn(&T) -> Uuid) -> Vec<T> {
    let mut order: Vec<Uuid> = Vec::new();
    let mut latest: HashMap<Uuid, T> = HashMap::new();
    for record in records {
        if latest.insert(id(record), record.clone()).is_none() {
            order.push(id(record));
        }
    }
    order.into_iter().filter_map(|id| latest.remove(&id)).collect()
}

async fn delete_rows(database: &mut SqliteConnection, table: &str, ids: &[i64]) -> Result<(), StorageError> {
    for chunk in ids.chunks(IDS_PER_STATEMENT) {
        let sql = format!("DELETE FROM {table} WHERE id IN ({})", vec!["?"; chunk.len()].join(","));
        let mut statement = sqlx::query(AssertSqlSafe(sql));
        for id in chunk {
            statement = statement.bind(id);
        }
        statement.execute(&mut *database).await?;
    }
    Ok(())
}
