use futures_util::stream::StreamExt;
use serde::de::DeserializeOwned;

use crate::{
    change_stream::{
        event::ResumeToken,
        session::SessionChangeStream as AsyncSessionChangeStream,
        ChangeStream as AsyncChangeStream,
    },
    error::Result,
};

use super::ClientSession;

/// A `ChangeStream` streams the ongoing changes of its associated collection, database or
/// deployment. `ChangeStream` instances should be created with method `watch` against the relevant
/// target.
///
/// `ChangeStream`s are "resumable", meaning that they can be restarted at a given place in the
/// stream of events. This is done automatically when the `ChangeStream` encounters certain
/// ["resumable"](https://specifications.readthedocs.io/en/latest/change-streams/change-streams/#resumable-error)
/// errors, such as transient network failures. It can also be done manually by passing
/// a [`ResumeToken`] retrieved from a past event into either the
/// [`resume_after`](crate::action::Watch::resume_after) or
/// [`start_after`](crate::action::Watch::start_after) options used to create
/// the `ChangeStream`. Issuing a raw change stream aggregation is discouraged unless users wish to
/// explicitly opt out of resumability.
///
/// A `ChangeStream` can be iterated like any other [`Iterator`]:
///
/// ```
/// # use mongodb::{sync::Client, error::Result, bson::doc,
/// # change_stream::event::ChangeStreamEvent};
/// #
/// # fn func() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com")?;
/// # let coll = client.database("foo").collection("bar");
/// let mut change_stream = coll.watch().run()?;
/// coll.insert_one(doc! { "x": 1 }).run()?;
/// for event in change_stream {
///     let event = event?;
///     println!("operation performed: {:?}, document: {:?}", event.operation_type, event.full_document);
///     // operation performed: Insert, document: Some(Document({"x": Int32(1)}))
/// }
/// #
/// # Ok(())
/// # }
/// ```
///
/// See the documentation [here](https://www.mongodb.com/docs/manual/changeStreams) for more
/// details. Also see the documentation on [usage recommendations](https://www.mongodb.com/docs/manual/administration/change-streams-production-recommendations/).
pub struct ChangeStream<T>
where
    T: DeserializeOwned + Unpin + Send + Sync,
{
    async_stream: AsyncChangeStream<T>,
}

impl<T> ChangeStream<T>
where
    T: DeserializeOwned + Unpin + Send + Sync,
{
    pub(crate) fn new(async_stream: AsyncChangeStream<T>) -> Self {
        Self { async_stream }
    }

    /// Returns the cached resume token that can be used to resume after the most recently returned
    /// change.
    ///
    /// See the documentation
    /// [here](https://www.mongodb.com/docs/manual/changeStreams/#change-stream-resume-token) for more
    /// information on change stream resume tokens.
    pub fn resume_token(&self) -> Option<ResumeToken> {
        self.async_stream.resume_token()
    }

    /// Update the type streamed values will be parsed as.
    pub fn with_type<D: DeserializeOwned + Unpin + Send + Sync>(self) -> ChangeStream<D> {
        ChangeStream {
            async_stream: self.async_stream.with_type(),
        }
    }

    /// Returns whether the change stream will continue to receive events.
    pub fn is_alive(&self) -> bool {
        self.async_stream.is_alive()
    }

    /// Retrieves the next result from the change stream, if any.
    ///
    /// Where calling `Iterator::next` will internally loop until a change document is received,
    /// this will make at most one request and return `None` if the returned document batch is
    /// empty.  This method should be used when storing the resume token in order to ensure the
    /// most up to date token is received, e.g.
    ///
    /// ```
    /// # use mongodb::{bson::Document, sync::{Client, Collection}, error::Result};
    /// # fn func() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://example.com")?;
    /// # let coll: Collection<Document> = client.database("foo").collection("bar");
    /// let mut change_stream = coll.watch().run()?;
    /// let mut resume_token = None;
    /// while change_stream.is_alive() {
    ///     if let Some(event) = change_stream.next_if_any()? {
    ///         // process event
    ///     }
    ///     resume_token = change_stream.resume_token();
    /// }
    /// #
    /// # Ok(())
    /// # }
    /// ```
    pub fn next_if_any(&mut self) -> Result<Option<T>> {
        crate::sync::TOKIO_RUNTIME.block_on(self.async_stream.next_if_any())
    }
}

impl<T> Iterator for ChangeStream<T>
where
    T: DeserializeOwned + Unpin + Send + Sync,
{
    type Item = Result<T>;

    fn next(&mut self) -> Option<Self::Item> {
        crate::sync::TOKIO_RUNTIME.block_on(self.async_stream.next())
    }
}

/// A [`SessionChangeStream`] is a change stream that was created with a [`ClientSession`] that must
/// be iterated using one. To iterate, use [`SessionChangeStream::next`]:
///
/// ```
/// # use mongodb::{bson::Document, sync::Client, error::Result};
/// #
/// # async fn do_stuff() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com")?;
/// # let mut session = client.start_session().run()?;
/// # let coll = client.database("foo").collection::<Document>("bar");
/// #
/// let mut cs = coll.watch().session(&mut session).run()?;
/// while let Some(event) = cs.next(&mut session)? {
///     println!("{:?}", event)
/// }
/// #
/// # Ok(())
/// # }
/// ```
pub struct SessionChangeStream<T>
where
    T: DeserializeOwned + Unpin,
{
    async_stream: AsyncSessionChangeStream<T>,
}

impl<T> SessionChangeStream<T>
where
    T: DeserializeOwned + Unpin + Send + Sync,
{
    pub(crate) fn new(async_stream: AsyncSessionChangeStream<T>) -> Self {
        Self { async_stream }
    }

    /// Returns the cached resume token that can be used to resume after the most recently returned
    /// change.
    ///
    /// See the documentation
    /// [here](https://www.mongodb.com/docs/manual/changeStreams/#change-stream-resume-token) for more
    /// information on change stream resume tokens.
    pub fn resume_token(&self) -> Option<ResumeToken> {
        self.async_stream.resume_token()
    }

    /// Update the type streamed values will be parsed as.
    pub fn with_type<D: DeserializeOwned + Unpin + Send + Sync>(self) -> SessionChangeStream<D> {
        SessionChangeStream {
            async_stream: self.async_stream.with_type(),
        }
    }

    /// Retrieve the next result from the change stream.
    /// The session provided must be the same session used to create the change stream.
    ///
    /// ```
    /// # use mongodb::{bson::{self, doc, Document}, sync::Client};
    /// # fn main() {
    /// # async {
    /// # let client = Client::with_uri_str("foo")?;
    /// # let coll = client.database("foo").collection::<Document>("bar");
    /// # let other_coll = coll.clone();
    /// # let mut session = client.start_session().run()?;
    /// let mut cs = coll.watch().session(&mut session).run()?;
    /// while let Some(event) = cs.next(&mut session)? {
    ///     let id = bson::serialize_to_bson(&event.id)?;
    ///     other_coll.insert_one(doc! { "id": id }).session(&mut session).run()?;
    /// }
    /// # Ok::<(), mongodb::error::Error>(())
    /// # };
    /// # }
    /// ```
    pub fn next(&mut self, session: &mut ClientSession) -> Result<Option<T>> {
        crate::sync::TOKIO_RUNTIME
            .block_on(self.async_stream.next(&mut session.async_client_session))
    }

    /// Returns whether the change stream will continue to receive events.
    pub fn is_alive(&self) -> bool {
        self.async_stream.is_alive()
    }

    /// Retrieve the next result from the change stream, if any.
    ///
    /// Where calling `next` will internally loop until a change document is received,
    /// this will make at most one request and return `None` if the returned document batch is
    /// empty.  This method should be used when storing the resume token in order to ensure the
    /// most up to date token is received, e.g.
    ///
    /// ```
    /// # use mongodb::{bson::Document, sync::{Client, Collection}, error::Result};
    /// # async fn func() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://example.com")?;
    /// # let coll: Collection<Document> = client.database("foo").collection("bar");
    /// # let mut session = client.start_session().run()?;
    /// let mut change_stream = coll.watch().session(&mut session).run()?;
    /// let mut resume_token = None;
    /// while change_stream.is_alive() {
    ///     if let Some(event) = change_stream.next_if_any(&mut session)? {
    ///         // process event
    ///     }
    ///     resume_token = change_stream.resume_token();
    /// }
    /// #
    /// # Ok(())
    /// # }
    /// ```
    pub fn next_if_any(&mut self, session: &mut ClientSession) -> Result<Option<T>> {
        crate::sync::TOKIO_RUNTIME.block_on(
            self.async_stream
                .next_if_any(&mut session.async_client_session),
        )
    }
}
