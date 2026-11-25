use sqlx::SqliteConnection;

use crate::StorageError;

// The list a record is ordered in: its connection's records in that place and those with no
// connection, which show in every connection; a record with no connection, those with none.
pub(super) async fn query_place(
    database: &mut SqliteConnection,
    owner: Option<&str>,
    folder: Option<&str>,
) -> Result<Vec<i64>, StorageError> {
    Ok(sqlx::query_scalar(
        "SELECT id FROM saved_queries WHERE (connection_id IS ?1 OR connection_id IS NULL) \
         AND folder_record_id IS ?2 ORDER BY sort_order, name COLLATE NOCASE, id",
    )
    .bind(owner)
    .bind(folder)
    .fetch_all(&mut *database)
    .await?)
}

// SQLite turns an integer that overflows into a REAL, so the next position is counted here. A pulled order at
// the end of the range renumbers the place from 0 first.
pub(super) async fn next_query_order(
    database: &mut SqliteConnection,
    owner: Option<&str>,
    folder: Option<&str>,
) -> Result<i64, StorageError> {
    let highest: Option<i64> = sqlx::query_scalar(
        "SELECT MAX(sort_order) FROM saved_queries \
         WHERE (connection_id IS ?1 OR connection_id IS NULL) AND folder_record_id IS ?2",
    )
    .bind(owner)
    .bind(folder)
    .fetch_one(&mut *database)
    .await?;
    match highest.map(|highest| highest.checked_add(1)) {
        None => Ok(0),
        Some(Some(next)) => Ok(next),
        Some(None) => {
            let place = query_place(database, owner, folder).await?;
            set_query_order(database, &place).await?;
            Ok(i64::try_from(place.len()).unwrap_or(i64::MAX))
        }
    }
}

pub(super) async fn set_query_order(database: &mut SqliteConnection, ids: &[i64]) -> Result<(), StorageError> {
    for (order, id) in ids.iter().enumerate() {
        sqlx::query("UPDATE saved_queries SET sort_order = ? WHERE id = ? AND sort_order <> ?")
            .bind(order as i64)
            .bind(id)
            .bind(order as i64)
            .execute(&mut *database)
            .await?;
    }
    Ok(())
}

pub(super) async fn compact_queries(
    database: &mut SqliteConnection,
    owner: Option<&str>,
    folder: Option<&str>,
) -> Result<(), StorageError> {
    let ids = query_place(database, owner, folder).await?;
    set_query_order(database, &ids).await
}

pub(super) async fn folder_place(
    database: &mut SqliteConnection,
    owner: Option<&str>,
    parent: Option<&str>,
) -> Result<Vec<i64>, StorageError> {
    Ok(sqlx::query_scalar(
        "SELECT id FROM saved_query_folders WHERE (connection_id IS ?1 OR connection_id IS NULL) \
         AND parent_record_id IS ?2 ORDER BY sort_order, name COLLATE NOCASE, id",
    )
    .bind(owner)
    .bind(parent)
    .fetch_all(&mut *database)
    .await?)
}

pub(super) async fn next_folder_order(
    database: &mut SqliteConnection,
    owner: Option<&str>,
    parent: Option<&str>,
) -> Result<i64, StorageError> {
    let highest: Option<i64> = sqlx::query_scalar(
        "SELECT MAX(sort_order) FROM saved_query_folders \
         WHERE (connection_id IS ?1 OR connection_id IS NULL) AND parent_record_id IS ?2",
    )
    .bind(owner)
    .bind(parent)
    .fetch_one(&mut *database)
    .await?;
    match highest.map(|highest| highest.checked_add(1)) {
        None => Ok(0),
        Some(Some(next)) => Ok(next),
        Some(None) => {
            compact_folders(database, owner, parent).await?;
            let place = folder_place(database, owner, parent).await?;
            Ok(i64::try_from(place.len()).unwrap_or(i64::MAX))
        }
    }
}

pub(super) async fn compact_folders(
    database: &mut SqliteConnection,
    owner: Option<&str>,
    parent: Option<&str>,
) -> Result<(), StorageError> {
    let ids = folder_place(database, owner, parent).await?;
    for (order, id) in ids.into_iter().enumerate() {
        sqlx::query("UPDATE saved_query_folders SET sort_order = ? WHERE id = ? AND sort_order <> ?")
            .bind(order as i64)
            .bind(id)
            .bind(order as i64)
            .execute(&mut *database)
            .await?;
    }
    Ok(())
}
