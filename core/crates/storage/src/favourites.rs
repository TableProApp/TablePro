use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;

use sqlx::{AssertSqlSafe, Connection, Row, SqlitePool};
use tokio::sync::watch;
use uuid::Uuid;

use crate::error::StorageError;
use crate::unix_time::to_unix;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatabaseEnvironment {
    Development,
    Testing,
    Production,
    Unassigned,
}

impl DatabaseEnvironment {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Development => "development",
            Self::Testing => "testing",
            Self::Production => "production",
            Self::Unassigned => "unassigned",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        [Self::Development, Self::Testing, Self::Production, Self::Unassigned]
            .into_iter()
            .find(|environment| environment.as_str() == text)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FavouriteTable {
    pub connection_id: Uuid,
    pub database: Option<String>,
    pub schema: Option<String>,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FavouriteDatabase {
    pub connection_id: Uuid,
    pub database: String,
    pub environment: DatabaseEnvironment,
}

#[derive(Debug, Clone)]
pub struct Favourites {
    pool: SqlitePool,
    path: PathBuf,
    changes: Arc<watch::Sender<u64>>,
}

impl Favourites {
    pub(crate) fn new(pool: SqlitePool, path: PathBuf, changes: Arc<watch::Sender<u64>>) -> Self {
        Self { pool, path, changes }
    }

    pub fn changes(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    fn changed(&self) {
        self.changes
            .send_modify(|revision| *revision = revision.wrapping_add(1));
    }

    pub async fn add_table(&self, table: &FavouriteTable) -> Result<(), StorageError> {
        if table.name.is_empty() {
            return Err(StorageError::EmptyName);
        }
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let affected = sqlx::query(
            "INSERT INTO favourite_tables (connection_id, database, schema, name, created_at) \
             VALUES (?, ?, ?, ?, ?) ON CONFLICT (connection_id, database, schema, name) DO NOTHING",
        )
        .bind(table.connection_id.to_string())
        .bind(table.database.as_deref().unwrap_or_default())
        .bind(table.schema.as_deref().unwrap_or_default())
        .bind(&table.name)
        .bind(to_unix(SystemTime::now()))
        .execute(&mut *transaction)
        .await?
        .rows_affected();
        transaction.commit().await?;
        if affected > 0 {
            self.changed();
        }
        Ok(())
    }

    pub async fn remove_table(&self, table: &FavouriteTable) -> Result<(), StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        crate::query_history::trim_upgrade_copies(
            &self.path,
            &[crate::query_history::CopyDelete {
                table: "favourite_tables",
                sql: "DELETE FROM main.favourite_tables \
                      WHERE connection_id = ? AND database = ? AND schema = ? AND name = ?"
                    .to_owned(),
                binds: vec![
                    crate::query_history::Bind::Text(table.connection_id.to_string()),
                    crate::query_history::Bind::Text(table.database.clone().unwrap_or_default()),
                    crate::query_history::Bind::Text(table.schema.clone().unwrap_or_default()),
                    crate::query_history::Bind::Text(table.name.clone()),
                ],
            }],
        )
        .await?;
        let affected = sqlx::query(
            "DELETE FROM favourite_tables WHERE connection_id = ? AND database = ? AND schema = ? AND name = ?",
        )
        .bind(table.connection_id.to_string())
        .bind(table.database.as_deref().unwrap_or_default())
        .bind(table.schema.as_deref().unwrap_or_default())
        .bind(&table.name)
        .execute(&mut *transaction)
        .await?
        .rows_affected();
        transaction.commit().await?;
        if affected > 0 {
            self.changed();
        }
        Ok(())
    }

    pub async fn tables(&self, connection: Uuid) -> Result<Vec<FavouriteTable>, StorageError> {
        let rows = sqlx::query(
            "SELECT database, schema, name FROM favourite_tables WHERE connection_id = ? \
             ORDER BY database COLLATE NOCASE, schema COLLATE NOCASE, name COLLATE NOCASE",
        )
        .bind(connection.to_string())
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| {
                let (database, schema): (String, String) = (row.try_get("database")?, row.try_get("schema")?);
                Ok(FavouriteTable {
                    connection_id: connection,
                    database: Some(database).filter(|text| !text.is_empty()),
                    schema: Some(schema).filter(|text| !text.is_empty()),
                    name: row.try_get("name")?,
                })
            })
            .collect()
    }

    pub async fn set_database(
        &self,
        connection: Uuid,
        database: &str,
        environment: DatabaseEnvironment,
    ) -> Result<(), StorageError> {
        if database.is_empty() {
            return Err(StorageError::EmptyName);
        }
        let mut held = self.pool.acquire().await?;
        let mut transaction = held.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let affected = sqlx::query(
            "INSERT INTO favourite_databases (connection_id, database, environment, created_at) \
             VALUES (?, ?, ?, ?) \
             ON CONFLICT (connection_id, database) DO UPDATE SET environment = excluded.environment \
             WHERE favourite_databases.environment <> excluded.environment",
        )
        .bind(connection.to_string())
        .bind(database)
        .bind(environment.as_str())
        .bind(to_unix(SystemTime::now()))
        .execute(&mut *transaction)
        .await?
        .rows_affected();
        transaction.commit().await?;
        if affected > 0 {
            self.changed();
        }
        Ok(())
    }

    pub async fn remove_database(&self, connection: Uuid, database: &str) -> Result<(), StorageError> {
        let mut held = self.pool.acquire().await?;
        let mut transaction = held.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        crate::query_history::trim_upgrade_copies(
            &self.path,
            &[crate::query_history::CopyDelete {
                table: "favourite_databases",
                sql: "DELETE FROM main.favourite_databases WHERE connection_id = ? AND database = ?".to_owned(),
                binds: vec![
                    crate::query_history::Bind::Text(connection.to_string()),
                    crate::query_history::Bind::Text(database.to_owned()),
                ],
            }],
        )
        .await?;
        let affected = sqlx::query("DELETE FROM favourite_databases WHERE connection_id = ? AND database = ?")
            .bind(connection.to_string())
            .bind(database)
            .execute(&mut *transaction)
            .await?
            .rows_affected();
        transaction.commit().await?;
        if affected > 0 {
            self.changed();
        }
        Ok(())
    }

    pub async fn databases(&self, connection: Uuid) -> Result<Vec<FavouriteDatabase>, StorageError> {
        let rows = sqlx::query(
            "SELECT database, environment FROM favourite_databases WHERE connection_id = ? \
             ORDER BY database COLLATE NOCASE",
        )
        .bind(connection.to_string())
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| {
                let environment: String = row.try_get("environment")?;
                Ok(FavouriteDatabase {
                    connection_id: connection,
                    database: row.try_get("database")?,
                    environment: DatabaseEnvironment::parse(&environment)
                        .ok_or_else(|| StorageError::Schema(format!("unknown database environment: {environment}")))?,
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_environment_round_trips_through_its_word() {
        for environment in [
            DatabaseEnvironment::Development,
            DatabaseEnvironment::Testing,
            DatabaseEnvironment::Production,
            DatabaseEnvironment::Unassigned,
        ] {
            assert_eq!(DatabaseEnvironment::parse(environment.as_str()), Some(environment));
        }
        assert_eq!(DatabaseEnvironment::parse("staging"), None);
    }

    async fn history(root: &tempfile::TempDir) -> crate::QueryHistory {
        crate::QueryHistory::open(&crate::StoragePaths::under(
            root.path(),
            "tablepro",
            "app.tablepro.TablePro",
        ))
        .await
        .expect("open history")
    }

    fn table(connection_id: Uuid, database: Option<&str>, schema: Option<&str>, name: &str) -> FavouriteTable {
        FavouriteTable {
            connection_id,
            database: database.map(str::to_owned),
            schema: schema.map(str::to_owned),
            name: name.to_owned(),
        }
    }

    #[tokio::test]
    async fn catalog_names_keep_case_spaces_and_connection_database_and_schema_identity() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let favourites = history.favourites();
        let connection = Uuid::new_v4();
        let other = Uuid::new_v4();
        let tables = [
            table(connection, Some(" shop "), Some("public"), "Orders"),
            table(connection, Some("shop"), Some("public"), "Orders"),
            table(connection, Some("shop"), Some("Public"), "Orders"),
            table(connection, Some("shop"), Some("public"), "orders"),
            table(connection, Some(" "), Some(" "), " "),
            table(other, Some("shop"), Some("public"), "Orders"),
        ];
        for table in &tables {
            favourites.add_table(table).await.expect("add table");
        }
        let found = favourites.tables(connection).await.expect("tables");
        assert_eq!(found.len(), tables.len() - 1);
        assert!(tables[..5].iter().all(|table| found.contains(table)));
        assert_eq!(
            favourites.tables(other).await.expect("other tables"),
            vec![tables[5].clone()]
        );

        favourites.remove_table(&tables[1]).await.expect("remove exact table");
        let found = favourites.tables(connection).await.expect("tables");
        assert_eq!(found.len(), 4);
        assert!(!found.contains(&tables[1]));
        assert!(found.contains(&tables[0]));
        assert!(found.contains(&tables[2]));
        assert!(found.contains(&tables[3]));
        assert!(found.contains(&tables[4]));

        for name in [" ", "shop", "Shop", " shop "] {
            favourites
                .set_database(connection, name, DatabaseEnvironment::Testing)
                .await
                .expect("mark database");
        }
        favourites
            .set_database(other, "shop", DatabaseEnvironment::Production)
            .await
            .expect("other database");
        favourites
            .remove_database(connection, "shop")
            .await
            .expect("remove database");
        let found = favourites.databases(connection).await.expect("databases");
        assert_eq!(found.len(), 3);
        assert!(
            [" ", "Shop", " shop "]
                .iter()
                .all(|name| found.iter().any(|db| db.database == *name))
        );
        assert_eq!(favourites.databases(other).await.expect("other databases").len(), 1);
    }

    #[tokio::test]
    async fn table_changes_notify_every_surface_only_when_committed_data_changes() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let favourites = history.favourites();
        let mut changed = favourites.changes();
        let mut queries_changed = history.saved_queries().changes();
        let connection = Uuid::new_v4();
        let entry = table(connection, None, None, "orders");

        favourites.add_table(&entry).await.expect("add");
        assert!(changed.has_changed().expect("revision"));
        assert!(queries_changed.has_changed().expect("shared revision"));
        assert_eq!(
            favourites.tables(connection).await.expect("committed rows"),
            vec![entry.clone()]
        );
        changed.borrow_and_update();
        queries_changed.borrow_and_update();

        favourites.add_table(&entry).await.expect("add again");
        favourites
            .add_table(&table(connection, Some(""), Some(""), "orders"))
            .await
            .expect("empty namespace is absent namespace");
        assert!(!changed.has_changed().expect("no revision"));
        assert!(!queries_changed.has_changed().expect("no shared revision"));
        assert_eq!(favourites.tables(connection).await.expect("rows").len(), 1);

        favourites.remove_table(&entry).await.expect("remove");
        assert!(changed.has_changed().expect("revision"));
        assert!(queries_changed.has_changed().expect("shared revision"));
        assert!(
            favourites
                .tables(connection)
                .await
                .expect("committed removal")
                .is_empty()
        );
        changed.borrow_and_update();
        queries_changed.borrow_and_update();
        favourites.remove_table(&entry).await.expect("remove again");
        assert!(!changed.has_changed().expect("no revision"));
        assert!(!queries_changed.has_changed().expect("no shared revision"));
    }

    #[tokio::test]
    async fn database_environment_changes_notify_but_repeated_assignments_do_not() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let favourites = history.favourites();
        let mut changed = favourites.changes();
        let connection = Uuid::new_v4();
        favourites
            .set_database(connection, "shop", DatabaseEnvironment::Testing)
            .await
            .expect("mark database");
        assert!(changed.has_changed().expect("revision"));
        changed.borrow_and_update();
        favourites
            .set_database(connection, "shop", DatabaseEnvironment::Testing)
            .await
            .expect("same environment");
        assert!(!changed.has_changed().expect("no revision"));
        favourites
            .set_database(connection, "shop", DatabaseEnvironment::Production)
            .await
            .expect("change environment");
        assert!(changed.has_changed().expect("revision"));
        assert_eq!(
            favourites.databases(connection).await.expect("committed database"),
            vec![FavouriteDatabase {
                connection_id: connection,
                database: "shop".to_owned(),
                environment: DatabaseEnvironment::Production,
            }]
        );
        changed.borrow_and_update();
        favourites.remove_database(connection, "shop").await.expect("remove");
        assert!(changed.has_changed().expect("revision"));
        changed.borrow_and_update();
        favourites
            .remove_database(connection, "shop")
            .await
            .expect("remove again");
        assert!(!changed.has_changed().expect("no revision"));
    }

    #[tokio::test]
    async fn failed_writes_keep_data_and_publish_no_revision() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let favourites = history.favourites();
        let connection = Uuid::new_v4();
        let entry = table(connection, None, None, "orders");
        favourites.add_table(&entry).await.expect("add");
        favourites
            .set_database(connection, "shop", DatabaseEnvironment::Testing)
            .await
            .expect("mark database");
        sqlx::query("CREATE TRIGGER reject_table_delete BEFORE DELETE ON favourite_tables BEGIN SELECT RAISE(ABORT, 'denied'); END")
            .execute(&favourites.pool)
            .await
            .expect("install failure");
        sqlx::query("CREATE TRIGGER reject_database_change BEFORE UPDATE ON favourite_databases BEGIN SELECT RAISE(ABORT, 'denied'); END")
            .execute(&favourites.pool)
            .await
            .expect("install failure");
        let changed = favourites.changes();
        assert!(favourites.remove_table(&entry).await.is_err());
        assert!(
            favourites
                .set_database(connection, "shop", DatabaseEnvironment::Production)
                .await
                .is_err()
        );
        assert!(matches!(
            favourites.add_table(&table(connection, None, None, "")).await,
            Err(StorageError::EmptyName)
        ));
        assert!(matches!(
            favourites
                .set_database(connection, "", DatabaseEnvironment::Testing)
                .await,
            Err(StorageError::EmptyName)
        ));
        assert!(!changed.has_changed().expect("no revision"));
        assert_eq!(
            favourites.tables(connection).await.expect("unchanged table"),
            vec![entry]
        );
        assert_eq!(
            favourites.databases(connection).await.expect("unchanged database")[0].environment,
            DatabaseEnvironment::Testing
        );
    }

    #[tokio::test]
    async fn corrupt_environment_is_an_error_instead_of_an_unassigned_database() {
        let root = tempfile::tempdir().expect("tempdir");
        let history = history(&root).await;
        let favourites = history.favourites();
        let connection = Uuid::new_v4();
        sqlx::query("PRAGMA ignore_check_constraints = ON")
            .execute(&favourites.pool)
            .await
            .expect("allow corrupt fixture");
        sqlx::query("INSERT INTO favourite_databases (connection_id, database, environment, created_at) VALUES (?, 'shop', 'unknown', 0)")
            .bind(connection.to_string())
            .execute(&favourites.pool)
            .await
            .expect("corrupt fixture");
        sqlx::query("PRAGMA ignore_check_constraints = OFF")
            .execute(&favourites.pool)
            .await
            .expect("restore constraints");
        assert!(matches!(
            favourites.databases(connection).await,
            Err(StorageError::Schema(_))
        ));
    }
}
