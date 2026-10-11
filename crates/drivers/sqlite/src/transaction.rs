use super::*;

pub(super) async fn execute_in_transaction_checked(
    pool: &Pool<Sqlite>,
    statements: &[(String, Vec<Value>)],
    expect_one: &[usize],
) -> Result<Vec<u64>, DriverError> {
    let mut tx = pool.begin().await.map_err(map_sqlx_error)?;
    let mut affected = Vec::with_capacity(statements.len());
    for (idx, (sql, params)) in statements.iter().enumerate() {
        let query = match bind_sqlite_params(sqlx::query(sqlx::AssertSqlSafe(sql.as_str())), params) {
            Ok(query) => query,
            Err(error) => {
                let _ = tx.rollback().await;
                return Err(DriverError::Transaction {
                    statement_index: idx,
                    source: Box::new(error),
                });
            }
        };
        match query.execute(&mut *tx).await {
            Ok(result) => {
                let total = result.rows_affected();
                if expect_one.contains(&idx) && total != 1 {
                    let source = DriverError::ConcurrentModification;
                    return Err(match tx.rollback().await {
                        Ok(()) => DriverError::Transaction {
                            statement_index: idx,
                            source: Box::new(source),
                        },
                        Err(error) => DriverError::TransactionRollbackFailed {
                            statement_index: idx,
                            source: Box::new(source),
                            rollback_error: Box::new(map_sqlx_error(error)),
                        },
                    });
                }
                affected.push(total);
            }
            Err(error) => {
                let _ = tx.rollback().await;
                return Err(DriverError::Transaction {
                    statement_index: idx,
                    source: Box::new(map_sqlx_error(error)),
                });
            }
        }
    }
    tx.commit().await.map_err(map_sqlx_error)?;
    Ok(affected)
}
