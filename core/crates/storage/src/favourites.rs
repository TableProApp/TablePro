//! The tables and databases a user marks as favourites on a connection,
//! as the macOS sidebar keeps them (core ADR 0017).

use std::path::PathBuf;
use std::time::SystemTime;

use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::error::StorageError;
use crate::unix_time::to_unix;

/// What a favourite database is for, the buckets the macOS list groups
/// them in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatabaseEnvironment {
    Development,
    Testing,
    Production,
    Unassigned,
}

impl DatabaseEnvironment {
    /// The word stored, which is also the macOS raw value.
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

/// A table marked as a favourite, named as the catalogue names it: the
/// database and schema where the engine has them.
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

/// The favourite tables and databases. Cloning shares the pool with the
/// history it lives beside.
#[derive(Debug, Clone)]
pub struct Favourites {
    pool: SqlitePool,
    // The database's file, whose upgrade copies a removal reaches too.
    path: PathBuf,
}

impl Favourites {
    pub(crate) fn new(pool: SqlitePool, path: PathBuf) -> Self {
        Self { pool, path }
    }

    /// Mark a table. Marking one already marked changes nothing.
    pub async fn add_table(&self, table: &FavouriteTable) -> Result<(), StorageError> {
        if table.name.trim().is_empty() {
            return Err(StorageError::EmptyName);
        }
        sqlx::query(
            "INSERT OR IGNORE INTO favourite_tables (connection_id, database, schema, name, created_at) \
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(table.connection_id.to_string())
        .bind(table.database.as_deref().unwrap_or_default())
        .bind(table.schema.as_deref().unwrap_or_default())
        .bind(&table.name)
        .bind(to_unix(SystemTime::now()))
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn remove_table(&self, table: &FavouriteTable) -> Result<(), StorageError> {
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
        sqlx::query(
            "DELETE FROM favourite_tables WHERE connection_id = ? AND database = ? AND schema = ? AND name = ?",
        )
        .bind(table.connection_id.to_string())
        .bind(table.database.as_deref().unwrap_or_default())
        .bind(table.schema.as_deref().unwrap_or_default())
        .bind(&table.name)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// The connection's favourite tables, by database, schema and name.
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

    /// Mark a database, or change the environment of one marked.
    pub async fn set_database(
        &self,
        connection: Uuid,
        database: &str,
        environment: DatabaseEnvironment,
    ) -> Result<(), StorageError> {
        if database.trim().is_empty() {
            return Err(StorageError::EmptyName);
        }
        sqlx::query(
            "INSERT INTO favourite_databases (connection_id, database, environment, created_at) \
             VALUES (?, ?, ?, ?) \
             ON CONFLICT (connection_id, database) DO UPDATE SET environment = excluded.environment",
        )
        .bind(connection.to_string())
        .bind(database)
        .bind(environment.as_str())
        .bind(to_unix(SystemTime::now()))
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn remove_database(&self, connection: Uuid, database: &str) -> Result<(), StorageError> {
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
        sqlx::query("DELETE FROM favourite_databases WHERE connection_id = ? AND database = ?")
            .bind(connection.to_string())
            .bind(database)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// The connection's favourite databases, by name.
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
                    environment: DatabaseEnvironment::parse(&environment).unwrap_or(DatabaseEnvironment::Unassigned),
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
}
