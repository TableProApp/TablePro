use derive_where::derive_where;
use serde::{de::DeserializeOwned, Deserialize};

use futures_util::StreamExt;

use crate::{
    bson::{Document, RawDocument},
    cursor::{poll_state::poll_panic, raw_batch::SessionRawBatchCursor},
    error::{Error, Result},
    raw_batch_cursor::SessionRawBatchCursorStream,
    ClientSession,
};

use super::{common, stream};

/// A [`SessionCursor`] is a cursor that was created with a [`ClientSession`] that must be iterated
/// using one. To iterate, use [`SessionCursor::next`] or retrieve a [`SessionCursorStream`] using
/// [`SessionCursor::stream`]:
///
/// ```rust
/// # use mongodb::{bson::{Document, doc}, Client, error::Result, ClientSession, SessionCursor};
/// #
/// # async fn do_stuff() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com").await?;
/// # let mut session = client.start_session().await?;
/// # let coll = client.database("foo").collection::<Document>("bar");
/// #
/// // iterate using next()
/// let mut cursor = coll.find(doc! {}).session(&mut session).await?;
/// while let Some(doc) = cursor.next(&mut session).await.transpose()? {
///     println!("{}", doc)
/// }
///
/// // iterate using `Stream`:
/// use futures::stream::TryStreamExt;
///
/// let mut cursor = coll.find(doc! {}).session(&mut session).await?;
/// let results: Vec<_> = cursor.stream(&mut session).try_collect().await?;
/// #
/// # Ok(())
/// # }
/// ```
///
/// If a [`SessionCursor`] is still open when it goes out of scope, it will automatically be closed
/// via an asynchronous [killCursors](https://www.mongodb.com/docs/manual/reference/command/killCursors/) command executed
/// from its [`Drop`](https://doc.rust-lang.org/std/ops/trait.Drop.html) implementation.
#[derive_where(Debug)]
pub struct SessionCursor<T> {
    // `None` while a `SessionCursorStream` is live; because that stream holds a `&mut` to this
    // struct, any access of this will always see `Some`.
    buffer: Option<stream::BatchBuffer<()>>,
    raw: SessionRawBatchCursor,
    _phantom: std::marker::PhantomData<T>,
}

impl<T> crate::cursor::NewCursor for SessionCursor<T> {
    fn generic_new(
        client: crate::Client,
        spec: common::CursorSpecification,
        implicit_session: Option<ClientSession>,
        pinned: Option<crate::cmap::conn::PinnedConnectionHandle>,
    ) -> Result<Self> {
        let raw = SessionRawBatchCursor::generic_new(client, spec, implicit_session, pinned)?;
        Ok(Self {
            buffer: Some(stream::BatchBuffer::new(())),
            raw,
            _phantom: std::marker::PhantomData,
        })
    }
}

impl<T> SessionCursor<T> {
    /// Retrieves a [`SessionCursorStream`] to iterate this cursor. The session provided must be the
    /// same session used to create the cursor.
    ///
    /// Note that the borrow checker will not allow the session to be reused in between iterations
    /// of this stream. In order to do that, either use [`SessionCursor::next`] instead or drop
    /// the stream before using the session.
    ///
    /// ```
    /// # use mongodb::{Client, bson::{doc, Document}, error::Result};
    /// # fn main() {
    /// # async {
    /// # let client = Client::with_uri_str("foo").await?;
    /// # let coll = client.database("foo").collection::<Document>("bar");
    /// # let other_coll = coll.clone();
    /// # let mut session = client.start_session().await?;
    /// #
    /// use futures::stream::TryStreamExt;
    ///
    /// // iterate over the results
    /// let mut cursor = coll.find(doc! { "x": 1 }).session(&mut session).await?;
    /// while let Some(doc) = cursor.stream(&mut session).try_next().await? {
    ///     println!("{}", doc);
    /// }
    ///
    /// // collect the results
    /// let mut cursor1 = coll.find(doc! { "x": 1 }).session(&mut session).await?;
    /// let v: Vec<Document> = cursor1.stream(&mut session).try_collect().await?;
    ///
    /// // use session between iterations
    /// let mut cursor2 = coll.find(doc! { "x": 1 }).session(&mut session).await?;
    /// loop {
    ///     let doc = match cursor2.stream(&mut session).try_next().await? {
    ///         Some(d) => d,
    ///         None => break,
    ///     };
    ///     other_coll.insert_one(doc).session(&mut session).await?;
    /// }
    /// # Ok::<(), mongodb::error::Error>(())
    /// # };
    /// # }
    /// ```
    pub fn stream<'session>(
        &mut self,
        session: &'session mut ClientSession,
    ) -> SessionCursorStream<'_, 'session, T> {
        let raw_stream = self.raw.stream(session);
        let stream = stream::Stream::from_cursor(self.buffer.take().unwrap().map(|_| raw_stream));
        SessionCursorStream {
            parent: &mut self.buffer,
            stream,
        }
    }

    /// Retrieve the next result from the cursor.
    /// The session provided must be the same session used to create the cursor.
    ///
    /// Use this method when the session needs to be used again between iterations or when the added
    /// functionality of `Stream` is not needed.
    ///
    /// ```
    /// # use mongodb::{Client, bson::{doc, Document}};
    /// # fn main() {
    /// # async {
    /// # let client = Client::with_uri_str("foo").await?;
    /// # let coll = client.database("foo").collection::<Document>("bar");
    /// # let other_coll = coll.clone();
    /// # let mut session = client.start_session().await?;
    /// let mut cursor = coll.find(doc! { "x": 1 }).session(&mut session).await?;
    /// while let Some(doc) = cursor.next(&mut session).await.transpose()? {
    ///     other_coll.insert_one(doc).session(&mut session).await?;
    /// }
    /// # Ok::<(), mongodb::error::Error>(())
    /// # };
    /// # }
    /// ```
    pub async fn next(&mut self, session: &mut ClientSession) -> Option<Result<T>>
    where
        T: DeserializeOwned,
    {
        self.stream(session).next().await
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
    /// Note: [`SessionCursor::current`] and [`SessionCursor::deserialize_current`] must only be
    /// called after [`SessionCursor::advance`] returned `Ok(true)`. It is an error to call
    /// either of them without calling [`SessionCursor::advance`] first or after
    /// [`SessionCursor::advance`] returns an error / false.
    ///
    /// ```
    /// # use mongodb::{Client, bson::{doc, Document}, error::Result};
    /// # async fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017").await?;
    /// # let mut session = client.start_session().await?;
    /// # let coll = client.database("stuff").collection::<Document>("stuff");
    /// let mut cursor = coll.find(doc! {}).session(&mut session).await?;
    /// while cursor.advance(&mut session).await? {
    ///     println!("{:?}", cursor.current());
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub async fn advance(&mut self, session: &mut ClientSession) -> Result<bool> {
        self.stream(session).stream.buffer_mut()?.advance().await
    }

    pub(crate) async fn try_advance(
        &mut self,
        session: &mut ClientSession,
    ) -> Result<stream::AdvanceResult> {
        self.stream(session)
            .stream
            .buffer_mut()?
            .try_advance()
            .await
    }

    fn buffer(&self) -> Result<&stream::BatchBuffer<()>> {
        self.buffer
            .as_ref()
            .ok_or_else(|| Error::internal("cursor buffer lost"))
    }

    pub(crate) fn batch(&self) -> Result<&std::collections::VecDeque<crate::bson::RawDocumentBuf>> {
        Ok(self.buffer()?.batch())
    }

    /// Returns a reference to the current result in the cursor.
    ///
    /// # Panics
    /// [`SessionCursor::advance`] must return `Ok(true)` before [`SessionCursor::current`] can be
    /// invoked. Calling [`SessionCursor::current`] after [`SessionCursor::advance`] does not return
    /// true or without calling [`SessionCursor::advance`] at all may result in a panic.
    ///
    /// ```
    /// # use mongodb::{Client, bson::{Document, doc}, error::Result};
    /// # async fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017").await?;
    /// # let mut session = client.start_session().await?;
    /// # let coll = client.database("stuff").collection::<Document>("stuff");
    /// let mut cursor = coll.find(doc! {}).session(&mut session).await?;
    /// while cursor.advance(&mut session).await? {
    ///     println!("{:?}", cursor.current());
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn current(&self) -> &RawDocument {
        poll_panic!(self.buffer()).current()
    }

    /// Deserialize the current result to the generic type associated with this cursor.
    ///
    /// # Panics
    /// [`SessionCursor::advance`] must return `Ok(true)` before
    /// [`SessionCursor::deserialize_current`] can be invoked. Calling
    /// [`SessionCursor::deserialize_current`] after [`SessionCursor::advance`] does not return
    /// true or without calling [`SessionCursor::advance`] at all may result in a panic.
    ///
    /// ```
    /// # use mongodb::{Client, error::Result, bson::doc};
    /// # async fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017").await?;
    /// # let mut session = client.start_session().await?;
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
    /// let mut cursor = coll.find(doc! {}).session(&mut session).await?;
    /// while cursor.advance(&mut session).await? {
    ///     println!("{:?}", cursor.deserialize_current()?);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn deserialize_current<'a>(&'a self) -> Result<T>
    where
        T: Deserialize<'a>,
    {
        self.buffer()?.deserialize_current()
    }

    /// Update the type streamed values will be parsed as.
    pub fn with_type<'a, D>(self) -> SessionCursor<D>
    where
        D: Deserialize<'a>,
    {
        SessionCursor {
            buffer: self.buffer,
            raw: self.raw,
            _phantom: std::marker::PhantomData,
        }
    }

    pub(crate) fn raw(&self) -> &SessionRawBatchCursor {
        &self.raw
    }

    pub(crate) fn raw_mut(&mut self) -> &mut SessionRawBatchCursor {
        &mut self.raw
    }
}

/// A type that implements [`Stream`](https://docs.rs/futures/latest/futures/stream/index.html) which can be used to
/// stream the results of a [`SessionCursor`]. Returned from [`SessionCursor::stream`].
///
/// This updates the buffer of the parent [`SessionCursor`] when dropped. [`SessionCursor::next`] or
/// any further streams created from [`SessionCursor::stream`] will pick up where this one left off.
pub struct SessionCursorStream<'cursor, 'session, T = Document> {
    parent: &'cursor mut Option<stream::BatchBuffer<()>>,
    stream: stream::Stream<'cursor, SessionRawBatchCursorStream<'cursor, 'session>, T>,
}

impl<T> Drop for SessionCursorStream<'_, '_, T> {
    fn drop(&mut self) {
        *self.parent = self.stream.take_buffer().map(|b| b.map(|_| ()));
    }
}

impl<'cursor, 'session, T> futures_core::Stream for SessionCursorStream<'cursor, 'session, T>
where
    T: DeserializeOwned,
    'session: 'cursor,
{
    type Item = Result<T>;

    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        self.stream.poll_next_unpin(cx)
    }
}
