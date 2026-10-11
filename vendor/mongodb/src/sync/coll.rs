use crate::{
    options::{ReadConcern, SelectionCriteria, WriteConcern},
    Collection as AsyncCollection,
    Namespace,
};

/// `Collection` is the client-side abstraction of a MongoDB Collection. It can be used to
/// perform collection-level operations such as CRUD operations. A `Collection` can be obtained
/// through a [`Database`](struct.Database.html) by calling either
/// [`Database::collection`](struct.Database.html#method.collection) or
/// [`Database::collection_with_options`](struct.Database.html#method.collection_with_options).
///
/// `Collection` uses [`std::sync::Arc`](https://doc.rust-lang.org/std/sync/struct.Arc.html) internally,
/// so it can safely be shared across threads. For example:
///
/// ```rust
/// # use mongodb::{
/// #     bson::doc,
/// #     error::Result,
/// #     sync::Client,
/// # };
/// #
/// # fn start_workers() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com")?;
/// let coll = client.database("items").collection("in_stock");
///
/// for i in 0..5 {
///     let coll_ref = coll.clone();
///
///     std::thread::spawn(move || {
///         // Perform operations with `coll_ref`. For example:
///         coll_ref.insert_one(doc! { "x": i });
///     });
/// }
/// #
/// # // Technically we should join the threads here, but for the purpose of the example, we'll just
/// # // sleep for a bit.
/// # std::thread::sleep(std::time::Duration::from_secs(3));
/// # Ok(())
/// # }
/// ```

#[derive(Clone, Debug)]
pub struct Collection<T>
where
    T: Send + Sync,
{
    pub(crate) async_collection: AsyncCollection<T>,
}

impl<T> Collection<T>
where
    T: Send + Sync,
{
    pub(crate) fn new(async_collection: AsyncCollection<T>) -> Self {
        Self { async_collection }
    }

    /// Gets a clone of the `Collection` with a different type `U`.
    pub fn clone_with_type<U: Send + Sync>(&self) -> Collection<U> {
        Collection::new(self.async_collection.clone_with_type())
    }

    /// Gets the name of the `Collection`.
    pub fn name(&self) -> &str {
        self.async_collection.name()
    }

    /// Gets the namespace of the `Collection`.
    ///
    /// The namespace of a MongoDB collection is the concatenation of the name of the database
    /// containing it, the '.' character, and the name of the collection itself. For example, if a
    /// collection named "bar" is created in a database named "foo", the namespace of the collection
    /// is "foo.bar".
    pub fn namespace(&self) -> Namespace {
        self.async_collection.namespace()
    }

    /// Gets the selection criteria of the `Collection`.
    pub fn selection_criteria(&self) -> Option<&SelectionCriteria> {
        self.async_collection.selection_criteria()
    }

    /// Gets the read concern of the `Collection`.
    pub fn read_concern(&self) -> Option<&ReadConcern> {
        self.async_collection.read_concern()
    }

    /// Gets the write concern of the `Collection`.
    pub fn write_concern(&self) -> Option<&WriteConcern> {
        self.async_collection.write_concern()
    }
}
