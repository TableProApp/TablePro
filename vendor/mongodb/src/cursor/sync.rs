use futures_util::stream::StreamExt;
use serde::de::{Deserialize, DeserializeOwned};

use crate::{
    bson::{Document, RawDocument},
    error::Result,
    sync::ClientSession,
};

use super::{
    session::{SessionCursor as AsyncSessionCursor, SessionCursorStream},
    Cursor as AsyncCursor,
};

/// A `Cursor` streams the result of a query. When a query is made, a `Cursor` will be returned with
/// the first batch of results from the server; the documents will be returned as the `Cursor` is
/// iterated. When the batch is exhausted and if there are more results, the `Cursor` will fetch the
/// next batch of documents, and so forth until the results are exhausted. Note that because of this
/// batching, additional network I/O may occur on any given call to `Cursor::next`. Because of this,
/// a `Cursor` iterates over `Result<Document>` items rather than simply `Document` items.
///
/// The batch size of the `Cursor` can be configured using the options to the method that returns
/// it. For example, setting the `batch_size` field of
/// [`FindOptions`](options/struct.FindOptions.html) will set the batch size of the
/// `Cursor` returned by [`Collection::find`](struct.Collection.html#method.find).
///
/// Note that the batch size determines both the number of documents stored in memory by the
/// `Cursor` at a given time as well as the total number of network round-trips needed to fetch all
/// results from the server; both of these factors should be taken into account when choosing the
/// optimal batch size.
///
/// A cursor can be used like any other [`Iterator`]. The simplest way is just to iterate over the
/// documents it yields using a for loop:
///
/// ```rust
/// # use mongodb::{bson::{doc, Document}, sync::Client, error::Result};
/// #
/// # fn do_stuff() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com")?;
/// # let coll = client.database("foo").collection::<Document>("bar");
/// # let mut cursor = coll.find(doc! {}).run()?;
/// #
/// for doc in cursor {
///   println!("{}", doc?)
/// }
/// #
/// # Ok(())
/// # }
/// ```
///
/// Additionally, all the other methods that an [`Iterator`] has are available on `Cursor` as well.
/// For instance, if the number of results from a query is known to be small, it might make sense
/// to collect them into a vector:
///
/// ```rust
/// # use mongodb::{
/// #     bson::{doc, Document},
/// #     error::Result,
/// #     sync::Client,
/// # };
/// #
/// # fn do_stuff() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com")?;
/// # let coll = client.database("foo").collection("bar");
/// # let cursor = coll.find(doc! { "x": 1 }).run()?;
/// #
/// let results: Vec<Result<Document>> = cursor.collect();
/// # Ok(())
/// # }
/// ```
#[derive(Debug)]
pub struct Cursor<T> {
    async_cursor: AsyncCursor<T>,
}

impl<T> Cursor<T> {
    pub(crate) fn new(async_cursor: AsyncCursor<T>) -> Self {
        Self { async_cursor }
    }
}

impl<T> Cursor<T> {
    /// Move the cursor forward, potentially triggering requests to the database for more results
    /// if the local buffer has been exhausted.
    ///
    /// This will keep requesting data from the server until either the cursor is exhausted
    /// or batch with results in it has been received.
    ///
    /// The return value indicates whether new results were successfully returned (true) or if
    /// the cursor has been closed (false).
    ///
    /// Note: [`Cursor::current`] and [`Cursor::deserialize_current`] must only be called after
    /// [`Cursor::advance`] returned `Ok(true)`. It is an error to call either of them without
    /// calling [`Cursor::advance`] first or after [`Cursor::advance`] returns an error / false.
    ///
    /// ```
    /// # use mongodb::{sync::Client, bson::{Document, doc}, error::Result};
    /// # fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017")?;
    /// # let coll = client.database("stuff").collection::<Document>("stuff");
    /// let mut cursor = coll.find(doc! {}).run()?;
    /// while cursor.advance()? {
    ///     println!("{:?}", cursor.deserialize_current()?);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn advance(&mut self) -> Result<bool> {
        crate::sync::TOKIO_RUNTIME.block_on(self.async_cursor.advance())
    }

    /// Returns a reference to the current result in the cursor.
    ///
    /// # Panics
    /// [`Cursor::advance`] must return `Ok(true)` before [`Cursor::current`] can be
    /// invoked. Calling [`Cursor::current`] after [`Cursor::advance`] does not return true
    /// or without calling [`Cursor::advance`] at all may result in a panic.
    ///
    /// ```
    /// # use mongodb::{sync::Client, bson::{doc, Document}, error::Result};
    /// # fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017")?;
    /// # let coll = client.database("stuff").collection::<Document>("stuff");
    /// let mut cursor = coll.find(doc! {}).run()?;
    /// while cursor.advance()? {
    ///     println!("{:?}", cursor.current());
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn current(&self) -> &RawDocument {
        self.async_cursor.current()
    }

    /// Returns true if the cursor has any additional items to return and false otherwise.
    pub fn has_next(&self) -> bool {
        self.async_cursor.has_next()
    }

    /// Deserialize the current result to the generic type associated with this cursor.
    ///
    /// # Panics
    /// [`Cursor::advance`] must return `Ok(true)` before [`Cursor::deserialize_current`] can be
    /// invoked. Calling [`Cursor::deserialize_current`] after [`Cursor::advance`] does not return
    /// true or without calling [`Cursor::advance`] at all may result in a panic.
    ///
    /// ```
    /// # use mongodb::{sync::Client, error::Result, bson::doc};
    /// # fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017")?;
    /// # let db = client.database("foo");
    /// use serde::Deserialize;
    ///
    /// #[derive(Debug, Deserialize)]
    /// struct Cat<'a> {
    ///     #[serde(borrow)]
    ///     name: &'a str
    /// }
    ///
    /// let coll = db.collection::<Cat>("cat");
    /// let mut cursor = coll.find(doc! {}).run()?;
    /// while cursor.advance()? {
    ///     println!("{:?}", cursor.deserialize_current()?);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn deserialize_current<'a>(&'a self) -> Result<T>
    where
        T: Deserialize<'a>,
    {
        self.async_cursor.deserialize_current()
    }
}

impl<T> Iterator for Cursor<T>
where
    T: DeserializeOwned + Unpin + Send + Sync,
{
    type Item = Result<T>;

    fn next(&mut self) -> Option<Self::Item> {
        crate::sync::TOKIO_RUNTIME.block_on(self.async_cursor.next())
    }
}

/// A `SessionCursor` is a cursor that was created with a `ClientSession` must be iterated using
/// one. To iterate, retrieve a [`SessionCursorIter]` using [`SessionCursor::iter`]:
///
/// ```rust
/// # use mongodb::{bson::{doc, Document}, sync::Client, error::Result};
/// #
/// # fn do_stuff() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com")?;
/// # let mut session = client.start_session().run()?;
/// # let coll = client.database("foo").collection::<Document>("bar");
/// # let mut cursor = coll.find(doc! {}).session(&mut session).run()?;
/// #
/// for doc in cursor.iter(&mut session) {
///   println!("{}", doc?)
/// }
/// #
/// # Ok(())
/// # }
/// ```
#[derive(Debug)]
pub struct SessionCursor<T> {
    async_cursor: AsyncSessionCursor<T>,
}

impl<T> SessionCursor<T> {
    pub(crate) fn new(async_cursor: AsyncSessionCursor<T>) -> Self {
        Self { async_cursor }
    }

    /// Move the cursor forward, potentially triggering requests to the database for more results
    /// if the local buffer has been exhausted.
    ///
    /// This will keep requesting data from the server until either the cursor is exhausted
    /// or batch with results in it has been received.
    ///
    /// The return value indicates whether new results were successfully returned (true) or if
    /// the cursor has been closed (false).
    ///
    /// Note: [`Cursor::current`] and [`Cursor::deserialize_current`] must only be called after
    /// [`Cursor::advance`] returned `Ok(true)`. It is an error to call either of them without
    /// calling [`Cursor::advance`] first or after [`Cursor::advance`] returns an error / false.
    ///
    /// ```
    /// # use mongodb::{sync::Client, bson::{doc, Document}, error::Result};
    /// # fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017")?;
    /// # let mut session = client.start_session().run()?;
    /// # let coll = client.database("stuff").collection::<Document>("stuff");
    /// let mut cursor = coll.find(doc! {}).session(&mut session).run()?;
    /// while cursor.advance(&mut session)? {
    ///     println!("{:?}", cursor.deserialize_current()?);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn advance(&mut self, session: &mut ClientSession) -> Result<bool> {
        crate::sync::TOKIO_RUNTIME
            .block_on(self.async_cursor.advance(&mut session.async_client_session))
    }

    /// Returns a reference to the current result in the cursor.
    ///
    /// # Panics
    /// [`Cursor::advance`] must return `Ok(true)` before [`Cursor::current`] can be
    /// invoked. Calling [`Cursor::current`] after [`Cursor::advance`] does not return true
    /// or without calling [`Cursor::advance`] at all may result in a panic.
    ///
    /// ```
    /// # use mongodb::{sync::Client, bson::{doc, Document}, error::Result};
    /// # fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017")?;
    /// # let mut session = client.start_session().run()?;
    /// # let coll = client.database("stuff").collection::<Document>("stuff");
    /// let mut cursor = coll.find(doc! {}).session(&mut session).run()?;
    /// while cursor.advance(&mut session)? {
    ///     println!("{:?}", cursor.current());
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn current(&self) -> &RawDocument {
        self.async_cursor.current()
    }

    /// Deserialize the current result to the generic type associated with this cursor.
    ///
    /// # Panics
    /// [`Cursor::advance`] must return `Ok(true)` before [`Cursor::deserialize_current`] can be
    /// invoked. Calling [`Cursor::deserialize_current`] after [`Cursor::advance`] does not return
    /// true or without calling [`Cursor::advance`] at all may result in a panic.
    ///
    /// ```
    /// # use mongodb::{sync::Client, error::Result, bson::doc};
    /// # fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017")?;
    /// # let mut session = client.start_session().run()?;
    /// # let db = client.database("foo");
    /// use serde::Deserialize;
    ///
    /// #[derive(Debug, Deserialize)]
    /// struct Cat<'a> {
    ///     #[serde(borrow)]
    ///     name: &'a str
    /// }
    ///
    /// let coll = db.collection::<Cat>("cat");
    /// let mut cursor = coll.find(doc! {}).session(&mut session).run()?;
    /// while cursor.advance(&mut session)? {
    ///     println!("{:?}", cursor.deserialize_current()?);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn deserialize_current<'a>(&'a self) -> Result<T>
    where
        T: Deserialize<'a>,
    {
        self.async_cursor.deserialize_current()
    }
}

impl<T> SessionCursor<T>
where
    T: DeserializeOwned + Unpin + Send + Sync,
{
    /// Retrieves a [`SessionCursorIter`] to iterate this cursor. The session provided must be
    /// the same session used to create the cursor.
    pub fn iter<'session>(
        &mut self,
        session: &'session mut ClientSession,
    ) -> SessionCursorIter<'_, 'session, T> {
        SessionCursorIter {
            async_stream: self.async_cursor.stream(&mut session.async_client_session),
        }
    }

    /// Retrieve the next result from the cursor.
    /// The session provided must be the same session used to create the cursor.
    ///
    /// Use this method when the session needs to be used again between iterations or when the added
    /// functionality of `Iterator` is not needed.
    ///
    /// ```
    /// # use mongodb::{bson::{doc, Document}, sync::Client};
    /// # fn foo() -> mongodb::error::Result<()> {
    /// # let client = Client::with_uri_str("foo")?;
    /// # let coll = client.database("foo").collection::<Document>("bar");
    /// # let other_coll = coll.clone();
    /// # let mut session = client.start_session().run()?;
    /// let mut cursor = coll.find(doc! { "x": 1 }).session(&mut session).run()?;
    /// while let Some(doc) = cursor.next(&mut session).transpose()? {
    ///     other_coll.insert_one(doc).session(&mut session).run()?;
    /// }
    /// # Ok::<(), mongodb::error::Error>(())
    /// # }
    /// ```
    pub fn next(&mut self, session: &mut ClientSession) -> Option<Result<T>> {
        self.iter(session).next()
    }
}

/// A handle that borrows a `ClientSession` temporarily for executing getMores or iterating through
/// the current buffer of a `SessionCursor`.
///
/// This updates the buffer of the parent `SessionCursor` when dropped.
pub struct SessionCursorIter<'cursor, 'session, T = Document>
where
    T: DeserializeOwned + Unpin + Send + Sync,
{
    async_stream: SessionCursorStream<'cursor, 'session, T>,
}

impl<'cursor, 'session, T> Iterator for SessionCursorIter<'cursor, 'session, T>
where
    T: DeserializeOwned + Unpin + Send + Sync,
    'session: 'cursor,
{
    type Item = Result<T>;

    fn next(&mut self) -> Option<Self::Item> {
        crate::sync::TOKIO_RUNTIME.block_on(self.async_stream.next())
    }
}
