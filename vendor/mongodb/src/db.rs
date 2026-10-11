pub(crate) mod action;
pub mod options;

use std::{fmt::Debug, sync::Arc};

use crate::{
    concern::{ReadConcern, WriteConcern},
    gridfs::{options::GridFsBucketOptions, GridFsBucket},
    options::{CollectionOptions, DatabaseOptions},
    selection_criteria::SelectionCriteria,
    Client,
    Collection,
};

/// `Database` is the client-side abstraction of a MongoDB database. It can be used to perform
/// database-level operations or to obtain handles to specific collections within the database. A
/// `Database` can only be obtained through a [`Client`](struct.Client.html) by calling either
/// [`Client::database`](struct.Client.html#method.database) or
/// [`Client::database_with_options`](struct.Client.html#method.database_with_options).
///
/// `Database` uses [`std::sync::Arc`](https://doc.rust-lang.org/std/sync/struct.Arc.html) internally,
/// so it can safely be shared across threads or async tasks. For example:
///
/// ```rust
/// 
/// # use mongodb::{bson::Document, Client, error::Result};
/// #
/// #
/// # async fn start_workers() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com").await?;
/// let db = client.database("items");
///
/// for i in 0..5 {
///     let db_ref = db.clone();
///
///     tokio::task::spawn(async move {
///         let collection = db_ref.collection::<Document>(&format!("coll{}", i));
///
///         // Do something with the collection
///     });
/// }
/// #
/// # Ok(())
/// # }
/// ```
#[derive(Clone, Debug)]
pub struct Database {
    inner: Arc<DatabaseInner>,
}

#[derive(Debug)]
struct DatabaseInner {
    client: Client,
    name: String,
    selection_criteria: Option<SelectionCriteria>,
    read_concern: Option<ReadConcern>,
    write_concern: Option<WriteConcern>,
}

impl Database {
    pub(crate) fn new(client: Client, name: &str, options: Option<DatabaseOptions>) -> Self {
        let options = options.unwrap_or_default();
        let selection_criteria = options
            .selection_criteria
            .or_else(|| client.selection_criteria().cloned());

        let read_concern = options
            .read_concern
            .or_else(|| client.read_concern().cloned());

        let write_concern = options
            .write_concern
            .or_else(|| client.write_concern().cloned());

        Self {
            inner: Arc::new(DatabaseInner {
                client,
                name: name.to_string(),
                selection_criteria,
                read_concern,
                write_concern,
            }),
        }
    }

    /// Get the `Client` that this collection descended from.
    pub fn client(&self) -> &Client {
        &self.inner.client
    }

    /// Gets the name of the `Database`.
    pub fn name(&self) -> &str {
        &self.inner.name
    }

    /// Gets the read preference of the `Database`.
    pub fn selection_criteria(&self) -> Option<&SelectionCriteria> {
        self.inner.selection_criteria.as_ref()
    }

    /// Gets the read concern of the `Database`.
    pub fn read_concern(&self) -> Option<&ReadConcern> {
        self.inner.read_concern.as_ref()
    }

    /// Gets the write concern of the `Database`.
    pub fn write_concern(&self) -> Option<&WriteConcern> {
        self.inner.write_concern.as_ref()
    }

    /// Gets a handle to a collection in this database with the provided name. The
    /// [`Collection`] options (e.g. read preference and write concern) will default to those of
    /// this [`Database`].
    ///
    /// For more information on how the generic parameter `T` is used, check out the [`Collection`]
    /// documentation.
    ///
    /// This method does not send or receive anything across the wire to the database, so it can be
    /// used repeatedly without incurring any costs from I/O.
    pub fn collection<T: Send + Sync>(&self, name: &str) -> Collection<T> {
        Collection::new(self.clone(), name, None)
    }

    /// Gets a handle to a collection in this database with the provided name.
    /// Operations done with this `Collection` will use the options specified by
    /// `options` and will otherwise default to those of this [`Database`].
    ///
    /// For more information on how the generic parameter `T` is used, check out the [`Collection`]
    /// documentation.
    ///
    /// This method does not send or receive anything across the wire to the database, so it can be
    /// used repeatedly without incurring any costs from I/O.
    pub fn collection_with_options<T: Send + Sync>(
        &self,
        name: &str,
        options: CollectionOptions,
    ) -> Collection<T> {
        Collection::new(self.clone(), name, Some(options))
    }

    /// Creates a new [`GridFsBucket`] in the database with the given options.
    pub fn gridfs_bucket(&self, options: impl Into<Option<GridFsBucketOptions>>) -> GridFsBucket {
        GridFsBucket::new(self.clone(), options.into().unwrap_or_default())
    }
}
