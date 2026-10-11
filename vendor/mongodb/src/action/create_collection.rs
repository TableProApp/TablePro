use crate::bson::{Bson, Document};
use std::time::Duration;

use crate::{
    collation::Collation,
    concern::WriteConcern,
    db::options::{
        ChangeStreamPreAndPostImages,
        ClusteredIndex,
        IndexOptionDefaults,
        TimeseriesOptions,
        ValidationAction,
        ValidationLevel,
    },
    options::CreateCollectionOptions,
    ClientSession,
    Database,
};

use super::{deeplink, export_doc, option_setters, options_doc};

impl Database {
    /// Creates a new collection in the database with the given `name`.
    ///
    /// Note that MongoDB creates collections implicitly when data is inserted, so this method is
    /// not needed if no special options are required.
    ///
    /// `await` will return d[`Result<()>`].
    #[deeplink]
    #[options_doc(create_coll)]
    pub fn create_collection(&self, name: impl Into<String>) -> CreateCollection<'_> {
        CreateCollection {
            db: self,
            name: name.into(),
            options: None,
            session: None,
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Database {
    /// Creates a new collection in the database with the given `name`.
    ///
    /// Note that MongoDB creates collections implicitly when data is inserted, so this method is
    /// not needed if no special options are required.
    ///
    /// [`run`](CreateCollection::run) will return d[`Result<()>`].
    #[deeplink]
    #[options_doc(create_coll, "run")]
    pub fn create_collection(&self, name: impl Into<String>) -> CreateCollection<'_> {
        self.async_database.create_collection(name)
    }
}

/// Creates a new collection.  Construct with [`Database::create_collection`].
#[must_use]
pub struct CreateCollection<'a> {
    pub(crate) db: &'a Database,
    pub(crate) name: String,
    pub(crate) options: Option<CreateCollectionOptions>,
    pub(crate) session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::db::options::CreateCollectionOptions)]
#[export_doc(create_coll)]
impl<'a> CreateCollection<'a> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

// Action impl in src/db/action/create_collection.rs
