use crate::bson::{Bson, Document};

use crate::{
    coll::options::{Hint, UpdateModifications, UpdateOptions},
    collation::Collation,
    error::Result,
    operation::Update as Op,
    options::WriteConcern,
    results::UpdateResult,
    ClientSession,
    Collection,
};

use super::{action_impl, deeplink, export_doc, option_setters, options_doc, CollRef};

impl<T> Collection<T>
where
    T: Send + Sync,
{
    /// Updates all documents matching `query` in the collection.
    ///
    /// Both `Document` and `Vec<Document>` implement `Into<UpdateModifications>`, so either can be
    /// passed in place of constructing the enum case. See the official MongoDB
    /// [documentation](https://www.mongodb.com/docs/manual/reference/command/update/#behavior) for more information on specifying updates.
    ///
    /// `await` will return d[`Result<UpdateResult>`].
    #[deeplink]
    #[options_doc(update)]
    pub fn update_many(
        &self,
        query: Document,
        update: impl Into<UpdateModifications>,
    ) -> Update<'_> {
        Update {
            coll: CollRef::new(self),
            query,
            update: update.into(),
            multi: true,
            options: None,
            session: None,
        }
    }

    /// Updates up to one document matching `query` in the collection.
    ///
    /// Both `Document` and `Vec<Document>` implement `Into<UpdateModifications>`, so either can be
    /// passed in place of constructing the enum case. See the official MongoDB
    /// [documentation](https://www.mongodb.com/docs/manual/reference/command/update/#behavior) for more information on specifying updates.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// `await` will return d[`Result<UpdateResult>`].
    #[deeplink]
    #[options_doc(update)]
    pub fn update_one(
        &self,
        query: Document,
        update: impl Into<UpdateModifications>,
    ) -> Update<'_> {
        Update {
            coll: CollRef::new(self),
            query,
            update: update.into(),
            multi: false,
            options: None,
            session: None,
        }
    }
}

#[cfg(feature = "sync")]
impl<T> crate::sync::Collection<T>
where
    T: Send + Sync,
{
    /// Updates all documents matching `query` in the collection.
    ///
    /// Both `Document` and `Vec<Document>` implement `Into<UpdateModifications>`, so either can be
    /// passed in place of constructing the enum case. See the official MongoDB
    /// [documentation](https://www.mongodb.com/docs/manual/reference/command/update/#behavior) for more information on specifying updates.
    ///
    /// [`run`](Update::run) will return d[`Result<UpdateResult>`].
    #[deeplink]
    #[options_doc(update, "run")]
    pub fn update_many(
        &self,
        query: Document,
        update: impl Into<UpdateModifications>,
    ) -> Update<'_> {
        self.async_collection.update_many(query, update)
    }

    /// Updates up to one document matching `query` in the collection.
    ///
    /// Both `Document` and `Vec<Document>` implement `Into<UpdateModifications>`, so either can be
    /// passed in place of constructing the enum case. See the official MongoDB
    /// [documentation](https://www.mongodb.com/docs/manual/reference/command/update/#behavior) for more information on specifying updates.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// [`run`](Update::run) will return d[`Result<UpdateResult>`].
    #[deeplink]
    #[options_doc(update, "run")]
    pub fn update_one(
        &self,
        query: Document,
        update: impl Into<UpdateModifications>,
    ) -> Update<'_> {
        self.async_collection.update_one(query, update)
    }
}

/// Update documents matching a query.  Construct with [`Collection::update_many`] or
/// [`Collection::update_one`].
#[must_use]
pub struct Update<'a> {
    coll: CollRef<'a>,
    query: Document,
    update: UpdateModifications,
    multi: bool,
    options: Option<UpdateOptions>,
    session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::coll::options::UpdateOptions)]
#[export_doc(update)]
impl<'a> Update<'a> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a> Action for Update<'a> {
    type Future = UpdateFuture;

    async fn execute(self) -> Result<UpdateResult> {
        if let UpdateModifications::Document(d) = &self.update {
            crate::bson_util::update_document_check(d)?;
        }
        let op = Op::with_update(
            self.coll.clone(),
            self.query,
            self.update,
            self.multi,
            self.options,
        );
        self.coll.client().execute_operation(op, self.session).await
    }
}
