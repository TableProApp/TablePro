//! Contains the functionality for change streams.
pub(crate) mod common;
pub mod event;
pub(crate) mod options;
pub mod session;

#[cfg(test)]
use std::collections::VecDeque;
use std::{
    pin::Pin,
    task::{Context, Poll},
};

use derive_where::derive_where;
use futures_core::Stream;
use futures_util::FutureExt;
use serde::de::DeserializeOwned;
#[cfg(test)]
use tokio::sync::oneshot;

use crate::{
    change_stream::event::ResumeToken,
    cursor::poll_state::{poll_panic, PollState},
    error::Result,
    Cursor,
};
use common::{ChangeStreamData, WatchArgs};

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
/// [`start_after`](crate::action::Watch::start_after) options used to create the
/// `ChangeStream`. Issuing a raw change stream aggregation is discouraged unless users wish to
/// explicitly opt out of resumability.
///
/// A `ChangeStream` can be iterated like any other [`Stream`]:
///
/// ```
/// # use futures::stream::StreamExt;
/// # use mongodb::{Client, error::Result, bson::doc,
/// # change_stream::event::ChangeStreamEvent};
/// # use tokio::task;
/// #
/// # async fn func() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com").await?;
/// # let coll = client.database("foo").collection("bar");
/// let mut change_stream = coll.watch().await?;
/// let coll_ref = coll.clone();
/// task::spawn(async move {
///     coll_ref.insert_one(doc! { "x": 1 }).await;
/// });
/// while let Some(event) = change_stream.next().await.transpose()? {
///     println!("operation performed: {:?}, document: {:?}", event.operation_type, event.full_document);
///     // operation performed: Insert, document: Some(Document({"x": Int32(1)}))
/// }
/// #
/// # Ok(())
/// # }
/// ```
///
/// If a [`ChangeStream`] is still open when it goes out of scope, it will automatically be closed
/// via an asynchronous [killCursors](https://www.mongodb.com/docs/manual/reference/command/killCursors/) command executed
/// from its [`Drop`](https://doc.rust-lang.org/std/ops/trait.Drop.html) implementation.
///
/// See the documentation [here](https://www.mongodb.com/docs/manual/changeStreams) for more
/// details. Also see the documentation on [usage recommendations](https://www.mongodb.com/docs/manual/administration/change-streams-production-recommendations/).
#[derive_where(Debug)]
pub struct ChangeStream<T>
where
    T: DeserializeOwned,
{
    inner: ChangeStreamState<T>,
}

impl<T> ChangeStream<T>
where
    T: DeserializeOwned,
{
    pub(crate) fn new(cursor: Cursor<()>, args: WatchArgs, data: ChangeStreamData) -> Self {
        Self {
            inner: PollState::new(Box::new(CursorWrapper::new(cursor, args, data))),
        }
    }

    /// Returns the cached resume token that can be used to resume after the most recently returned
    /// change.
    ///
    /// See the documentation
    /// [here](https://www.mongodb.com/docs/manual/changeStreams/#change-stream-resume-token) for more
    /// information on change stream resume tokens.
    pub fn resume_token(&self) -> Option<ResumeToken> {
        poll_panic!(self.inner.state()).data.resume_token.clone()
    }

    /// Update the type streamed values will be parsed as.
    pub fn with_type<D: DeserializeOwned>(self) -> ChangeStream<D> {
        ChangeStream {
            inner: PollState::new(poll_panic!(self.inner.into_state())),
        }
    }

    /// Returns whether the change stream will continue to receive events.
    pub fn is_alive(&self) -> bool {
        !poll_panic!(self.inner.state().and_then(|state| state.cursor.raw())).is_exhausted()
    }

    /// Retrieves the next result from the change stream, if any.
    ///
    /// Where calling `Stream::next` will internally loop until a change document is received,
    /// this will make at most one request and return `None` if the returned document batch is
    /// empty.  This method should be used when storing the resume token in order to ensure the
    /// most up to date token is received, e.g.
    ///
    /// ```
    /// # use mongodb::{Client, Collection, bson::Document, error::Result};
    /// # async fn func() -> Result<()> {
    /// # let client = Client::with_uri_str("mongodb://example.com").await?;
    /// # let coll: Collection<Document> = client.database("foo").collection("bar");
    /// let mut change_stream = coll.watch().await?;
    /// let mut resume_token = None;
    /// while change_stream.is_alive() {
    ///     if let Some(event) = change_stream.next_if_any().await? {
    ///         // process event
    ///     }
    ///     resume_token = change_stream.resume_token();
    /// }
    /// #
    /// # Ok(())
    /// # }
    /// ```
    pub async fn next_if_any(&mut self) -> Result<Option<T>> {
        Ok(self
            .inner
            .state_mut()?
            .next_if_any(&mut ())
            .await?
            .into_option())
    }

    #[cfg(test)]
    pub(crate) fn set_kill_watcher(&mut self, tx: oneshot::Sender<()>) -> Result<()> {
        self.inner
            .state_mut()?
            .cursor
            .raw_mut()?
            .set_kill_watcher(tx);
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn current_batch(&self) -> Result<&VecDeque<crate::bson::RawDocumentBuf>> {
        self.inner.state()?.cursor.batch()
    }

    #[cfg(test)]
    pub(crate) fn client(&self) -> Result<&crate::Client> {
        Ok(self.inner.state()?.cursor.raw()?.client())
    }
}

impl<T> Stream for ChangeStream<T>
where
    T: DeserializeOwned,
{
    type Item = Result<T>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.get_mut().inner.poll_next_step(
            cx,
            |mut state| {
                async move {
                    let out = state.next_event(&mut ()).await;
                    (state, out)
                }
                .boxed()
            },
            |_, out| out.transpose(),
        )
    }
}

type CursorWrapper = common::CursorWrapper<Cursor<()>>;

type ChangeStreamState<T> = PollState<'static, Box<CursorWrapper>, Result<Option<T>>>;

impl common::InnerCursor for Cursor<()> {
    type Session = ();

    async fn try_advance(
        &mut self,
        _session: &mut Self::Session,
    ) -> Result<crate::cursor::stream::AdvanceResult> {
        self.try_advance().await
    }

    fn get_resume_token(&self) -> Result<Option<ResumeToken>> {
        common::get_resume_token(self.batch()?, self.raw()?.post_batch_resume_token())
    }

    fn current(&self) -> &crate::bson::RawDocument {
        self.current()
    }

    async fn execute_watch(
        &mut self,
        args: WatchArgs,
        mut data: ChangeStreamData,
        _session: &mut Self::Session,
    ) -> Result<(Self, WatchArgs)> {
        data.implicit_session = self.raw_mut()?.take_implicit_session();
        let client = self.raw()?.client().clone();
        let new_stream: ChangeStream<event::ChangeStreamEvent<()>> = client
            .execute_watch(args.pipeline, args.options, args.target, Some(data))
            .await?;
        let new_wrapper = new_stream.inner.into_state()?;
        Ok((new_wrapper.cursor, new_wrapper.args))
    }

    fn set_drop_address(&mut self, from: &Self) -> Result<()> {
        self.raw_mut()?
            .set_drop_address(from.raw()?.address().clone());
        Ok(())
    }
}
