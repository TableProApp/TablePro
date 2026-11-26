// Writes a host makes whole: every favourite it holds, or the ones one of its edits marked and cleared. The Mac's
// store writes through these while it moves into the core (core ADR 0010, slice 9).

use std::collections::HashSet;
use std::time::SystemTime;

use sha2::{Digest, Sha256};
use sqlx::{AssertSqlSafe, Connection, Row, SqliteConnection};
use uuid::Uuid;

use crate::StorageError;
use crate::journal::{JournalEntry, RecordKind, RecordRef};
use crate::query_history::{Bind, CopyDelete, trim_upgrade_copies};
use crate::unix_time::to_unix;

use super::{DatabaseEnvironment, FavouriteDatabase, FavouriteTable, Favourites, database_record};

// Every connection's favourites, with a digest of each kind a later write can name to say what it was based on. Each
// kind has its own, since the Mac keeps the tables and the databases in two stores.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FavouriteContents {
    pub tables: Vec<FavouriteTable>,
    pub databases: Vec<FavouriteDatabase>,
    pub digests: FavouriteDigests,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FavouriteDigests {
    pub tables: String,
    pub databases: String,
}

// Favourites marked, databases filed under the environment given, and favourites cleared by their key.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FavouriteWrite {
    pub tables: Vec<FavouriteTable>,
    pub databases: Vec<FavouriteDatabase>,
    pub removed_tables: Vec<FavouriteTable>,
    // A database by its connection and name.
    pub removed_databases: Vec<(Uuid, String)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Tables,
    Databases,
}

impl Favourites {
    pub async fn contents(&self) -> Result<FavouriteContents, StorageError> {
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin().await?;
        let contents = read_contents(&mut transaction).await?;
        transaction.commit().await?;
        Ok(contents)
    }

    // Returns the digests after the write.
    pub async fn write(&self, write: &FavouriteWrite) -> Result<FavouriteDigests, StorageError> {
        self.commit(None, write).await
    }

    // The store comes to hold exactly these tables, its databases untouched. Refused with `ImportOutdated`, writing
    // nothing, when `expected` is not the digest of the tables the store holds.
    pub async fn replace_tables(
        &self,
        expected: Option<&str>,
        tables: &[FavouriteTable],
    ) -> Result<FavouriteDigests, StorageError> {
        let write = FavouriteWrite {
            tables: tables.to_vec(),
            ..FavouriteWrite::default()
        };
        self.commit(Some((Kind::Tables, expected)), &write).await
    }

    // As `replace_tables`, for the databases.
    pub async fn replace_databases(
        &self,
        expected: Option<&str>,
        databases: &[FavouriteDatabase],
    ) -> Result<FavouriteDigests, StorageError> {
        let write = FavouriteWrite {
            databases: databases.to_vec(),
            ..FavouriteWrite::default()
        };
        self.commit(Some((Kind::Databases, expected)), &write).await
    }

    async fn commit(
        &self,
        replace: Option<(Kind, Option<&str>)>,
        write: &FavouriteWrite,
    ) -> Result<FavouriteDigests, StorageError> {
        if write.tables.iter().any(|table| table.name.is_empty())
            || write.databases.iter().any(|database| database.database.is_empty())
        {
            return Err(StorageError::EmptyName);
        }
        let mut connection = self.pool.acquire().await?;
        let mut transaction = connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await?;
        let (removed_tables, removed_databases) = match replace {
            Some((kind, expected)) => {
                let held = read_contents(&mut transaction).await?;
                let digest = match kind {
                    Kind::Tables => &held.digests.tables,
                    Kind::Databases => &held.digests.databases,
                };
                if expected.is_some_and(|expected| expected != digest) {
                    return Err(StorageError::ImportOutdated);
                }
                match kind {
                    Kind::Tables => {
                        let kept: HashSet<(Uuid, String, String, String)> = write.tables.iter().map(key).collect();
                        let gone = held.tables.into_iter().filter(|table| !kept.contains(&key(table)));
                        (gone.collect(), Vec::new())
                    }
                    Kind::Databases => {
                        let kept: HashSet<(Uuid, &str)> = write
                            .databases
                            .iter()
                            .map(|database| (database.connection_id, database.database.as_str()))
                            .collect();
                        let gone = held
                            .databases
                            .into_iter()
                            .filter(|database| !kept.contains(&(database.connection_id, database.database.as_str())))
                            .map(|database| (database.connection_id, database.database));
                        (Vec::new(), gone.collect())
                    }
                }
            }
            None => (write.removed_tables.clone(), write.removed_databases.clone()),
        };
        trim_upgrade_copies(&self.path, &copy_deletes(&removed_tables, &removed_databases)).await?;
        let (gone_tables, gone_databases) = remove(&mut transaction, &removed_tables, &removed_databases).await?;
        let (marked_tables, marked_databases) = mark(&mut transaction, write).await?;
        let digests = read_contents(&mut transaction).await?.digests;
        transaction.commit().await?;
        let entries: Vec<JournalEntry> = [
            JournalEntry::new(RecordKind::FavouriteTable)
                .wrote(marked_tables)
                .deleted(gone_tables),
            JournalEntry::new(RecordKind::FavouriteDatabase)
                .wrote(marked_databases)
                .deleted(gone_databases),
        ]
        .into_iter()
        .filter(|entry| !entry.is_empty())
        .collect();
        if !entries.is_empty() {
            self.signals.changed(&entries);
        }
        Ok(digests)
    }
}

type Changed = (Vec<RecordRef>, Vec<RecordRef>);

async fn remove(
    database: &mut SqliteConnection,
    tables: &[FavouriteTable],
    databases: &[(Uuid, String)],
) -> Result<Changed, StorageError> {
    let mut gone_tables = Vec::new();
    for table in tables {
        let removed = sqlx::query(
            "DELETE FROM favourite_tables WHERE connection_id = ? AND database = ? AND schema = ? AND name = ?",
        )
        .bind(table.connection_id.to_string())
        .bind(table.database.as_deref().unwrap_or_default())
        .bind(table.schema.as_deref().unwrap_or_default())
        .bind(&table.name)
        .execute(&mut *database)
        .await?
        .rows_affected();
        if removed > 0 {
            gone_tables.push(table.record());
        }
    }
    let mut gone_databases = Vec::new();
    for (connection_id, name) in databases {
        let removed = sqlx::query("DELETE FROM favourite_databases WHERE connection_id = ? AND database = ?")
            .bind(connection_id.to_string())
            .bind(name)
            .execute(&mut *database)
            .await?
            .rows_affected();
        if removed > 0 {
            gone_databases.push(database_record(*connection_id, name));
        }
    }
    Ok((gone_tables, gone_databases))
}

async fn mark(database: &mut SqliteConnection, write: &FavouriteWrite) -> Result<Changed, StorageError> {
    let now = to_unix(SystemTime::now());
    let mut marked_tables = Vec::new();
    for table in &write.tables {
        let added = sqlx::query(
            "INSERT INTO favourite_tables (connection_id, database, schema, name, created_at) \
             VALUES (?, ?, ?, ?, ?) ON CONFLICT (connection_id, database, schema, name) DO NOTHING",
        )
        .bind(table.connection_id.to_string())
        .bind(table.database.as_deref().unwrap_or_default())
        .bind(table.schema.as_deref().unwrap_or_default())
        .bind(&table.name)
        .bind(now)
        .execute(&mut *database)
        .await?
        .rows_affected();
        if added > 0 {
            marked_tables.push(table.record());
        }
    }
    let mut marked_databases = Vec::new();
    for favourite in &write.databases {
        let changed = sqlx::query(
            "INSERT INTO favourite_databases (connection_id, database, environment, created_at) \
             VALUES (?, ?, ?, ?) \
             ON CONFLICT (connection_id, database) DO UPDATE SET environment = excluded.environment \
             WHERE favourite_databases.environment <> excluded.environment",
        )
        .bind(favourite.connection_id.to_string())
        .bind(&favourite.database)
        .bind(favourite.environment.as_str())
        .bind(now)
        .execute(&mut *database)
        .await?
        .rows_affected();
        if changed > 0 {
            marked_databases.push(database_record(favourite.connection_id, &favourite.database));
        }
    }
    Ok((marked_tables, marked_databases))
}

// As the table's primary key holds it: an absent database or schema is empty.
fn key(table: &FavouriteTable) -> (Uuid, String, String, String) {
    (
        table.connection_id,
        table.database.clone().unwrap_or_default(),
        table.schema.clone().unwrap_or_default(),
        table.name.clone(),
    )
}

fn copy_deletes(tables: &[FavouriteTable], databases: &[(Uuid, String)]) -> Vec<CopyDelete> {
    let tables = tables.iter().map(|table| CopyDelete {
        table: "favourite_tables",
        sql: "DELETE FROM main.favourite_tables WHERE connection_id = ? AND database = ? AND schema = ? AND name = ?"
            .to_owned(),
        binds: vec![
            Bind::Text(table.connection_id.to_string()),
            Bind::Text(table.database.clone().unwrap_or_default()),
            Bind::Text(table.schema.clone().unwrap_or_default()),
            Bind::Text(table.name.clone()),
        ],
    });
    let databases = databases.iter().map(|(connection_id, database)| CopyDelete {
        table: "favourite_databases",
        sql: "DELETE FROM main.favourite_databases WHERE connection_id = ? AND database = ?".to_owned(),
        binds: vec![Bind::Text(connection_id.to_string()), Bind::Text(database.clone())],
    });
    tables.chain(databases).collect()
}

async fn read_contents(database: &mut SqliteConnection) -> Result<FavouriteContents, StorageError> {
    let tables = sqlx::query(
        "SELECT connection_id, database, schema, name FROM favourite_tables \
         ORDER BY connection_id, database, schema, name",
    )
    .fetch_all(&mut *database)
    .await?
    .into_iter()
    .map(|row| {
        let (database, schema): (String, String) = (row.try_get("database")?, row.try_get("schema")?);
        Ok(FavouriteTable {
            connection_id: uuid(&row.try_get::<String, _>("connection_id")?)?,
            database: Some(database).filter(|text| !text.is_empty()),
            schema: Some(schema).filter(|text| !text.is_empty()),
            name: row.try_get("name")?,
        })
    })
    .collect::<Result<Vec<_>, StorageError>>()?;
    let databases = sqlx::query(
        "SELECT connection_id, database, environment FROM favourite_databases ORDER BY connection_id, database",
    )
    .fetch_all(&mut *database)
    .await?
    .into_iter()
    .map(|row| {
        let environment: String = row.try_get("environment")?;
        Ok(FavouriteDatabase {
            connection_id: uuid(&row.try_get::<String, _>("connection_id")?)?,
            database: row.try_get("database")?,
            environment: DatabaseEnvironment::parse(&environment)
                .ok_or_else(|| StorageError::Schema(format!("unknown database environment: {environment}")))?,
        })
    })
    .collect::<Result<Vec<_>, StorageError>>()?;
    let digests = digests(&tables, &databases)?;
    Ok(FavouriteContents {
        tables,
        databases,
        digests,
    })
}

fn uuid(text: &str) -> Result<Uuid, StorageError> {
    Uuid::parse_str(text).map_err(|_| StorageError::Schema("a favourite's connection_id is not a UUID".to_owned()))
}

fn digests(tables: &[FavouriteTable], databases: &[FavouriteDatabase]) -> Result<FavouriteDigests, StorageError> {
    let tables: Vec<_> = tables.iter().map(key).collect();
    let databases: Vec<_> = databases
        .iter()
        .map(|database| {
            (
                database.connection_id,
                &database.database,
                database.environment.as_str(),
            )
        })
        .collect();
    Ok(FavouriteDigests {
        tables: hex::encode(Sha256::digest(serde_json::to_vec(&tables)?)),
        databases: hex::encode(Sha256::digest(serde_json::to_vec(&databases)?)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{QueryHistory, StoragePaths};

    async fn favourites(root: &tempfile::TempDir) -> Favourites {
        QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
            .await
            .expect("open")
            .favourites()
    }

    fn table(connection_id: Uuid, schema: Option<&str>, name: &str) -> FavouriteTable {
        FavouriteTable {
            connection_id,
            database: Some("shop".to_owned()),
            schema: schema.map(str::to_owned),
            name: name.to_owned(),
        }
    }

    #[tokio::test]
    async fn a_write_marks_and_clears_by_key_across_connections() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = favourites(&root).await;
        let (one, two) = (Uuid::new_v4(), Uuid::new_v4());
        let orders = table(one, Some("public"), "orders");
        let users = table(two, None, "users");
        let marked = FavouriteDatabase {
            connection_id: two,
            database: "shop".to_owned(),
            environment: DatabaseEnvironment::Production,
        };
        store
            .write(&FavouriteWrite {
                tables: vec![orders.clone(), users.clone()],
                databases: vec![marked.clone()],
                ..FavouriteWrite::default()
            })
            .await
            .expect("write");

        let digests = store
            .write(&FavouriteWrite {
                removed_tables: vec![orders],
                ..FavouriteWrite::default()
            })
            .await
            .expect("clear");

        let contents = store.contents().await.expect("contents");
        assert_eq!(contents.tables, vec![users]);
        assert_eq!(contents.databases, vec![marked]);
        assert_eq!(contents.digests, digests);
    }

    #[tokio::test]
    async fn a_replace_of_tables_on_an_older_read_writes_nothing_and_a_current_one_keeps_the_databases() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = favourites(&root).await;
        let connection = Uuid::new_v4();
        let first = table(connection, None, "first");
        let second = table(connection, None, "second");
        store
            .write(&FavouriteWrite {
                tables: vec![first.clone()],
                ..FavouriteWrite::default()
            })
            .await
            .expect("write");
        let read = store.contents().await.expect("contents");
        store
            .write(&FavouriteWrite {
                tables: vec![second.clone()],
                ..FavouriteWrite::default()
            })
            .await
            .expect("write");

        let marked = FavouriteDatabase {
            connection_id: connection,
            database: "shop".to_owned(),
            environment: DatabaseEnvironment::Testing,
        };
        store
            .write(&FavouriteWrite {
                databases: vec![marked.clone()],
                ..FavouriteWrite::default()
            })
            .await
            .expect("write a database");

        let refused = store.replace_tables(Some(&read.digests.tables), &[]).await;
        let current = store.contents().await.expect("contents").digests;
        store
            .replace_tables(Some(&current.tables), std::slice::from_ref(&second))
            .await
            .expect("replace");

        assert!(matches!(refused, Err(StorageError::ImportOutdated)));
        let contents = store.contents().await.expect("contents");
        assert_eq!(contents.tables, vec![second]);
        assert_eq!(contents.databases, vec![marked]);
    }
}
