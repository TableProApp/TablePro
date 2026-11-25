use sqlx::SqliteConnection;

use crate::StorageError;

// Returns the queries whose place moved.
pub(super) async fn set_query_order(database: &mut SqliteConnection, ids: &[i64]) -> Result<Vec<i64>, StorageError> {
    let mut moved = Vec::new();
    for (order, id) in ids.iter().enumerate() {
        let changed = sqlx::query("UPDATE saved_queries SET sort_order = ?1 WHERE id = ?2 AND sort_order IS NOT ?1")
            .bind(order as i64)
            .bind(id)
            .execute(&mut *database)
            .await?
            .rows_affected();
        if changed > 0 {
            moved.push(*id);
        }
    }
    Ok(moved)
}

pub(super) async fn compact_queries(
    database: &mut SqliteConnection,
    connection: &str,
    folder: Option<i64>,
) -> Result<Vec<i64>, StorageError> {
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

// Returns the folders whose place moved.
pub(super) async fn compact_folders(
    database: &mut SqliteConnection,
    connection: &str,
    parent: Option<i64>,
) -> Result<Vec<i64>, StorageError> {
    let ids: Vec<i64> = sqlx::query_scalar(
        "SELECT id FROM saved_query_folders WHERE connection_id = ? AND parent_id IS ? \
         ORDER BY sort_order, name COLLATE NOCASE, id",
    )
    .bind(connection)
    .bind(parent)
    .fetch_all(&mut *database)
    .await?;
    let mut moved = Vec::new();
    for (order, id) in ids.into_iter().enumerate() {
        let changed =
            sqlx::query("UPDATE saved_query_folders SET sort_order = ?1 WHERE id = ?2 AND sort_order IS NOT ?1")
                .bind(order as i64)
                .bind(id)
                .execute(&mut *database)
                .await?
                .rows_affected();
        if changed > 0 {
            moved.push(id);
        }
    }
    Ok(moved)
}
