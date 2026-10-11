use std::{marker::PhantomData, time::Duration};

use crate::bson::Bson;

use crate::{
    coll::options::{CommitQuorum, CreateIndexOptions},
    error::Result,
    operation::CreateIndexes as Op,
    options::WriteConcern,
    results::{CreateIndexResult, CreateIndexesResult},
    ClientSession,
    Collection,
    IndexModel,
};

use super::{
    action_impl,
    deeplink,
    export_doc,
    option_setters,
    options_doc,
    CollRef,
    Multiple,
    Single,
};

impl<T> Collection<T>
where
    T: Send + Sync,
{
    /// Creates the given index on this collection.
    ///
    /// `await` will return d[`Result<CreateIndexResult>`].
    #[deeplink]
    #[options_doc(create_index)]
    pub fn create_index(&self, index: IndexModel) -> CreateIndex<'_> {
        CreateIndex {
            coll: CollRef::new(self),
            indexes: vec![index],
            options: None,
            session: None,
            _mode: PhantomData,
        }
    }

    /// Creates the given indexes on this collection.
    ///
    /// `await` will return d[`Result<CreateIndexesResult>`].
    #[deeplink]
    #[options_doc(create_index)]
    pub fn create_indexes(
        &self,
        indexes: impl IntoIterator<Item = IndexModel>,
    ) -> CreateIndex<'_, Multiple> {
        CreateIndex {
            coll: CollRef::new(self),
            indexes: indexes.into_iter().collect(),
            options: None,
            session: None,
            _mode: PhantomData,
        }
    }
}

#[cfg(feature = "sync")]
impl<T> crate::sync::Collection<T>
where
    T: Send + Sync,
{
    /// Creates the given index on this collection.
    ///
    /// [`run`](CreateIndex::run) will return d[`Result<CreateIndexResult>`].
    #[deeplink]
    #[options_doc(create_index, "run")]
    pub fn create_index(&self, index: IndexModel) -> CreateIndex<'_> {
        self.async_collection.create_index(index)
    }

    /// Creates the given indexes on this collection.
    ///
    /// [`run`](CreateIndex::run) will return d[`Result<CreateIndexesResult>`].
    #[deeplink]
    #[options_doc(create_index, "run")]
    pub fn create_indexes(
        &self,
        indexes: impl IntoIterator<Item = IndexModel>,
    ) -> CreateIndex<'_, Multiple> {
        self.async_collection.create_indexes(indexes)
    }
}

/// Perform creation of an index or indexes.  Construct by calling [`Collection::create_index`] or
/// [`Collection::create_indexes`].
#[must_use]
pub struct CreateIndex<'a, M = Single> {
    coll: CollRef<'a>,
    indexes: Vec<IndexModel>,
    options: Option<CreateIndexOptions>,
    session: Option<&'a mut ClientSession>,
    _mode: PhantomData<M>,
}

#[option_setters(crate::coll::options::CreateIndexOptions)]
#[export_doc(create_index)]
impl<'a, M> CreateIndex<'a, M> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a> Action for CreateIndex<'a, Single> {
    type Future = CreateIndexFuture;

    async fn execute(self) -> Result<CreateIndexResult> {
        let inner: CreateIndex<'a, Multiple> = CreateIndex {
            coll: self.coll,
            indexes: self.indexes,
            options: self.options,
            session: self.session,
            _mode: PhantomData,
        };
        let response = inner.await?;
        Ok(response.into_create_index_result())
    }
}

#[action_impl]
impl<'a> Action for CreateIndex<'a, Multiple> {
    type Future = CreateIndexesFuture;

    async fn execute(self) -> Result<CreateIndexesResult> {
        let op = Op::new(self.coll.clone(), self.indexes, self.options);
        self.coll.client().execute_operation(op, self.session).await
    }
}
