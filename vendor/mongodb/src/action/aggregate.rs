use std::{marker::PhantomData, time::Duration};

use crate::bson::{Bson, Document};

use crate::{
    coll::options::{AggregateOptions, Hint},
    collation::Collation,
    error::Result,
    operation::OperationTarget,
    options::{ReadConcern, WriteConcern},
    selection_criteria::SelectionCriteria,
    Client,
    ClientSession,
    Collection,
    Cursor,
    Database,
    SessionCursor,
};

use super::{
    action_impl,
    deeplink,
    export_doc,
    option_setters,
    options_doc,
    CollRef,
    ExplicitSession,
    ImplicitSession,
};

impl Database {
    /// Runs an aggregation operation.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/aggregation/) for more
    /// information on aggregations.
    ///
    /// `await` will return d[`Result<Cursor<Document>>`]. If a [`ClientSession`] was provided, the
    /// returned cursor will be a [`SessionCursor`]. If [`with_type`](Aggregate::with_type) was
    /// called, the returned cursor will be generic over the `T` specified.
    #[deeplink]
    #[options_doc(aggregate)]
    pub fn aggregate(&self, pipeline: impl IntoIterator<Item = Document>) -> Aggregate<'_> {
        Aggregate::new(
            AggregateTargetRef::Database(self),
            pipeline.into_iter().collect(),
        )
    }
}

impl<T> Collection<T>
where
    T: Send + Sync,
{
    /// Runs an aggregation operation.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/aggregation/) for more
    /// information on aggregations.
    ///
    /// `await` will return d[`Result<Cursor<Document>>`]. If a [`ClientSession`] was provided, the
    /// returned cursor will be a [`SessionCursor`]. If [`with_type`](Aggregate::with_type) was
    /// called, the returned cursor will be generic over the `T` specified.
    #[deeplink]
    #[options_doc(aggregate)]
    pub fn aggregate(&self, pipeline: impl IntoIterator<Item = Document>) -> Aggregate<'_> {
        Aggregate::new(
            AggregateTargetRef::Collection(CollRef::new(self)),
            pipeline.into_iter().collect(),
        )
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Database {
    /// Runs an aggregation operation.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/aggregation/) for more
    /// information on aggregations.
    ///
    /// [`run`](Aggregate::run) will return d[`Result<crate::sync::Cursor<Document>>`]. If a
    /// [`crate::sync::ClientSession`] was provided, the returned cursor will be a
    /// [`crate::sync::SessionCursor`]. If [`with_type`](Aggregate::with_type) was called, the
    /// returned cursor will be generic over the `T` specified.
    #[deeplink]
    #[options_doc(aggregate, "run")]
    pub fn aggregate(&self, pipeline: impl IntoIterator<Item = Document>) -> Aggregate<'_> {
        self.async_database.aggregate(pipeline)
    }
}

#[cfg(feature = "sync")]
impl<T> crate::sync::Collection<T>
where
    T: Send + Sync,
{
    /// Runs an aggregation operation.
    ///
    /// See the documentation [here](https://www.mongodb.com/docs/manual/aggregation/) for more
    /// information on aggregations.
    ///
    /// [`run`](Aggregate::run) will return d[`Result<crate::sync::Cursor<Document>>`]. If a
    /// `crate::sync::ClientSession` was provided, the returned cursor will be a
    /// `crate::sync::SessionCursor`. If [`with_type`](Aggregate::with_type) was called, the
    /// returned cursor will be generic over the `T` specified.
    #[deeplink]
    #[options_doc(aggregate, "run")]
    pub fn aggregate(&self, pipeline: impl IntoIterator<Item = Document>) -> Aggregate<'_> {
        self.async_collection.aggregate(pipeline)
    }
}

/// Run an aggregation operation.  Construct with [`Database::aggregate`] or
/// [`Collection::aggregate`].
#[must_use]
pub struct Aggregate<'a, Session = ImplicitSession, T = Document> {
    target: AggregateTargetRef<'a>,
    pipeline: Vec<Document>,
    options: Option<AggregateOptions>,
    session: Session,
    _phantom: PhantomData<fn() -> T>,
}

impl<'a> Aggregate<'a> {
    fn new(target: AggregateTargetRef<'a>, pipeline: Vec<Document>) -> Self {
        Self {
            target,
            pipeline,
            options: None,
            session: ImplicitSession,
            _phantom: PhantomData,
        }
    }
}

#[option_setters(crate::coll::options::AggregateOptions)]
#[export_doc(aggregate, extra = [session, batch])]
impl<'a, Session, T> Aggregate<'a, Session, T> {
    /// Use the provided type for the returned cursor.
    ///
    /// ```rust
    /// # use futures_util::TryStreamExt;
    /// # use mongodb::{bson::Document, error::Result, Cursor, Database};
    /// # use serde::Deserialize;
    /// # async fn run() -> Result<()> {
    /// # let database: Database = todo!();
    /// # let pipeline: Vec<Document> = todo!();
    /// #[derive(Deserialize)]
    /// struct PipelineOutput {
    ///     len: usize,
    /// }
    ///
    /// let aggregate_cursor = database
    ///     .aggregate(pipeline)
    ///     .with_type::<PipelineOutput>()
    ///     .await?;
    /// let aggregate_results: Vec<PipelineOutput> = aggregate_cursor.try_collect().await?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn with_type<U>(self) -> Aggregate<'a, Session, U> {
        Aggregate {
            target: self.target,
            pipeline: self.pipeline,
            options: self.options,
            session: self.session,
            _phantom: PhantomData,
        }
    }
}

macro_rules! agg_exec_generic {
    ($agg:expr) => {{
        let mut aggregate = crate::operation::aggregate::Aggregate::new(
            (&$agg.target).into(),
            $agg.pipeline,
            $agg.options,
        );
        let client = $agg.target.client();
        client.execute_cursor_operation(&mut aggregate, None).await
    }};
}

impl<'a, T> Aggregate<'a, ImplicitSession, T> {
    /// Use the provided session when running the operation.
    pub fn session(
        self,
        value: impl Into<&'a mut ClientSession>,
    ) -> Aggregate<'a, ExplicitSession<'a>, T> {
        Aggregate {
            target: self.target,
            pipeline: self.pipeline,
            options: self.options,
            session: ExplicitSession(value.into()),
            _phantom: PhantomData,
        }
    }

    /// Execute the aggregate command, returning a cursor that provides results in zero-copy raw
    /// batches.
    pub async fn batch(self) -> Result<crate::raw_batch_cursor::RawBatchCursor> {
        agg_exec_generic!(self)
    }
}

#[action_impl(sync = crate::sync::Cursor<T>)]
impl<'a, T> Action for Aggregate<'a, ImplicitSession, T> {
    type Future = AggregateFuture;

    async fn execute(self) -> Result<Cursor<T>> {
        agg_exec_generic!(self)
    }
}

macro_rules! agg_exec_generic_session {
    ($agg:expr) => {{
        let mut aggregate = crate::operation::aggregate::Aggregate::new(
            (&$agg.target).into(),
            $agg.pipeline,
            $agg.options,
        );
        let client = $agg.target.client();
        let session = $agg.session;
        client
            .execute_cursor_operation(&mut aggregate, Some(session.0))
            .await
    }};
}

impl<'a, T> Aggregate<'a, ExplicitSession<'a>, T> {
    /// Execute the aggregate command, returning a cursor that provides results in zero-copy raw
    /// batches.
    pub async fn batch(self) -> Result<crate::raw_batch_cursor::SessionRawBatchCursor> {
        agg_exec_generic_session!(self)
    }
}

#[action_impl(sync = crate::sync::SessionCursor<T>)]
impl<'a, T> Action for Aggregate<'a, ExplicitSession<'a>, T> {
    type Future = AggregateSessionFuture;

    async fn execute(self) -> Result<SessionCursor<T>> {
        agg_exec_generic_session!(self)
    }
}

enum AggregateTargetRef<'a> {
    Database(&'a Database),
    Collection(CollRef<'a>),
}

impl AggregateTargetRef<'_> {
    fn client(&self) -> &Client {
        match self {
            Self::Collection(cr) => cr.client(),
            Self::Database(db) => db.client(),
        }
    }
}

impl From<&AggregateTargetRef<'_>> for OperationTarget {
    fn from(value: &AggregateTargetRef<'_>) -> Self {
        match value {
            AggregateTargetRef::Collection(cr) => OperationTarget::Collection((*cr).clone()),
            AggregateTargetRef::Database(db) => OperationTarget::Database((*db).clone()),
        }
    }
}

#[test]
fn aggregate_session_type() {
    // Assert that this code compiles but do not actually run it.
    #[allow(
        unreachable_code,
        unused_variables,
        dead_code,
        clippy::diverging_sub_expression
    )]
    fn compile_ok() {
        let agg: Aggregate = todo!();
        let typed: Aggregate<'_, _, ()> = agg.with_type::<()>();
        let mut session: ClientSession = todo!();
        let typed_session: Aggregate<'_, _, ()> = typed.session(&mut session);
    }
}
