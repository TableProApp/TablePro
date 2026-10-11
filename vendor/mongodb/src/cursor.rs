pub(crate) mod common;
pub(crate) mod poll_state;
pub mod raw_batch;
pub(crate) mod session;
pub(crate) mod stream;
#[cfg(feature = "sync")]
pub(crate) mod sync;

use std::task::Poll;

use derive_where::derive_where;
use futures_core::Stream as AsyncStream;
use futures_util::stream::StreamExt;
use serde::{de::DeserializeOwned, Deserialize};

use crate::{
    bson::RawDocument,
    cmap::conn::PinnedConnectionHandle,
    cursor::poll_state::poll_panic,
    error::Result,
    Client,
    ClientSession,
};

/// A [`Cursor`] streams the result of a query. When a query is made, the returned [`Cursor`] will
/// contain the first batch of results from the server; the individual results will then be returned
/// as the [`Cursor`] is iterated. When the batch is exhausted and if there are more results, the
/// [`Cursor`] will fetch the next batch of documents, and so forth until the results are exhausted.
/// Note that because of this batching, additional network I/O may occur on any given call to
/// `next`. Because of this, a [`Cursor`] iterates over `Result<T>` items rather than
/// simply `T` items.
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
/// [`Cursor`] implements [`Stream`](https://docs.rs/futures/latest/futures/stream/trait.Stream.html), which means
/// it can be iterated over much in the same way that an `Iterator` can be in synchronous Rust. In
/// order to do so, the [`StreamExt`](https://docs.rs/futures/latest/futures/stream/trait.StreamExt.html) trait must
/// be imported. Because a [`Cursor`] iterates over a `Result<T>`, it also has access to the
/// potentially more ergonomic functionality provided by
/// [`TryStreamExt`](https://docs.rs/futures/latest/futures/stream/trait.TryStreamExt.html), which can be
/// imported instead of or in addition to
/// [`StreamExt`](https://docs.rs/futures/latest/futures/stream/trait.StreamExt.html). The methods from
/// [`TryStreamExt`](https://docs.rs/futures/latest/futures/stream/trait.TryStreamExt.html) are especially useful when
/// used in conjunction with the `?` operator.
///
/// ```rust
/// # use mongodb::{bson::{Document, doc}, Client, error::Result};
/// #
/// # async fn do_stuff() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com").await?;
/// # let coll = client.database("foo").collection::<Document>("bar");
/// #
/// use futures::stream::{StreamExt, TryStreamExt};
///
/// let mut cursor = coll.find(doc! {}).await?;
/// // regular Stream uses next() and iterates over Option<Result<T>>
/// while let Some(doc) = cursor.next().await {
///   println!("{}", doc?)
/// }
/// // regular Stream uses collect() and collects into a Vec<Result<T>>
/// let v: Vec<Result<_>> = cursor.collect().await;
///
/// let mut cursor = coll.find(doc! {}).await?;
/// // TryStream uses try_next() and iterates over Result<Option<T>>
/// while let Some(doc) = cursor.try_next().await? {
///   println!("{}", doc)
/// }
/// // TryStream uses try_collect() and collects into a Result<Vec<T>>
/// let v: Vec<_> = cursor.try_collect().await?;
/// #
/// # Ok(())
/// # }
/// ```
///
/// If a [`Cursor`] is still open when it goes out of scope, it will automatically be closed via an
/// asynchronous [killCursors](https://www.mongodb.com/docs/manual/reference/command/killCursors/) command executed
/// from its [`Drop`](https://doc.rust-lang.org/std/ops/trait.Drop.html) implementation.
#[derive_where(Debug)]
pub struct Cursor<T> {
    stream: stream::Stream<'static, raw_batch::RawBatchCursor, T>,
}

#[allow(dead_code)]
const _: fn() = || {
    /// `Cursor<T>` must stay covariant in `T` for zero-copy deserialization to work: a cursor
    /// yielding a type that borrows for a long lifetime has to be usable where one borrowing for a
    /// shorter lifetime is expected.
    fn assert_covariant<'long: 'short, 'short>(cursor: Cursor<&'long str>) -> Cursor<&'short str> {
        cursor
    }
};

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
    /// # use mongodb::{Client, bson::{Document, doc}, error::Result};
    /// # async fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017").await?;
    /// # let coll = client.database("stuff").collection::<Document>("stuff");
    /// let mut cursor = coll.find(doc! {}).await?;
    /// while cursor.advance().await? {
    ///     println!("{:?}", cursor.current());
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub async fn advance(&mut self) -> Result<bool> {
        self.stream.buffer_mut()?.advance().await
    }

    /// Returns a reference to the current result in the cursor.
    ///
    /// # Panics
    /// [`Cursor::advance`] must return `Ok(true)` before [`Cursor::current`] can be
    /// invoked. Calling [`Cursor::current`] after [`Cursor::advance`] does not return true
    /// or without calling [`Cursor::advance`] at all may result in a panic.
    ///
    /// ```
    /// # use mongodb::{Client, bson::{Document, doc}, error::Result};
    /// # async fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017").await?;
    /// # let coll = client.database("stuff").collection::<Document>("stuff");
    /// let mut cursor = coll.find(doc! {}).await?;
    /// while cursor.advance().await? {
    ///     println!("{:?}", cursor.current());
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn current(&self) -> &RawDocument {
        poll_panic!(self.stream.buffer()).current()
    }

    /// Returns true if the cursor has any additional items to return and false otherwise.
    pub fn has_next(&self) -> bool {
        let state = poll_panic!(self.stream.buffer());
        !state.batch().is_empty() || state.raw.has_next()
    }

    /// Deserialize the current result to the generic type associated with this cursor.
    ///
    /// # Panics
    /// [`Cursor::advance`] must return `Ok(true)` before [`Cursor::deserialize_current`] can be
    /// invoked. Calling [`Cursor::deserialize_current`] after [`Cursor::advance`] does not return
    /// true or without calling [`Cursor::advance`] at all may result in a panic.
    ///
    /// ```
    /// # use mongodb::{Client, error::Result, bson::doc};
    /// # async fn foo() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://localhost:27017").await?;
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
    /// let mut cursor = coll.find(doc! {}).await?;
    /// while cursor.advance().await? {
    ///     println!("{:?}", cursor.deserialize_current()?);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn deserialize_current<'a>(&'a self) -> Result<T>
    where
        T: Deserialize<'a>,
    {
        self.stream.buffer()?.deserialize_current()
    }

    /// Update the type streamed values will be parsed as.
    pub fn with_type<'a, D>(self) -> Cursor<D>
    where
        D: Deserialize<'a>,
    {
        Cursor {
            stream: self.stream.with_type(),
        }
    }

    pub(crate) fn raw(&self) -> Result<&raw_batch::RawBatchCursor> {
        Ok(&self.stream.buffer()?.raw)
    }

    pub(crate) fn raw_mut(&mut self) -> Result<&mut raw_batch::RawBatchCursor> {
        Ok(&mut self.stream.buffer_mut()?.raw)
    }

    pub(crate) async fn try_advance(&mut self) -> Result<stream::AdvanceResult> {
        self.stream.buffer_mut()?.try_advance().await
    }

    pub(crate) fn batch(&self) -> Result<&std::collections::VecDeque<crate::bson::RawDocumentBuf>> {
        Ok(self.stream.buffer()?.batch())
    }
}

pub(crate) trait NewCursor: Sized {
    fn generic_new(
        client: Client,
        spec: common::CursorSpecification,
        implicit_session: Option<ClientSession>,
        pinned: Option<PinnedConnectionHandle>,
    ) -> Result<Self>;
}

impl<T> NewCursor for Cursor<T> {
    fn generic_new(
        client: Client,
        spec: common::CursorSpecification,
        implicit_session: Option<ClientSession>,
        pinned: Option<PinnedConnectionHandle>,
    ) -> Result<Self> {
        let raw = crate::cursor::raw_batch::RawBatchCursor::generic_new(
            client,
            spec,
            implicit_session,
            pinned,
        )?;
        Ok(Self {
            stream: stream::Stream::new(raw),
        })
    }
}

impl<T> AsyncStream for Cursor<T>
where
    T: DeserializeOwned,
{
    type Item = Result<T>;

    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> Poll<Option<Self::Item>> {
        self.stream.poll_next_unpin(cx)
    }
}
