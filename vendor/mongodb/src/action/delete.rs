use crate::bson::{Bson, Document};

use crate::{
    coll::options::{DeleteOptions, Hint},
    collation::Collation,
    error::Result,
    operation::Delete as Op,
    options::WriteConcern,
    results::DeleteResult,
    ClientSession,
    Collection,
};

use super::{action_impl, deeplink, export_doc, option_setters, options_doc, CollRef};

impl<T> Collection<T>
where
    T: Send + Sync,
{
    /// Deletes up to one document found matching `query`.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// `await` will return d[`Result<DeleteResult>`].
    #[deeplink]
    #[options_doc(delete)]
    pub fn delete_one(&self, query: Document) -> Delete<'_> {
        Delete {
            coll: CollRef::new(self),
            query,
            options: None,
            session: None,
            limit: Some(1),
        }
    }

    /// Deletes all documents stored in the collection matching `query`.
    ///
    /// `await` will return d[`Result<DeleteResult>`].
    #[deeplink]
    #[options_doc(delete)]
    pub fn delete_many(&self, query: Document) -> Delete<'_> {
        Delete {
            coll: CollRef::new(self),
            query,
            options: None,
            session: None,
            limit: None,
        }
    }
}

#[cfg(feature = "sync")]
impl<T> crate::sync::Collection<T>
where
    T: Send + Sync,
{
    /// Deletes up to one document found matching `query`.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// [`run`](Delete::run) will return d[`Result<DeleteResult>`].
    #[deeplink]
    #[options_doc(delete, "run")]
    pub fn delete_one(&self, query: Document) -> Delete<'_> {
        self.async_collection.delete_one(query)
    }

    /// Deletes all documents stored in the collection matching `query`.
    ///
    /// [`run`](Delete::run) will return d[`Result<DeleteResult>`].
    #[deeplink]
    #[options_doc(delete, "run")]
    pub fn delete_many(&self, query: Document) -> Delete<'_> {
        self.async_collection.delete_many(query)
    }
}

/// Deletes documents matching a query.  Construct with [`Collection::delete_one`] or
/// [`Collection::delete_many`].
#[must_use]
pub struct Delete<'a> {
    coll: CollRef<'a>,
    query: Document,
    options: Option<DeleteOptions>,
    session: Option<&'a mut ClientSession>,
    limit: Option<u32>,
}

#[option_setters(crate::coll::options::DeleteOptions)]
#[export_doc(delete)]
impl<'a> Delete<'a> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a> Action for Delete<'a> {
    type Future = DeleteFuture;

    async fn execute(self) -> Result<DeleteResult> {
        let op = Op::new(self.coll.clone(), self.query, self.limit, self.options);
        self.coll.client().execute_operation(op, self.session).await
    }
}
