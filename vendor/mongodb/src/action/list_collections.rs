use std::marker::PhantomData;

use crate::{
    action::ActionSession,
    bson::{Bson, Document},
    cursor::NewCursor,
};
use futures_util::TryStreamExt;

use crate::{
    db::options::ListCollectionsOptions,
    error::{Error, ErrorKind, Result},
    operation::list_collections as op,
    results::CollectionSpecification,
    ClientSession,
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
    ExplicitSession,
    ImplicitSession,
    ListNames,
    ListSpecifications,
};

impl Database {
    /// Gets information about each of the collections in the database.
    ///
    /// `await` will return d[`Result<Cursor<CollectionSpecification>>`].
    #[deeplink]
    #[options_doc(list_collections)]
    pub fn list_collections(&self) -> ListCollections<'_> {
        ListCollections {
            db: self,
            options: None,
            mode: PhantomData,
            session: ImplicitSession,
        }
    }

    /// Gets the names of the collections in the database.
    ///
    /// `await` will return d[`Result<Vec<String>>`].
    #[deeplink]
    #[options_doc(list_collection_names)]
    pub fn list_collection_names(&self) -> ListCollections<'_, ListNames> {
        ListCollections {
            db: self,
            options: None,
            mode: PhantomData,
            session: ImplicitSession,
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Database {
    /// Gets information about each of the collections in the database.
    ///
    /// [`run`](ListCollections::run) will return
    /// d[`Result<Cursor<CollectionSpecification>>`].
    #[deeplink]
    #[options_doc(list_collections, "run")]
    pub fn list_collections(&self) -> ListCollections<'_> {
        self.async_database.list_collections()
    }

    /// Gets the names of the collections in the database.
    ///
    /// [`run`](ListCollections::run) will return d[`Result<Vec<String>>`].
    #[deeplink]
    #[options_doc(list_collection_names, "run")]
    pub fn list_collection_names(&self) -> ListCollections<'_, ListNames> {
        self.async_database.list_collection_names()
    }
}

/// Gets information about each of the collections in the database.  Create by
/// calling [`Database::list_collections`] or [`Database::list_collection_names`].
#[must_use]
pub struct ListCollections<'a, M = ListSpecifications, S = ImplicitSession> {
    db: &'a Database,
    options: Option<ListCollectionsOptions>,
    mode: PhantomData<M>,
    session: S,
}

#[option_setters(crate::db::options::ListCollectionsOptions)]
#[export_doc(list_collection_names, extra = [session])]
impl<S> ListCollections<'_, ListNames, S> {}

impl<'a, M> ListCollections<'a, M, ImplicitSession> {
    /// Use the provided session when running the operation.
    pub fn session<'s>(
        self,
        value: impl Into<&'s mut ClientSession>,
    ) -> ListCollections<'a, M, ExplicitSession<'s>> {
        ListCollections {
            db: self.db,
            options: self.options,
            mode: PhantomData,
            session: ExplicitSession(value.into()),
        }
    }
}

#[option_setters(crate::db::options::ListCollectionsOptions)]
#[export_doc(list_collections, extra = [session, batch])]
impl<'a, S: ActionSession<'a>> ListCollections<'a, ListSpecifications, S> {
    async fn exec_generic<C: NewCursor>(self) -> Result<C> {
        let mut list_collections = op::ListCollections::new(self.db.clone(), false, self.options);
        self.db
            .client()
            .execute_cursor_operation(&mut list_collections, self.session.into_opt_session())
            .await
    }
}

#[action_impl(sync = crate::sync::Cursor<CollectionSpecification>)]
impl<'a> Action for ListCollections<'a, ListSpecifications, ImplicitSession> {
    type Future = ListCollectionsFuture;

    async fn execute(self) -> Result<Cursor<CollectionSpecification>> {
        self.exec_generic().await
    }
}

impl<'a> ListCollections<'a, ListSpecifications, ImplicitSession> {
    /// Execute the list collections command, returning a cursor that provides results in zero-copy
    /// raw batches.
    pub async fn batch(self) -> Result<crate::raw_batch_cursor::RawBatchCursor> {
        self.exec_generic().await
    }
}

#[action_impl(sync = crate::sync::SessionCursor<CollectionSpecification>)]
impl<'a> Action for ListCollections<'a, ListSpecifications, ExplicitSession<'a>> {
    type Future = ListCollectionsSessionFuture;

    async fn execute(self) -> Result<SessionCursor<CollectionSpecification>> {
        self.exec_generic().await
    }
}

impl<'a> ListCollections<'a, ListSpecifications, ExplicitSession<'a>> {
    /// Execute the list collections command, returning a cursor that provides results in zero-copy
    /// raw batches.
    pub async fn batch(self) -> Result<crate::raw_batch_cursor::SessionRawBatchCursor> {
        self.exec_generic().await
    }
}

async fn list_collection_names_common(
    cursor: impl TryStreamExt<Ok = Document, Error = Error>,
) -> Result<Vec<String>> {
    cursor
        .and_then(|doc| match doc.get("name").and_then(Bson::as_str) {
            Some(name) => futures_util::future::ok(name.into()),
            None => futures_util::future::err(
                ErrorKind::InvalidResponse {
                    message: "Expected name field in server response, but there was none."
                        .to_string(),
                }
                .into(),
            ),
        })
        .try_collect()
        .await
}

#[action_impl]
impl<'a> Action for ListCollections<'a, ListNames, ImplicitSession> {
    type Future = ListCollectionNamesFuture;

    async fn execute(self) -> Result<Vec<String>> {
        let mut list_collections = op::ListCollections::new(self.db.clone(), true, self.options);
        let cursor: Cursor<Document> = self
            .db
            .client()
            .execute_cursor_operation(&mut list_collections, None)
            .await?;
        return list_collection_names_common(cursor).await;
    }
}

#[action_impl]
impl<'a> Action for ListCollections<'a, ListNames, ExplicitSession<'a>> {
    type Future = ListCollectionNamesSessionFuture;

    async fn execute(self) -> Result<Vec<String>> {
        let mut list_collections = op::ListCollections::new(self.db.clone(), true, self.options);
        let mut cursor: SessionCursor<Document> = self
            .db
            .client()
            .execute_cursor_operation(&mut list_collections, Some(&mut *self.session.0))
            .await?;

        list_collection_names_common(cursor.stream(self.session.0)).await
    }
}
