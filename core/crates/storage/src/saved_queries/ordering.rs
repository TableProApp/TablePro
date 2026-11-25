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

pub(super) async fn next_query_order(
    database: &mut SqliteConnection,
    owner: Option<&str>,
    folder: Option<&str>,
) -> Result<i64, StorageError> {
    Ok(sqlx::query_scalar(
        "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM saved_queries \
         WHERE (connection_id IS ?1 OR connection_id IS NULL) AND folder_record_id IS ?2",
    )
    .bind(owner)
    .bind(folder)
    .fetch_one(&mut *database)
    .await?)
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
    Ok(sqlx::query_scalar(
        "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM saved_query_folders \
         WHERE (connection_id IS ?1 OR connection_id IS NULL) AND parent_record_id IS ?2",
    )
    .bind(owner)
    .bind(parent)
    .fetch_one(&mut *database)
    .await?)
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
