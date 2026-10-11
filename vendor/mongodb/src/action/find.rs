use std::time::Duration;

use crate::bson::{Bson, Document};
use serde::de::DeserializeOwned;

use crate::{
    coll::options::{CursorType, FindOneOptions, FindOptions, Hint},
    collation::Collation,
    error::Result,
    operation::Find as Op,
    options::ReadConcern,
    selection_criteria::SelectionCriteria,
    ClientSession,
    Collection,
    Cursor,
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
};

impl<T: Send + Sync> Collection<T> {
    /// Finds the documents in the collection matching `filter`.
    ///
    /// `await` will return d[`Result<Cursor<T>>`] (or d[`Result<SessionCursor<T>>`] if a session is
    /// provided).
    #[deeplink]
    #[options_doc(find)]
    pub fn find(&self, filter: Document) -> Find<'_, T> {
        Find {
            coll: self,
            filter,
            options: None,
            session: ImplicitSession,
        }
    }
}

impl<T: DeserializeOwned + Send + Sync> Collection<T> {
    /// Finds a single document in the collection matching `filter`.
    ///
    /// `await` will return d[`Result<Option<T>>`].
    #[deeplink]
    #[options_doc(find_one)]
    pub fn find_one(&self, filter: Document) -> FindOne<'_, T> {
        FindOne {
            coll: self,
            filter,
            options: None,
            session: None,
        }
    }
}

#[cfg(feature = "sync")]
impl<T: Send + Sync> crate::sync::Collection<T> {
    /// Finds the documents in the collection matching `filter`.
    ///
    /// [`run`](Find::run) will return d[`Result<crate::sync::Cursor<T>>`] (or
    /// d[`Result<crate::sync::SessionCursor<T>>`] if a session is provided).
    #[deeplink]
    #[options_doc(find, "run")]
    pub fn find(&self, filter: Document) -> Find<'_, T> {
        self.async_collection.find(filter)
    }
}

#[cfg(feature = "sync")]
impl<T: DeserializeOwned + Send + Sync> crate::sync::Collection<T> {
    /// Finds a single document in the collection matching `filter`.
    ///
    /// [`run`](FindOne::run) will return d[`Result<Option<T>>`].
    #[deeplink]
    #[options_doc(find_one, "run")]
    pub fn find_one(&self, filter: Document) -> FindOne<'_, T> {
        self.async_collection.find_one(filter)
    }
}

/// Finds the documents in a collection matching a filter.  Construct with [`Collection::find`].
#[must_use]
pub struct Find<'a, T: Send + Sync, Session = ImplicitSession> {
    coll: &'a Collection<T>,
    filter: Document,
    options: Option<FindOptions>,
    session: Session,
}

#[option_setters(crate::coll::options::FindOptions)]
#[export_doc(find, extra = [batch])]
impl<'a, T: Send + Sync, Session> Find<'a, T, Session> {
    /// Use the provided session when running the operation.
    pub fn session<'s>(
        self,
        value: impl Into<&'s mut ClientSession>,
    ) -> Find<'a, T, ExplicitSession<'s>> {
        Find {
            coll: self.coll,
            filter: self.filter,
            options: self.options,
            session: ExplicitSession(value.into()),
        }
    }
}

#[action_impl(sync = crate::sync::Cursor<T>)]
impl<'a, T: Send + Sync> Action for Find<'a, T, ImplicitSession> {
    type Future = FindFuture;

    async fn execute(mut self) -> Result<Cursor<T>> {
        self.exec_generic().await
    }
}

impl<'a, T: Send + Sync> Find<'a, T, ImplicitSession> {
    async fn exec_generic<C: crate::cursor::NewCursor>(self) -> Result<C> {
        let mut find = Op::new(self.coll.clone_with_type(), self.filter, self.options);
        self.coll
            .client()
            .execute_cursor_operation(&mut find, None)
            .await
    }

    /// Execute the find command, returning a cursor that provides results in zero-copy raw batches.
    pub async fn batch(self) -> Result<crate::raw_batch_cursor::RawBatchCursor> {
        self.exec_generic().await
    }
}

#[action_impl(sync = crate::sync::SessionCursor<T>)]
impl<'a, T: Send + Sync> Action for Find<'a, T, ExplicitSession<'a>> {
    type Future = FindSessionFuture;

    async fn execute(mut self) -> Result<SessionCursor<T>> {
        self.exec_generic().await
    }
}

impl<'a, T: Send + Sync> Find<'a, T, ExplicitSession<'a>> {
    async fn exec_generic<C: crate::cursor::NewCursor>(self) -> Result<C> {
        let mut find = Op::new(self.coll.clone_with_type(), self.filter, self.options);
        self.coll
            .client()
            .execute_cursor_operation(&mut find, Some(self.session.0))
            .await
    }

    /// Execute the find command, returning a cursor that provides results in zero-copy raw batches.
    pub async fn batch(self) -> Result<crate::raw_batch_cursor::SessionRawBatchCursor> {
        self.exec_generic().await
    }
}

/// Finds a single document in a collection matching a filter.  Construct with
/// [`Collection::find_one`].
#[must_use]
pub struct FindOne<'a, T: Send + Sync> {
    coll: &'a Collection<T>,
    filter: Document,
    options: Option<FindOneOptions>,
    session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::coll::options::FindOneOptions)]
#[export_doc(find_one)]
impl<'a, T: Send + Sync> FindOne<'a, T> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a, T: DeserializeOwned + Send + Sync> Action for FindOne<'a, T> {
    type Future = FindOneFuture;

    async fn execute(self) -> Result<Option<T>> {
        use futures_util::stream::StreamExt;
        let mut options: FindOptions = self.options.unwrap_or_default().into();
        options.limit = Some(-1);
        let find = self.coll.find(self.filter).with_options(options);
        if let Some(session) = self.session {
            let mut cursor = find.session(&mut *session).await?;
            let mut stream = cursor.stream(session);
            stream.next().await.transpose()
        } else {
            let mut cursor = find.await?;
            cursor.next().await.transpose()
        }
    }
}
