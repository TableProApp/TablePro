#[cfg(feature = "in-use-encryption")]
use crate::bson::Document;

use crate::{
    coll::options::DropCollectionOptions,
    db::options::DropDatabaseOptions,
    error::Result,
    operation::drop_database,
    options::WriteConcern,
    ClientSession,
    Collection,
    Database,
};

use super::{action_impl, deeplink, export_doc, option_setters, options_doc, CollRef};

impl Database {
    /// Drops the database, deleting all data, collections, and indexes stored in it.
    ///
    /// `await` will return d[`Result<()>`].
    #[deeplink]
    #[options_doc(drop_db)]
    pub fn drop(&self) -> DropDatabase<'_> {
        DropDatabase {
            db: self,
            options: None,
            session: None,
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Database {
    /// Drops the database, deleting all data, collections, and indexes stored in it.
    ///
    /// [`run`](DropDatabase::run) will return d[`Result<()>`].
    #[deeplink]
    #[options_doc(drop_db, "run")]
    pub fn drop(&self) -> DropDatabase<'_> {
        self.async_database.drop()
    }
}

/// Drops the database, deleting all data, collections, and indexes stored in it.  Construct with
/// [`Database::drop`].
#[must_use]
pub struct DropDatabase<'a> {
    db: &'a Database,
    options: Option<DropDatabaseOptions>,
    session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::db::options::DropDatabaseOptions)]
#[export_doc(drop_db)]
impl<'a> DropDatabase<'a> {
    /// Runs the drop using the provided session.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a> Action for DropDatabase<'a> {
    type Future = DropDatabaseFuture;

    async fn execute(mut self) -> Result<()> {
        let op = drop_database::DropDatabase::new(self.db.clone(), self.options);
        self.db.client().execute_operation(op, self.session).await
    }
}

impl<T> Collection<T>
where
    T: Send + Sync,
{
    /// Drops the collection, deleting all data and indexes stored in it.
    ///
    /// `await` will return d[`Result<()>`].
    #[deeplink]
    #[options_doc(drop_coll)]
    pub fn drop(&self) -> DropCollection<'_> {
        DropCollection {
            cr: CollRef::new(self),
            options: None,
            session: None,
        }
    }
}

#[cfg(feature = "sync")]
impl<T> crate::sync::Collection<T>
where
    T: Send + Sync,
{
    /// Drops the collection, deleting all data and indexes stored in it.
    ///
    /// [`run`](DropCollection::run) will return d[`Result<()>`].
    #[deeplink]
    #[options_doc(drop_coll, "run")]
    pub fn drop(&self) -> DropCollection<'_> {
        self.async_collection.drop()
    }
}

/// Drops the collection, deleting all data and indexes stored in it.  Construct with
/// [`Collection::drop`].
#[must_use]
pub struct DropCollection<'a> {
    pub(crate) cr: CollRef<'a>,
    pub(crate) options: Option<DropCollectionOptions>,
    pub(crate) session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::coll::options::DropCollectionOptions)]
#[export_doc(drop_coll)]
impl<'a> DropCollection<'a> {
    /// Runs the drop using the provided session.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

// Action impl in src/coll/action/drop.rs
