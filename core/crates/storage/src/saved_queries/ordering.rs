use sqlx::SqliteConnection;

use crate::StorageError;

pub(super) async fn set_query_order(database: &mut SqliteConnection, ids: &[i64]) -> Result<(), StorageError> {
    for (order, id) in ids.iter().enumerate() {
        sqlx::query("UPDATE saved_queries SET sort_order = ? WHERE id = ?")
            .bind(order as i64)
            .bind(id)
            .execute(&mut *database)
            .await?;
    }
    Ok(())
}

pub(super) async fn compact_queries(
    database: &mut SqliteConnection,
    connection: &str,
    folder: Option<i64>,
) -> Result<(), StorageError> {
    let ids = sqlx::query_scalar(
        "SELECT id FROM saved_queries WHERE connection_id = ? AND folder_id IS ? \
         ORDER BY sort_order, name COLLATE NOCASE, id",
    )
    .bind(connection)
    .bind(folder)
    .fetch_all(&mut *database)
    .await?;
    set_query_order(database, &ids).await
}

pub(super) async fn compact_folders(
    database: &mut SqliteConnection,
    connection: &str,
    parent: Option<i64>,
) -> Result<(), StorageError> {
    let ids: Vec<i64> = sqlx::query_scalar(
        "SELECT id FROM saved_query_folders WHERE connection_id = ? AND parent_id IS ? \
         ORDER BY sort_order, name COLLATE NOCASE, id",
    )
    .bind(connection)
    .bind(parent)
    .fetch_all(&mut *database)
    .await?;
    for (order, id) in ids.into_iter().enumerate() {
        sqlx::query("UPDATE saved_query_folders SET sort_order = ? WHERE id = ?")
            .bind(order as i64)
            .bind(id)
            .execute(&mut *database)
            .await?;
    }
    Ok(())
}
