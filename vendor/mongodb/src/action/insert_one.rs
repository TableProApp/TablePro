use std::{borrow::Borrow, ops::Deref};

use crate::bson::{Bson, RawDocumentBuf};
use serde::Serialize;

use crate::{
    coll::options::{InsertManyOptions, InsertOneOptions},
    error::{convert_insert_many_error, Result},
    operation::Insert as Op,
    options::WriteConcern,
    results::InsertOneResult,
    ClientSession,
    Collection,
};

use super::{action_impl, deeplink, export_doc, option_setters, options_doc, CollRef};

impl<T: Serialize + Send + Sync> Collection<T> {
    /// Inserts `doc` into the collection.
    ///
    /// Note that either an owned or borrowed value can be inserted here, so the input document
    /// does not need to be cloned to be passed in.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// `await` will return d[`Result<InsertOneResult>`].
    #[deeplink]
    #[options_doc(insert_one)]
    pub fn insert_one(&self, doc: impl Borrow<T>) -> InsertOne<'_> {
        InsertOne {
            coll: CollRef::new(self),
            doc: crate::bson_compat::serialize_to_raw_document_buf(doc.borrow())
                .map_err(Into::into),
            options: None,
            session: None,
        }
    }
}

#[cfg(feature = "sync")]
impl<T: Serialize + Send + Sync> crate::sync::Collection<T> {
    /// Inserts `doc` into the collection.
    ///
    /// Note that either an owned or borrowed value can be inserted here, so the input document
    /// does not need to be cloned to be passed in.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// [`run`](InsertOne::run) will return d[`Result<InsertOneResult>`].
    #[deeplink]
    #[options_doc(insert_one, "run")]
    pub fn insert_one(&self, doc: impl Borrow<T>) -> InsertOne<'_> {
        self.async_collection.insert_one(doc)
    }
}

/// Inserts a document into a collection.  Construct with [`Collection::insert_one`].
#[must_use]
pub struct InsertOne<'a> {
    coll: CollRef<'a>,
    doc: Result<RawDocumentBuf>,
    options: Option<InsertOneOptions>,
    session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::coll::options::InsertOneOptions)]
#[export_doc(insert_one)]
impl<'a> InsertOne<'a> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a> Action for InsertOne<'a> {
    type Future = InsertOneFuture;

    async fn execute(mut self) -> Result<InsertOneResult> {
        let doc = self.doc?;

        let insert = Op::new(
            self.coll.clone(),
            vec![doc.deref()],
            self.options.map(InsertManyOptions::from_insert_one_options),
            self.coll.client().should_auto_encrypt().await,
        );
        self.coll
            .client()
            .execute_operation(insert, self.session)
            .await
            .map(InsertOneResult::from_insert_many_result)
            .map_err(convert_insert_many_error)
    }
}
