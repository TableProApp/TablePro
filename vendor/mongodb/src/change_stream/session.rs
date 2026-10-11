//! Types for change streams using sessions.
use serde::de::DeserializeOwned;

use crate::{error::Result, ClientSession, SessionCursor};

use super::{
    event::{ChangeStreamEvent, ResumeToken},
    ChangeStreamData,
    WatchArgs,
};

/// A [`SessionChangeStream`] is a change stream that was created with a ClientSession that must
/// be iterated using one. To iterate, use [`SessionChangeStream::next`]:
///
/// ```
/// # use mongodb::{bson::Document, Client, error::Result};
/// #
/// # async fn do_stuff() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com").await?;
/// # let mut session = client.start_session().await?;
/// # let coll = client.database("foo").collection::<Document>("bar");
/// #
/// let mut cs = coll.watch().session(&mut session).await?;
/// while let Some(event) = cs.next(&mut session).await? {
///     println!("{:?}", event)
/// }
/// #
/// # Ok(())
/// # }
/// ```
///
/// If a [`SessionChangeStream`] is still open when it goes out of scope, it will automatically be
/// closed via an asynchronous [killCursors](https://www.mongodb.com/docs/manual/reference/command/killCursors/) command executed
/// from its [`Drop`](https://doc.rust-lang.org/std/ops/trait.Drop.html) implementation.
pub struct SessionChangeStream<T>
where
    T: DeserializeOwned + Unpin,
{
    inner: CursorWrapper,
    _marker: std::marker::PhantomData<fn() -> T>,
}

type CursorWrapper = super::common::CursorWrapper<SessionCursor<()>>;

impl<T> SessionChangeStream<T>
where
    T: DeserializeOwned + Unpin + Send + Sync,
{
    pub(crate) fn new(cursor: SessionCursor<()>, args: WatchArgs, data: ChangeStreamData) -> Self {
        Self {
            inner: CursorWrapper::new(cursor, args, data),
            _marker: std::marker::PhantomData,
        }
    }

    /// Returns the cached resume token that can be used to resume after the most recently returned
    /// change.
    ///
    /// See the documentation
    /// [here](https://www.mongodb.com/docs/manual/changeStreams/#change-stream-resume-token) for more
    /// information on change stream resume tokens.
    pub fn resume_token(&self) -> Option<ResumeToken> {
        self.inner.data.resume_token.clone()
    }

    /// Update the type streamed values will be parsed as.
    pub fn with_type<D: DeserializeOwned + Unpin + Send + Sync>(self) -> SessionChangeStream<D> {
        SessionChangeStream {
            inner: self.inner,
            _marker: std::marker::PhantomData,
        }
    }

    /// Retrieve the next result from the change stream.
    /// The session provided must be the same session used to create the change stream.
    ///
    /// ```
    /// # use mongodb::{Client, bson::{self, doc, Document}};
    /// # fn main() {
    /// # async {
    /// # let client = Client::with_uri_str("foo").await?;
    /// # let coll = client.database("foo").collection::<Document>("bar");
    /// # let other_coll = coll.clone();
    /// # let mut session = client.start_session().await?;
    /// let mut cs = coll.watch().session(&mut session).await?;
    /// while let Some(event) = cs.next(&mut session).await? {
    ///     let id = bson::serialize_to_bson(&event.id)?;
    ///     other_coll.insert_one(doc! { "id": id }).session(&mut session).await?;
    /// }
    /// # Ok::<(), mongodb::error::Error>(())
    /// # };
    /// # }
    /// ```
    pub async fn next(&mut self, session: &mut ClientSession) -> Result<Option<T>> {
        self.inner.next_event(session).await
    }

    /// Returns whether the change stream will continue to receive events.
    pub fn is_alive(&self) -> bool {
        !self.inner.cursor.raw().is_exhausted()
    }

    /// Retrieve the next result from the change stream, if any.
    ///
    /// Where calling `next` will internally loop until a change document is received,
    /// this will make at most one request and return `None` if the returned document batch is
    /// empty.  This method should be used when storing the resume token in order to ensure the
    /// most up to date token is received, e.g.
    ///
    /// ```
    /// # use mongodb::{Client, Collection, bson::Document, error::Result};
    /// # async fn func() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://example.com").await?;
    /// # let coll: Collection<Document> = client.database("foo").collection("bar");
    /// # let mut session = client.start_session().await?;
    /// let mut change_stream = coll.watch().session(&mut session).await?;
    /// let mut resume_token = None;
    /// while change_stream.is_alive() {
    ///     if let Some(event) = change_stream.next_if_any(&mut session).await? {
    ///         // process event
    ///     }
    ///     resume_token = change_stream.resume_token();
    /// }
    /// #
    /// # Ok(())
    /// # }
    /// ```
    pub async fn next_if_any(&mut self, session: &mut ClientSession) -> Result<Option<T>> {
        Ok(self.inner.next_if_any(session).await?.into_option())
    }
}

impl super::common::InnerCursor for SessionCursor<()> {
    type Session = ClientSession;

    async fn try_advance(
        &mut self,
        session: &mut Self::Session,
    ) -> Result<crate::cursor::stream::AdvanceResult> {
        self.try_advance(session).await
    }

    fn get_resume_token(&self) -> Result<Option<ResumeToken>> {
        super::common::get_resume_token(self.batch()?, self.raw().post_batch_resume_token())
    }

    fn current(&self) -> &crate::bson::RawDocument {
        self.current()
    }

    async fn execute_watch(
        &mut self,
        args: WatchArgs,
        data: ChangeStreamData,
        session: &mut Self::Session,
    ) -> Result<(Self, WatchArgs)> {
        let new_stream: SessionChangeStream<ChangeStreamEvent<()>> = self
            .raw()
            .client()
            .execute_watch_with_session(
                args.pipeline,
                args.options,
                args.target,
                Some(data),
                session,
            )
            .await?;
        let new_inner = new_stream.inner;
        Ok((new_inner.cursor, new_inner.args))
    }

    fn set_drop_address(&mut self, from: &Self) -> Result<()> {
        self.raw_mut()
            .set_drop_address(from.raw().address().clone());
        Ok(())
    }
}
