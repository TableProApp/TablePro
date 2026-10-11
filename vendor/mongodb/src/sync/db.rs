use std::fmt::Debug;

use super::{gridfs::GridFsBucket, Collection};
use crate::{
    options::{
        CollectionOptions,
        GridFsBucketOptions,
        ReadConcern,
        SelectionCriteria,
        WriteConcern,
    },
    Database as AsyncDatabase,
};

/// `Database` is the client-side abstraction of a MongoDB database. It can be used to perform
/// database-level operations or to obtain handles to specific collections within the database. A
/// `Database` can only be obtained through a [`Client`](struct.Client.html) by calling either
/// [`Client::database`](struct.Client.html#method.database) or
/// [`Client::database_with_options`](struct.Client.html#method.database_with_options).
///
/// `Database` uses [`std::sync::Arc`](https://doc.rust-lang.org/std/sync/struct.Arc.html) internally,
/// so it can safely be shared across threads. For example:
///
/// ```rust
/// # use mongodb::{bson::Document, sync::Client, error::Result};
///
/// # fn start_workers() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com")?;
/// let db = client.database("items");
///
/// for i in 0..5 {
///     let db_ref = db.clone();
///
///     std::thread::spawn(move || {
///         let collection = db_ref.collection::<Document>(&format!("coll{}", i));
///
///         // Do something with the collection
///     });
/// }
/// #
/// # // Technically we should join the threads here, but for the purpose of the example, we'll just
/// # // sleep for a bit.
/// # std::thread::sleep(std::time::Duration::from_secs(3));
/// # Ok(())
/// # }
/// ```
#[derive(Debug, Clone)]
pub struct Database {
    pub(crate) async_database: AsyncDatabase,
}

impl Database {
    pub(crate) fn new(async_database: AsyncDatabase) -> Self {
        Self { async_database }
    }

    /// Gets the name of the `Database`.
    pub fn name(&self) -> &str {
        self.async_database.name()
    }

    /// Gets the read preference of the `Database`.
    pub fn selection_criteria(&self) -> Option<&SelectionCriteria> {
        self.async_database.selection_criteria()
    }

    /// Gets the read concern of the `Database`.
    pub fn read_concern(&self) -> Option<&ReadConcern> {
        self.async_database.read_concern()
    }

    /// Gets the write concern of the `Database`.
    pub fn write_concern(&self) -> Option<&WriteConcern> {
        self.async_database.write_concern()
    }

    /// Gets a handle to a collection with type `T` specified by `name` of the database. The
    /// `Collection` options (e.g. read preference and write concern) will default to those of the
    /// `Database`.
    ///
    /// This method does not send or receive anything across the wire to the database, so it can be
    /// used repeatedly without incurring any costs from I/O.
    pub fn collection<T: Send + Sync>(&self, name: &str) -> Collection<T> {
        Collection::new(self.async_database.collection(name))
    }

    /// Gets a handle to a collection with type `T` specified by `name` in the cluster the `Client`
    /// is connected to. Operations done with this `Collection` will use the options specified by
    /// `options` by default and will otherwise default to those of the `Database`.
    ///
    /// This method does not send or receive anything across the wire to the database, so it can be
    /// used repeatedly without incurring any costs from I/O.
    pub fn collection_with_options<T: Send + Sync>(
        &self,
        name: &str,
        options: CollectionOptions,
    ) -> Collection<T> {
        Collection::new(self.async_database.collection_with_options(name, options))
    }

    /// Creates a new [`GridFsBucket`] in the database with the given options.
    pub fn gridfs_bucket(&self, options: impl Into<Option<GridFsBucketOptions>>) -> GridFsBucket {
        GridFsBucket::new(self.async_database.gridfs_bucket(options))
    }
}
