//! Raw batch cursor API for zero-copy document processing.
//!
//! This module provides a high-performance alternative to the standard cursor API when you need
//! direct access to server response batches without per-document deserialization overhead.
//!
//! # When to Use
//!
//! **Use `RawBatchCursor` when:**
//! - Processing high-volume queries where deserialization is a bottleneck
//! - Implementing custom batch-level logic (e.g., batch transformation, filtering)
//! - Inspecting raw BSON structure without a known schema
//! - Forwarding documents without modification (e.g., proxying, caching)
//!
//! **Use regular `Cursor` when:**
//! - Working with strongly-typed `Deserialize` documents
//! - Iterating one document at a time
//! - Deserialization overhead is acceptable for your use case
//!
//! # Example
//!
//! ```no_run
//! # use mongodb::{Client, bson::{doc, Document}};
//! # async fn example() -> mongodb::error::Result<()> {
//! # let client = Client::with_uri_str("mongodb://localhost:27017").await?;
//! # let db = client.database("db");
//! # let coll = db.collection::<Document>("coll");
//! use futures::stream::StreamExt;
//!
//! let mut cursor = coll.find(doc! {}).batch().await?;
//! while let Some(batch) = cursor.next().await {
//!     let batch = batch?;
//!     // Zero-copy access to documents in this batch
//!     for doc_result in batch.doc_slices()? {
//!         let doc = doc_result?;
//!         // Process raw document
//!     }
//! }
//! # Ok(())
//! # }
//! ```

use std::{
    pin::Pin,
    task::{ready, Context, Poll},
};

use crate::{
    bson::{RawArray, RawDocument},
    cursor::common::CursorSpecification,
    operation::GetMore,
};
use futures_core::{future::BoxFuture, Future, Stream};
#[cfg(test)]
use tokio::sync::oneshot;

use crate::{
    bson::RawDocumentBuf,
    change_stream::event::ResumeToken,
    client::{options::ServerAddress, AsyncDropToken},
    cmap::conn::PinnedConnectionHandle,
    cursor::common::{kill_cursor, PinnedConnection},
    error::{Error, ErrorKind, Result},
    Client,
    ClientSession,
};

use super::common::CursorInformation;

const CURSOR: &str = "cursor";
const FIRST_BATCH: &str = "firstBatch";
const NEXT_BATCH: &str = "nextBatch";

/// A raw batch response returned by the server for a cursor getMore/find.
///
/// This provides zero-copy access to the server's batch array via
/// [`doc_slices`](RawBatch::doc_slices).
#[derive(Clone, Debug)]
pub struct RawBatch {
    reply: RawDocumentBuf,
}

impl RawBatch {
    pub(crate) fn new(reply: RawDocumentBuf) -> Self {
        Self { reply }
    }

    /// Returns a borrowed view of the batch array (`firstBatch` or `nextBatch`) without copying.
    ///
    /// This lets callers iterate over [`crate::bson::RawDocument`] items directly for maximal
    /// performance.
    pub fn doc_slices(&self) -> Result<&RawArray> {
        let root = self.reply.as_ref();
        let cursor = root
            .get_document(CURSOR)
            .map_err(|_| Error::invalid_response("missing cursor subdocument"))?;

        let docs = cursor
            .get(FIRST_BATCH)?
            .or_else(|| cursor.get(NEXT_BATCH).ok().flatten())
            .ok_or_else(|| {
                Error::invalid_response(format!("missing {FIRST_BATCH}/{NEXT_BATCH}"))
            })?;

        docs.as_array()
            .ok_or_else(|| Error::invalid_response(format!("invalid {FIRST_BATCH}/{NEXT_BATCH}")))
    }

    /// Returns a reference to the full server response document.
    ///
    /// This provides access to all fields in the server's response, including cursor metadata,
    /// for debugging or custom parsing.
    pub fn as_raw_document(&self) -> &RawDocument {
        self.reply.as_ref()
    }
}

/// Streams the results of a query, providing direct access to each batch of results.
pub struct RawBatchCursor {
    client: Client,
    drop_token: AsyncDropToken,
    state: CursorState,
    provider: GetMoreRawProvider<'static, ImplicitClientSessionHandle>,
    drop_address: Option<ServerAddress>,
    #[cfg(test)]
    kill_watcher: Option<oneshot::Sender<()>>,
}

#[allow(dead_code, unreachable_code, clippy::diverging_sub_expression)]
const _: fn() = || {
    fn assert_unpin<T: Unpin>(_t: T) {}

    let _rb: RawBatchCursor = todo!();
    assert_unpin(_rb);
};

/// The state of a server-side cursor, shared by [`RawBatchCursor`] and [`SessionRawBatchCursor`].
#[derive(Debug)]
struct CursorState {
    info: CursorInformation,
    exhausted: bool,
    pinned_connection: PinnedConnection,
    post_batch_resume_token: Option<ResumeToken>,
    buffered_reply: Option<BufferedReply>,
}

impl CursorState {
    fn new(spec: CursorSpecification, pin: Option<PinnedConnectionHandle>) -> Self {
        Self {
            exhausted: spec.info.id == 0,
            info: spec.info,
            pinned_connection: PinnedConnection::new(pin),
            post_batch_resume_token: spec.post_batch_resume_token,
            buffered_reply: Some(BufferedReply::new(spec.initial_reply)),
        }
    }

    fn mark_exhausted(&mut self) {
        self.exhausted = true;
        self.pinned_connection = PinnedConnection::Unpinned;
    }

    fn has_next(&self) -> bool {
        !self.exhausted
            || self
                .buffered_reply
                .as_ref()
                .is_some_and(|buffered| buffered.has_docs)
    }

    fn poll_next_batch<'s, S: ClientSessionHandle<'s>>(
        &mut self,
        provider: &mut GetMoreRawProvider<'s, S>,
        client: &Client,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<RawBatch>>> {
        loop {
            // If a getMore is in flight, poll it and update state.
            if let Some(future) = provider.executing_future() {
                let get_more_out = ready!(Pin::new(future).poll(cx));
                let error = match get_more_out.result {
                    Ok(out) => {
                        self.buffered_reply = Some(BufferedReply::new(out.raw_reply));
                        self.post_batch_resume_token = out.post_batch_resume_token;
                        if out.exhausted {
                            self.mark_exhausted();
                        }
                        if out.id != 0 {
                            self.info.id = out.id;
                        }
                        self.info.ns = out.ns;
                        None
                    }
                    Err(e) => {
                        if matches!(*e.kind, ErrorKind::Command(ref ce) if ce.code == 43 || ce.code == 237)
                        {
                            self.mark_exhausted();
                        }
                        if e.is_network_error() {
                            // Flag the connection as invalid, preventing a killCursors
                            // command, but leave the connection pinned.
                            self.pinned_connection.invalidate();
                        }
                        Some(e)
                    }
                };
                provider.clear_execution(get_more_out.session, self.exhausted);
                if let Some(e) = error {
                    return Poll::Ready(Some(Err(e)));
                }
            }

            // Yield any buffered reply.
            if let Some(buffered) = self.buffered_reply.take() {
                return Poll::Ready(Some(Ok(RawBatch::new(buffered.reply))));
            }

            // If not exhausted and the connection is valid, start a getMore and iterate.
            if !self.exhausted && !matches!(self.pinned_connection, PinnedConnection::Invalid(_)) {
                provider.start_execution(
                    self.info.clone(),
                    client.clone(),
                    self.pinned_connection.handle(),
                );
                continue;
            }

            // Otherwise, we're done.
            return Poll::Ready(None);
        }
    }
}

/// A server reply along with cached "has documents" status.
#[derive(Debug)]
struct BufferedReply {
    reply: RawDocumentBuf,
    has_docs: bool,
}

impl BufferedReply {
    fn new(reply: RawDocumentBuf) -> Self {
        let has_docs = reply
            .get_document(CURSOR)
            .ok()
            .and_then(|cursor| {
                cursor
                    .get_array(FIRST_BATCH)
                    .or_else(|_| cursor.get_array(NEXT_BATCH))
                    .ok()
            })
            .is_some_and(|batch| !batch.is_empty());
        Self { reply, has_docs }
    }
}

impl crate::cursor::NewCursor for RawBatchCursor {
    fn generic_new(
        client: Client,
        spec: CursorSpecification,
        implicit_session: Option<ClientSession>,
        pinned: Option<PinnedConnectionHandle>,
    ) -> Result<Self> {
        Ok(Self::new(client, spec, implicit_session, pinned))
    }
}

impl RawBatchCursor {
    fn new(
        client: Client,
        spec: CursorSpecification,
        session: Option<ClientSession>,
        pin: Option<PinnedConnectionHandle>,
    ) -> Self {
        let exhausted = spec.info.id == 0;
        Self {
            client: client.clone(),
            drop_token: client.register_async_drop(),
            drop_address: None,
            #[cfg(test)]
            kill_watcher: None,
            state: CursorState::new(spec, pin),
            provider: if exhausted {
                GetMoreRawProvider::Done
            } else {
                GetMoreRawProvider::Idle(Box::new(ImplicitClientSessionHandle(session)))
            },
        }
    }

    pub(crate) fn is_exhausted(&self) -> bool {
        self.state.exhausted
    }

    pub(crate) fn has_next(&self) -> bool {
        self.state.has_next()
    }

    pub(crate) fn post_batch_resume_token(&self) -> Option<&ResumeToken> {
        self.state.post_batch_resume_token.as_ref()
    }

    pub(crate) fn address(&self) -> &ServerAddress {
        &self.state.info.address
    }

    pub(crate) fn set_drop_address(&mut self, address: ServerAddress) {
        self.drop_address = Some(address);
    }

    pub(crate) fn client(&self) -> &Client {
        &self.client
    }

    #[cfg(test)]
    pub(crate) fn set_kill_watcher(&mut self, tx: oneshot::Sender<()>) {
        assert!(
            self.kill_watcher.is_none(),
            "cursor already has a kill_watcher"
        );
        self.kill_watcher = Some(tx);
    }

    /// Extracts the stored implicit [`ClientSession`], if any.
    pub(crate) fn take_implicit_session(&mut self) -> Option<ClientSession> {
        self.provider.take_implicit_session()
    }
}

impl Stream for RawBatchCursor {
    type Item = Result<RawBatch>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        this.state
            .poll_next_batch(&mut this.provider, &this.client, cx)
    }
}

impl Drop for RawBatchCursor {
    fn drop(&mut self) {
        if self.is_exhausted() {
            return;
        }
        kill_cursor(
            self.client.clone(),
            &mut self.drop_token,
            &self.state.info.ns,
            self.state.info.id,
            self.state.pinned_connection.replicate(),
            self.drop_address.take(),
            #[cfg(test)]
            self.kill_watcher.take(),
        );
    }
}

/// A raw batch cursor that was created with a [`ClientSession`] and must be iterated using one.
#[derive(Debug)]
pub struct SessionRawBatchCursor {
    client: Client,
    drop_token: AsyncDropToken,
    state: CursorState,
    drop_address: Option<ServerAddress>,
    #[cfg(test)]
    kill_watcher: Option<oneshot::Sender<()>>,
}

impl super::NewCursor for SessionRawBatchCursor {
    fn generic_new(
        client: Client,
        spec: CursorSpecification,
        _implicit_session: Option<ClientSession>,
        pinned: Option<PinnedConnectionHandle>,
    ) -> Result<Self> {
        Ok(Self::new(client, spec, pinned))
    }
}

impl SessionRawBatchCursor {
    fn new(
        client: Client,
        spec: CursorSpecification,
        pinned: Option<PinnedConnectionHandle>,
    ) -> Self {
        Self {
            drop_token: client.register_async_drop(),
            client,
            state: CursorState::new(spec, pinned),
            drop_address: None,
            #[cfg(test)]
            kill_watcher: None,
        }
    }

    /// Retrieves a [`SessionRawBatchCursorStream`] to iterate this cursor. The session provided
    /// must be the same session used to create the cursor.
    pub fn stream<'session>(
        &mut self,
        session: &'session mut ClientSession,
    ) -> SessionRawBatchCursorStream<'_, 'session> {
        SessionRawBatchCursorStream {
            parent: self,
            provider: GetMoreRawProvider::Idle(Box::new(ExplicitClientSessionHandle(session))),
        }
    }

    pub(crate) fn address(&self) -> &ServerAddress {
        &self.state.info.address
    }

    pub(crate) fn set_drop_address(&mut self, address: ServerAddress) {
        self.drop_address = Some(address);
    }

    pub(crate) fn is_exhausted(&self) -> bool {
        self.state.exhausted
    }

    pub(crate) fn post_batch_resume_token(&self) -> Option<&ResumeToken> {
        self.state.post_batch_resume_token.as_ref()
    }

    #[cfg(test)]
    pub(crate) fn set_kill_watcher(&mut self, tx: oneshot::Sender<()>) {
        assert!(
            self.kill_watcher.is_none(),
            "cursor already has a kill_watcher"
        );
        self.kill_watcher = Some(tx);
    }

    pub(crate) fn client(&self) -> &Client {
        &self.client
    }
}

impl Drop for SessionRawBatchCursor {
    fn drop(&mut self) {
        if self.is_exhausted() {
            return;
        }
        kill_cursor(
            self.client.clone(),
            &mut self.drop_token,
            &self.state.info.ns,
            self.state.info.id,
            self.state.pinned_connection.replicate(),
            self.drop_address.take(),
            #[cfg(test)]
            self.kill_watcher.take(),
        );
    }
}

/// A [`Stream`] type for the results of [`SessionRawBatchCursor`].  Returned from
/// [`SessionRawBatchCursor::stream`].
pub struct SessionRawBatchCursorStream<'cursor, 'session> {
    parent: &'cursor mut SessionRawBatchCursor,
    provider: GetMoreRawProvider<'session, ExplicitClientSessionHandle<'session>>,
}

impl Stream for SessionRawBatchCursorStream<'_, '_> {
    type Item = Result<RawBatch>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        this.parent
            .state
            .poll_next_batch(&mut this.provider, &this.parent.client, cx)
    }
}

#[derive(Debug)]
struct GetMoreRawResultAndSession<S> {
    result: Result<crate::results::GetMoreResult>,
    session: S,
}

enum GetMoreRawProvider<'s, S> {
    Executing(BoxFuture<'s, GetMoreRawResultAndSession<S>>),
    Idle(Box<S>),
    Done,
}

impl GetMoreRawProvider<'static, ImplicitClientSessionHandle> {
    /// Extracts the stored implicit [`ClientSession`], if any.
    /// The provider cannot be started again after this call.
    fn take_implicit_session(&mut self) -> Option<ClientSession> {
        match self {
            Self::Idle(session) => session.take_implicit_session(),
            Self::Executing(..) | Self::Done => None,
        }
    }
}

impl<'s, S: ClientSessionHandle<'s>> GetMoreRawProvider<'s, S> {
    fn executing_future(&mut self) -> Option<&mut BoxFuture<'s, GetMoreRawResultAndSession<S>>> {
        if let Self::Executing(future) = self {
            Some(future)
        } else {
            None
        }
    }

    fn clear_execution(&mut self, session: S, exhausted: bool) {
        if exhausted && session.is_implicit() {
            *self = Self::Done
        } else {
            *self = Self::Idle(Box::new(session))
        }
    }

    fn start_execution(
        &mut self,
        info: CursorInformation,
        client: Client,
        pinned_connection: Option<&PinnedConnectionHandle>,
    ) {
        take_mut::take(self, |this| {
            if let Self::Idle(mut session) = this {
                let pinned = pinned_connection.map(|c| c.replicate());
                let fut = Box::pin(async move {
                    let get_more = GetMore::new(info, pinned.as_ref());
                    let res = client
                        .execute_operation(get_more, session.borrow_mut())
                        .await;
                    GetMoreRawResultAndSession {
                        result: res,
                        session: *session,
                    }
                });
                Self::Executing(fut)
            } else {
                this
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bson::{doc, Document};

    #[test]
    fn raw_batch_into_docs_works() {
        let reply_doc: Document = doc! {
            "ok": 1,
            "cursor": {
                "id": 0_i64,
                "ns": "db.coll",
                "firstBatch": [
                    { "x": 1 },
                    { "x": 2 }
                ]
            }
        };
        let mut bytes = Vec::new();
        reply_doc.to_writer(&mut bytes).unwrap();
        let raw = RawDocumentBuf::from_bytes(bytes).unwrap();

        let batch = RawBatch::new(raw);
        let docs: Vec<_> = batch.doc_slices().unwrap().into_iter().collect();
        assert_eq!(docs.len(), 2);
    }
}

#[derive(Debug)]
pub(super) struct ImplicitClientSessionHandle(pub(super) Option<ClientSession>);

impl ImplicitClientSessionHandle {
    fn take_implicit_session(&mut self) -> Option<ClientSession> {
        self.0.take()
    }
}

impl ClientSessionHandle<'_> for ImplicitClientSessionHandle {
    fn is_implicit(&self) -> bool {
        true
    }

    fn borrow_mut(&mut self) -> Option<&mut ClientSession> {
        self.0.as_mut()
    }
}

pub(super) struct ExplicitClientSessionHandle<'a>(pub(super) &'a mut ClientSession);

impl<'a> ClientSessionHandle<'a> for ExplicitClientSessionHandle<'a> {
    fn is_implicit(&self) -> bool {
        false
    }

    fn borrow_mut(&mut self) -> Option<&mut ClientSession> {
        Some(self.0)
    }
}

pub(super) trait ClientSessionHandle<'a>: Send + 'a {
    fn is_implicit(&self) -> bool;

    fn borrow_mut(&mut self) -> Option<&mut ClientSession>;
}
