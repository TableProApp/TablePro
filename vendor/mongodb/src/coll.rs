mod action;
pub mod options;

use std::{fmt, fmt::Debug, str::FromStr, sync::Arc};

use crate::bson::rawdoc;
use serde::{de::Error as DeError, Deserialize, Deserializer, Serialize};

use self::options::*;
use crate::{
    client::options::ServerAddress,
    cmap::conn::PinnedConnectionHandle,
    concern::{ReadConcern, WriteConcern},
    error::{Error, Result},
    selection_criteria::SelectionCriteria,
    Client,
    Database,
};

/// `Collection` is the client-side abstraction of a MongoDB Collection. It can be used to
/// perform collection-level operations such as CRUD operations. A `Collection` can be obtained
/// through a [`Database`](struct.Database.html) by calling either
/// [`Database::collection`](struct.Database.html#method.collection) or
/// [`Database::collection_with_options`](struct.Database.html#method.collection_with_options).
///
/// A [`Collection`] can be parameterized with any type that implements the
/// `Serialize` and `Deserialize` traits from the [`serde`](https://serde.rs/) crate. This includes but
/// is not limited to just `Document`. The various methods that accept or return instances of the
/// documents in the collection will accept/return instances of the generic parameter (e.g.
/// [`Collection::insert_one`] accepts it as an argument, [`Collection::find_one`] returns an
/// `Option` of it). It is recommended to define types that model your data which you can
/// parameterize your [`Collection`]s with instead of `Document`, since doing so eliminates a lot of
/// boilerplate deserialization code and is often more performant.
///
/// `Collection` uses [`std::sync::Arc`](https://doc.rust-lang.org/std/sync/struct.Arc.html) internally,
/// so it can safely be shared across threads or async tasks.
///
/// # Example
/// ```rust
/// # use mongodb::{
/// #     bson::doc,
/// #     error::Result,
/// # };
/// #
/// # async fn start_workers() -> Result<()> {
/// # use mongodb::Client;
/// #
/// # let client = Client::with_uri_str("mongodb://example.com").await?;
/// use serde::{Deserialize, Serialize};
///
/// /// Define a type that models our data.
/// #[derive(Clone, Debug, Deserialize, Serialize)]
/// struct Item {
///     id: u32,
/// }
///
/// // Parameterize our collection with the model.
/// let coll = client.database("items").collection::<Item>("in_stock");
///
/// for i in 0..5 {
///     let coll_ref = coll.clone();
///
///     // Spawn several tasks that operate on the same collection concurrently.
///     tokio::task::spawn(async move {
///         // Perform operations with `coll_ref` that work with directly our model.
///         coll_ref.insert_one(Item { id: i }).await;
///     });
/// }
/// #
/// # Ok(())
/// # }
/// ```
#[derive(Debug)]
pub struct Collection<T>
where
    T: Send + Sync,
{
    inner: Arc<CollectionInner>,
    _phantom: std::marker::PhantomData<fn() -> T>,
}

// Because derive is too conservative, derive only implements Clone if T is Clone.
// Collection<T> does not actually store any value of type T (so T does not need to be clone).
impl<T> Clone for Collection<T>
where
    T: Send + Sync,
{
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
            _phantom: Default::default(),
        }
    }
}

#[derive(Debug, Clone)]
struct CollectionInner {
    client: Client,
    db: Database,
    name: String,
    selection_criteria: Option<SelectionCriteria>,
    read_concern: Option<ReadConcern>,
    write_concern: Option<WriteConcern>,
}

impl<T> Collection<T>
where
    T: Send + Sync,
{
    pub(crate) fn new(db: Database, name: &str, options: Option<CollectionOptions>) -> Self {
        let options = options.unwrap_or_default();
        let selection_criteria = options
            .selection_criteria
            .or_else(|| db.selection_criteria().cloned());

        let read_concern = options.read_concern.or_else(|| db.read_concern().cloned());

        let write_concern = options
            .write_concern
            .or_else(|| db.write_concern().cloned());

        Self {
            inner: Arc::new(CollectionInner {
                client: db.client().clone(),
                db,
                name: name.to_string(),
                selection_criteria,
                read_concern,
                write_concern,
            }),
            _phantom: Default::default(),
        }
    }

    /// Gets a clone of the `Collection` with a different type `U`.
    pub fn clone_with_type<U: Send + Sync>(&self) -> Collection<U> {
        Collection {
            inner: self.inner.clone(),
            _phantom: Default::default(),
        }
    }

    pub(crate) fn clone_unconcerned(&self) -> Self {
        let mut new_inner = CollectionInner::clone(&self.inner);
        new_inner.write_concern = None;
        new_inner.read_concern = None;
        Self {
            inner: Arc::new(new_inner),
            _phantom: Default::default(),
        }
    }

    /// Get the `Client` that this collection descended from.
    pub fn client(&self) -> &Client {
        &self.inner.client
    }

    /// Gets the name of the `Collection`.
    pub fn name(&self) -> &str {
        &self.inner.name
    }

    /// Gets the namespace of the `Collection`.
    ///
    /// The namespace of a MongoDB collection is the concatenation of the name of the database
    /// containing it, the '.' character, and the name of the collection itself. For example, if a
    /// collection named "bar" is created in a database named "foo", the namespace of the collection
    /// is "foo.bar".
    pub fn namespace(&self) -> Namespace {
        Namespace {
            db: self.inner.db.name().into(),
            coll: self.name().into(),
        }
    }

    /// Gets the selection criteria of the `Collection`.
    pub fn selection_criteria(&self) -> Option<&SelectionCriteria> {
        self.inner.selection_criteria.as_ref()
    }

    /// Gets the read concern of the `Collection`.
    pub fn read_concern(&self) -> Option<&ReadConcern> {
        self.inner.read_concern.as_ref()
    }

    /// Gets the write concern of the `Collection`.
    pub fn write_concern(&self) -> Option<&WriteConcern> {
        self.inner.write_concern.as_ref()
    }

    pub(crate) fn db(&self) -> &Database {
        &self.inner.db
    }

    /// Kill the server side cursor that id corresponds to.
    pub(super) async fn kill_cursor(
        &self,
        cursor_id: i64,
        pinned_connection: Option<&PinnedConnectionHandle>,
        drop_address: Option<ServerAddress>,
    ) -> Result<()> {
        let ns = self.namespace();

        let op = crate::operation::run_command::RunCommand::new(
            self.inner.db.clone(),
            rawdoc! {
                "killCursors": ns.coll.as_str(),
                "cursors": [cursor_id]
            },
            drop_address.map(SelectionCriteria::from_address),
            pinned_connection,
        );
        self.client().execute_operation(op, None).await?;
        Ok(())
    }
}

/// A struct modeling the canonical name for a collection in MongoDB.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Namespace {
    /// The name of the database associated with this namespace.
    pub db: String,

    /// The name of the collection this namespace corresponds to.
    pub coll: String,
}

impl Namespace {
    /// Construct a `Namespace` with the given database and collection.
    pub fn new(db: impl Into<String>, coll: impl Into<String>) -> Self {
        Self {
            db: db.into(),
            coll: coll.into(),
        }
    }

    pub(crate) fn from_str(s: &str) -> Option<Self> {
        let mut parts = s.split('.');

        let db = parts.next();
        let coll = parts.collect::<Vec<_>>().join(".");

        match (db, coll) {
            (Some(db), coll) if !coll.is_empty() => Some(Self {
                db: db.to_string(),
                coll,
            }),
            _ => None,
        }
    }
}

impl fmt::Display for Namespace {
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        write!(fmt, "{}.{}", self.db, self.coll)
    }
}

impl<'de> Deserialize<'de> for Namespace {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s: String = Deserialize::deserialize(deserializer)?;
        Self::from_str(&s)
            .ok_or_else(|| D::Error::custom("Missing one or more fields in namespace"))
    }
}

impl Serialize for Namespace {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&(self.db.clone() + "." + &self.coll))
    }
}

impl FromStr for Namespace {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self> {
        let mut parts = s.split('.');

        let db = parts.next();
        let coll = parts.collect::<Vec<_>>().join(".");

        match (db, coll) {
            (Some(db), coll) if !coll.is_empty() => Ok(Self {
                db: db.to_string(),
                coll,
            }),
            _ => Err(Self::Err::invalid_argument(
                "Missing one or more fields in namespace",
            )),
        }
    }
}
