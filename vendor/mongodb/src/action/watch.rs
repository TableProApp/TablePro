use std::{marker::PhantomData, time::Duration};

use crate::{
    bson::{Bson, Document, Timestamp},
    operation::OperationTarget,
};
use serde::de::DeserializeOwned;

use super::{
    action_impl,
    deeplink,
    export_doc,
    option_setters,
    options_doc,
    ExplicitSession,
    ImplicitSession,
};
use crate::{
    change_stream::{
        event::{ChangeStreamEvent, ResumeToken},
        options::{ChangeStreamOptions, FullDocumentBeforeChangeType, FullDocumentType},
        session::SessionChangeStream,
        ChangeStream,
    },
    collation::Collation,
    error::Result,
    options::ReadConcern,
    selection_criteria::SelectionCriteria,
    Client,
    ClientSession,
    Collection,
    Database,
};

impl Client {
    /// Starts a new [`ChangeStream`] that receives events for all changes in the cluster. The
    /// stream does not observe changes from system collections or the "config", "local" or
    /// "admin" databases.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/changeStreams/) on change
    /// streams.
    ///
    /// Change streams require either a "majority" read concern or no read
    /// concern. Anything else will cause a server error.
    ///
    /// Note that using a `$project` stage to remove any of the `_id` `operationType` or `ns` fields
    /// will cause an error. The driver requires these fields to support resumability. For
    /// more information on resumability, see the documentation for
    /// [`ChangeStream`](change_stream/struct.ChangeStream.html)
    ///
    /// If the pipeline alters the structure of the returned events, the parsed type will need to be
    /// changed via [`ChangeStream::with_type`].
    ///
    /// `await` will return d[`Result<ChangeStream<ChangeStreamEvent<Document>>>`] or
    /// d[`Result<SessionChangeStream<ChangeStreamEvent<Document>>>`] if a
    /// [`ClientSession`] has been provided.
    #[deeplink]
    #[options_doc(watch)]
    pub fn watch(&self) -> Watch<'_> {
        Watch::new_cluster(self)
    }
}

impl Database {
    /// Starts a new [`ChangeStream`](change_stream/struct.ChangeStream.html) that receives events
    /// for all changes in this database. The stream does not observe changes from system
    /// collections and cannot be started on "config", "local" or "admin" databases.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/changeStreams/) on change
    /// streams.
    ///
    /// Change streams require either a "majority" read concern or no read
    /// concern. Anything else will cause a server error.
    ///
    /// Note that using a `$project` stage to remove any of the `_id`, `operationType` or `ns`
    /// fields will cause an error. The driver requires these fields to support resumability. For
    /// more information on resumability, see the documentation for
    /// [`ChangeStream`](change_stream/struct.ChangeStream.html).
    ///
    /// If the pipeline alters the structure of the returned events, the parsed type will need to be
    /// changed via [`ChangeStream::with_type`].
    ///
    /// `await` will return d[`Result<ChangeStream<ChangeStreamEvent<Document>>>`] or
    /// d[`Result<SessionChangeStream<ChangeStreamEvent<Document>>>`] if a
    /// [`ClientSession`] has been provided.
    #[deeplink]
    #[options_doc(watch)]
    pub fn watch(&self) -> Watch<'_> {
        Watch::new(self.client(), self.into())
    }
}

impl<T> Collection<T>
where
    T: Send + Sync,
{
    /// Starts a new [`ChangeStream`](change_stream/struct.ChangeStream.html) that receives events
    /// for all changes in this collection. A
    /// [`ChangeStream`](change_stream/struct.ChangeStream.html) cannot be started on system
    /// collections.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/changeStreams/) on change
    /// streams.
    ///
    /// Change streams require either a "majority" read concern or no read concern. Anything else
    /// will cause a server error.
    ///
    /// `await` will return d[`Result<ChangeStream<ChangeStreamEvent<T>>>`] or
    /// d[`Result<SessionChangeStream<ChangeStreamEvent<T>>>`] if a
    /// [`ClientSession`] has been provided.
    #[deeplink]
    #[options_doc(watch)]
    pub fn watch(&self) -> Watch<'_, T> {
        Watch::new(self.client(), self.into())
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Client {
    /// Starts a new [`ChangeStream`] that receives events for all changes in the cluster. The
    /// stream does not observe changes from system collections or the "config", "local" or
    /// "admin" databases.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/changeStreams/) on change
    /// streams.
    ///
    /// Change streams require either a "majority" read concern or no read
    /// concern. Anything else will cause a server error.
    #[options_doc(watch, "run")]
    pub fn watch(&self) -> Watch<'_> {
        self.async_client.watch()
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Database {
    /// Starts a new [`ChangeStream`](change_stream/struct.ChangeStream.html) that receives events
    /// for all changes in this database. The stream does not observe changes from system
    /// collections and cannot be started on "config", "local" or "admin" databases.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/changeStreams/) on change
    /// streams.
    ///
    /// Change streams require either a "majority" read concern or no read
    /// concern. Anything else will cause a server error.
    #[options_doc(watch, "run")]
    pub fn watch(&self) -> Watch<'_> {
        self.async_database.watch()
    }
}

#[cfg(feature = "sync")]
impl<T> crate::sync::Collection<T>
where
    T: Send + Sync,
{
    /// Starts a new [`ChangeStream`](change_stream/struct.ChangeStream.html) that receives events
    /// for all changes in this collection. A
    /// [`ChangeStream`](change_stream/struct.ChangeStream.html) cannot be started on system
    /// collections.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/changeStreams/) on change
    /// streams.
    ///
    /// Change streams require either a "majority" read concern or no read concern. Anything else
    /// will cause a server error.
    #[options_doc(watch, "run")]
    pub fn watch(&self) -> Watch<'_, T> {
        self.async_collection.watch()
    }
}

/// Starts a new [`ChangeStream`] that receives events for all changes in a given scope.  Create by
/// calling [`Client::watch`], [`Database::watch`], or [`Collection::watch`].
#[must_use]
pub struct Watch<'a, T = Document, S = ImplicitSession> {
    client: &'a Client,
    target: OperationTarget,
    pipeline: Vec<Document>,
    options: Option<ChangeStreamOptions>,
    session: S,
    cluster: bool,
    phantom: PhantomData<fn() -> T>,
}

impl<'a, T> Watch<'a, T, ImplicitSession> {
    fn new(client: &'a Client, target: OperationTarget) -> Self {
        Self {
            client,
            target,
            pipeline: vec![],
            options: None,
            session: ImplicitSession,
            cluster: false,
            phantom: PhantomData,
        }
    }

    fn new_cluster(client: &'a Client) -> Self {
        Self {
            client,
            target: OperationTarget::admin(client),
            pipeline: vec![],
            options: None,
            session: ImplicitSession,
            cluster: true,
            phantom: PhantomData,
        }
    }
}

#[option_setters(crate::change_stream::options::ChangeStreamOptions, skip = [resume_after, all_changes_for_cluster])]
#[export_doc(watch, extra = [session])]
impl<S> Watch<'_, S> {
    /// Apply an aggregation pipeline to the change stream.
    ///
    /// Note that using a `$project` stage to remove any of the `_id`, `operationType` or `ns`
    /// fields will cause an error. The driver requires these fields to support resumability. For
    /// more information on resumability, see the documentation for
    /// [`ChangeStream`](change_stream/struct.ChangeStream.html)
    ///
    /// If the pipeline alters the structure of the returned events, the parsed type will need to be
    /// changed via [`ChangeStream::with_type`].
    pub fn pipeline(mut self, value: impl IntoIterator<Item = Document>) -> Self {
        self.pipeline = value.into_iter().collect();
        self
    }

    /// Specifies the logical starting point for the new change stream. Note that if a watched
    /// collection is dropped and recreated or newly renamed, `start_after` should be set instead.
    /// `resume_after` and `start_after` cannot be set simultaneously.
    ///
    /// For more information on resuming a change stream see the documentation [here](https://www.mongodb.com/docs/manual/changeStreams/#change-stream-resume-after)
    pub fn resume_after(mut self, value: impl Into<Option<ResumeToken>>) -> Self {
        // Implemented manually to accept `impl Into<Option<ResumeToken>>` so the output of
        // `ChangeStream::resume_token()` can be passed in directly.
        self.options().resume_after = value.into();
        self
    }
}

impl<'a, T> Watch<'a, T, ImplicitSession> {
    /// Use the provided ['ClientSession'].
    pub fn session<'s>(
        self,
        session: impl Into<&'s mut ClientSession>,
    ) -> Watch<'a, T, ExplicitSession<'s>> {
        Watch {
            client: self.client,
            target: self.target,
            pipeline: self.pipeline,
            options: self.options,
            session: ExplicitSession(session.into()),
            cluster: self.cluster,
            phantom: PhantomData,
        }
    }
}

#[action_impl(sync = crate::sync::ChangeStream<ChangeStreamEvent<T>>)]
impl<'a, T: DeserializeOwned + Unpin + Send + Sync> Action for Watch<'a, T, ImplicitSession> {
    type Future = WatchFuture;

    async fn execute(mut self) -> Result<ChangeStream<ChangeStreamEvent<T>>> {
        if self.cluster {
            self.options
                .get_or_insert_with(Default::default)
                .all_changes_for_cluster = Some(true);
        }
        self.client
            .execute_watch(self.pipeline, self.options, self.target, None)
            .await
    }
}

#[action_impl(sync = crate::sync::SessionChangeStream<ChangeStreamEvent<T>>)]
impl<'a, T: DeserializeOwned + Unpin + Send + Sync> Action for Watch<'a, T, ExplicitSession<'a>> {
    type Future = WatchSessionFuture;

    async fn execute(mut self) -> Result<SessionChangeStream<ChangeStreamEvent<T>>> {
        if self.cluster {
            self.options
                .get_or_insert_with(Default::default)
                .all_changes_for_cluster = Some(true);
        }
        self.client
            .execute_watch_with_session(
                self.pipeline,
                self.options,
                self.target,
                None,
                self.session.0,
            )
            .await
    }
}
