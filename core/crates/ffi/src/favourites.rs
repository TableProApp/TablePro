use std::sync::Arc;

use tablepro_session::runtime::Tasks;
use tablepro_storage::{DatabaseEnvironment, FavouriteDatabase, FavouriteTable, Favourites};
use uuid::Uuid;

use crate::error::CoreError;
use crate::library::parse_id;
use crate::runtime::on_runtime;

// The tables and databases a user marked, per connection, in the query history's database (core ADR 0017).
#[derive(uniffi::Object)]
pub struct FavouriteStore {
    favourites: Favourites,
    tasks: Tasks,
}

// A table by its database and schema, None where the engine has neither.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FavouriteTableInfo {
    pub database: Option<String>,
    pub schema: Option<String>,
    pub name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DatabaseEnvironmentTag {
    Development,
    Testing,
    Production,
    Unassigned,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FavouriteDatabaseInfo {
    pub database: String,
    pub environment: DatabaseEnvironmentTag,
}

impl FavouriteStore {
    pub(crate) fn new(favourites: Favourites, tasks: Tasks) -> Arc<Self> {
        Arc::new(Self { favourites, tasks })
    }
}

#[uniffi::export]
impl FavouriteStore {
    // By database, schema and name.
    pub async fn tables(&self, connection_id: String) -> Result<Vec<FavouriteTableInfo>, CoreError> {
        let connection = parse_id(&connection_id)?;
        let favourites = self.favourites.clone();
        on_runtime(&self.tasks, async move {
            Ok(favourites
                .tables(connection)
                .await?
                .into_iter()
                .map(FavouriteTableInfo::from)
                .collect())
        })
        .await
    }

    // A table marked already stays as it is.
    pub async fn add_table(&self, connection_id: String, table: FavouriteTableInfo) -> Result<(), CoreError> {
        let table = stored(&connection_id, table)?;
        let favourites = self.favourites.clone();
        on_runtime(&self.tasks, async move { Ok(favourites.add_table(&table).await?) }).await
    }

    pub async fn remove_table(&self, connection_id: String, table: FavouriteTableInfo) -> Result<(), CoreError> {
        let table = stored(&connection_id, table)?;
        let favourites = self.favourites.clone();
        on_runtime(&self.tasks, async move { Ok(favourites.remove_table(&table).await?) }).await
    }

    // By name, in any case.
    pub async fn databases(&self, connection_id: String) -> Result<Vec<FavouriteDatabaseInfo>, CoreError> {
        let connection = parse_id(&connection_id)?;
        let favourites = self.favourites.clone();
        on_runtime(&self.tasks, async move {
            Ok(favourites
                .databases(connection)
                .await?
                .into_iter()
                .map(FavouriteDatabaseInfo::from)
                .collect())
        })
        .await
    }

    // Marks the database, or files a marked one under another environment.
    pub async fn set_database(
        &self,
        connection_id: String,
        database: String,
        environment: DatabaseEnvironmentTag,
    ) -> Result<(), CoreError> {
        let connection = parse_id(&connection_id)?;
        let favourites = self.favourites.clone();
        on_runtime(&self.tasks, async move {
            Ok(favourites
                .set_database(connection, &database, environment.into())
                .await?)
        })
        .await
    }

    pub async fn remove_database(&self, connection_id: String, database: String) -> Result<(), CoreError> {
        let connection = parse_id(&connection_id)?;
        let favourites = self.favourites.clone();
        on_runtime(&self.tasks, async move {
            Ok(favourites.remove_database(connection, &database).await?)
        })
        .await
    }
}

fn stored(connection_id: &str, table: FavouriteTableInfo) -> Result<FavouriteTable, CoreError> {
    let connection_id: Uuid = parse_id(connection_id)?;
    Ok(FavouriteTable {
        connection_id,
        database: table.database.filter(|database| !database.is_empty()),
        schema: table.schema.filter(|schema| !schema.is_empty()),
        name: table.name,
    })
}

impl From<FavouriteTable> for FavouriteTableInfo {
    fn from(table: FavouriteTable) -> Self {
        Self {
            database: table.database,
            schema: table.schema,
            name: table.name,
        }
    }
}

impl From<FavouriteDatabase> for FavouriteDatabaseInfo {
    fn from(database: FavouriteDatabase) -> Self {
        Self {
            database: database.database,
            environment: database.environment.into(),
        }
    }
}

impl From<DatabaseEnvironment> for DatabaseEnvironmentTag {
    fn from(environment: DatabaseEnvironment) -> Self {
        match environment {
            DatabaseEnvironment::Development => Self::Development,
            DatabaseEnvironment::Testing => Self::Testing,
            DatabaseEnvironment::Production => Self::Production,
            DatabaseEnvironment::Unassigned => Self::Unassigned,
        }
    }
}

impl From<DatabaseEnvironmentTag> for DatabaseEnvironment {
    fn from(environment: DatabaseEnvironmentTag) -> Self {
        match environment {
            DatabaseEnvironmentTag::Development => Self::Development,
            DatabaseEnvironmentTag::Testing => Self::Testing,
            DatabaseEnvironmentTag::Production => Self::Production,
            DatabaseEnvironmentTag::Unassigned => Self::Unassigned,
        }
    }
}

impl std::fmt::Debug for FavouriteStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FavouriteStore").finish_non_exhaustive()
    }
}
