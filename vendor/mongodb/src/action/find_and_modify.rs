use std::{borrow::Borrow, time::Duration};

use crate::bson::{Bson, Document, RawDocumentBuf};
use serde::{de::DeserializeOwned, Serialize};

use crate::{
    coll::options::{
        FindOneAndDeleteOptions,
        FindOneAndReplaceOptions,
        FindOneAndUpdateOptions,
        Hint,
        ReturnDocument,
        UpdateModifications,
    },
    collation::Collation,
    error::Result,
    operation::{
        find_and_modify::options::{FindAndModifyOptions, Modification},
        FindAndModify as Op,
        UpdateOrReplace,
    },
    options::WriteConcern,
    ClientSession,
    Collection,
};

use super::{action_impl, deeplink, export_doc, option_setters, options_doc};

impl<T: DeserializeOwned + Send + Sync> Collection<T> {
    async fn find_and_modify(
        &self,
        filter: Document,
        modification: Modification,
        options: Option<FindAndModifyOptions>,
        session: Option<&mut ClientSession>,
    ) -> Result<Option<T>> {
        let op = Op::<T>::with_modification(self.clone_with_type(), filter, modification, options)?;
        self.client().execute_operation(op, session).await
    }

    /// Atomically finds up to one document in the collection matching `filter` and deletes it.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// `await` will return d[`Result<Option<T>>`].
    #[deeplink]
    #[options_doc(find_one_and_delete)]
    pub fn find_one_and_delete(&self, filter: Document) -> FindOneAndDelete<'_, T> {
        FindOneAndDelete {
            coll: self,
            filter,
            options: None,
            session: None,
        }
    }

    /// Atomically finds up to one document in the collection matching `filter` and updates it.
    /// Both `Document` and `Vec<Document>` implement `Into<UpdateModifications>`, so either can be
    /// passed in place of constructing the enum case.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// `await` will return d[`Result<Option<T>>`].
    #[deeplink]
    #[options_doc(find_one_and_update)]
    pub fn find_one_and_update(
        &self,
        filter: Document,
        update: impl Into<UpdateModifications>,
    ) -> FindOneAndUpdate<'_, T> {
        FindOneAndUpdate {
            coll: self,
            filter,
            update: update.into(),
            options: None,
            session: None,
        }
    }
}

impl<T: Serialize + DeserializeOwned + Send + Sync> Collection<T> {
    /// Atomically finds up to one document in the collection matching `filter` and replaces it with
    /// `replacement`.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// `await` will return d[`Result<Option<T>>`].
    #[deeplink]
    #[options_doc(find_one_and_replace)]
    pub fn find_one_and_replace(
        &self,
        filter: Document,
        replacement: impl Borrow<T>,
    ) -> FindOneAndReplace<'_, T> {
        FindOneAndReplace {
            coll: self,
            filter,
            replacement: crate::bson_compat::serialize_to_raw_document_buf(replacement.borrow())
                .map_err(Into::into),
            options: None,
            session: None,
        }
    }
}

#[cfg(feature = "sync")]
impl<T: DeserializeOwned + Send + Sync> crate::sync::Collection<T> {
    /// Atomically finds up to one document in the collection matching `filter` and deletes it.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// [`run`](FindOneAndDelete::run) will return d[`Result<Option<T>>`].
    #[deeplink]
    #[options_doc(find_one_and_delete, "run")]
    pub fn find_one_and_delete(&self, filter: Document) -> FindOneAndDelete<'_, T> {
        self.async_collection.find_one_and_delete(filter)
    }

    /// Atomically finds up to one document in the collection matching `filter` and updates it.
    /// Both `Document` and `Vec<Document>` implement `Into<UpdateModifications>`, so either can be
    /// passed in place of constructing the enum case.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// [`run`](FindOneAndDelete::run) will return d[`Result<Option<T>>`].
    #[deeplink]
    #[options_doc(find_one_and_update, "run")]
    pub fn find_one_and_update(
        &self,
        filter: Document,
        update: impl Into<UpdateModifications>,
    ) -> FindOneAndUpdate<'_, T> {
        self.async_collection.find_one_and_update(filter, update)
    }
}

#[cfg(feature = "sync")]
impl<T: Serialize + DeserializeOwned + Send + Sync> crate::sync::Collection<T> {
    /// Atomically finds up to one document in the collection matching `filter` and replaces it with
    /// `replacement`.
    ///
    /// This operation will retry once upon failure if the connection and encountered error support
    /// retryability. See the documentation
    /// [here](https://www.mongodb.com/docs/manual/core/retryable-writes/) for more information on
    /// retryable writes.
    ///
    /// [`run`](FindOneAndReplace::run) will return d[`Result<Option<T>>`].
    #[deeplink]
    #[options_doc(find_one_and_replace, "run")]
    pub fn find_one_and_replace(
        &self,
        filter: Document,
        replacement: impl Borrow<T>,
    ) -> FindOneAndReplace<'_, T> {
        self.async_collection
            .find_one_and_replace(filter, replacement)
    }
}

/// Atomically finds up to one document in the collection matching a filter and deletes it.
/// Construct with [`Collection::find_one_and_delete`].
#[must_use]
pub struct FindOneAndDelete<'a, T: Send + Sync> {
    coll: &'a Collection<T>,
    filter: Document,
    options: Option<FindOneAndDeleteOptions>,
    session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::coll::options::FindOneAndDeleteOptions)]
#[export_doc(find_one_and_delete)]
impl<'a, T: Send + Sync> FindOneAndDelete<'a, T> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a, T: DeserializeOwned + Send + Sync> Action for FindOneAndDelete<'a, T> {
    type Future = FindOneAndDeleteFuture;

    async fn execute(self) -> Result<Option<T>> {
        self.coll
            .find_and_modify(
                self.filter,
                Modification::Delete,
                self.options.map(FindAndModifyOptions::from),
                self.session,
            )
            .await
    }
}

/// Atomically finds up to one document in the collection matching a filter and updates it.
/// Construct with [`Collection::find_one_and_update`].
#[must_use]
pub struct FindOneAndUpdate<'a, T: Send + Sync> {
    coll: &'a Collection<T>,
    filter: Document,
    update: UpdateModifications,
    options: Option<FindOneAndUpdateOptions>,
    session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::coll::options::FindOneAndUpdateOptions)]
#[export_doc(find_one_and_update)]
impl<'a, T: Send + Sync> FindOneAndUpdate<'a, T> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a, T: DeserializeOwned + Send + Sync> Action for FindOneAndUpdate<'a, T> {
    type Future = FindOneAndUpdateFuture;

    async fn execute(self) -> Result<Option<T>> {
        self.coll
            .find_and_modify(
                self.filter,
                Modification::Update(self.update.into()),
                self.options.map(FindAndModifyOptions::from),
                self.session,
            )
            .await
    }
}

/// Atomically finds up to one document in the collection matching a filter and replaces it.
/// Construct with [`Collection::find_one_and_replace`].
#[must_use]
pub struct FindOneAndReplace<'a, T: Send + Sync> {
    coll: &'a Collection<T>,
    filter: Document,
    replacement: Result<RawDocumentBuf>,
    options: Option<FindOneAndReplaceOptions>,
    session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::coll::options::FindOneAndReplaceOptions)]
#[export_doc(find_one_and_replace)]
impl<'a, T: Send + Sync> FindOneAndReplace<'a, T> {
    /// Use the provided session when running the operation.
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a, T: DeserializeOwned + Send + Sync> Action for FindOneAndReplace<'a, T> {
    type Future = FindOneAndReplaceFuture;

    async fn execute(self) -> Result<Option<T>> {
        self.coll
            .find_and_modify(
                self.filter,
                Modification::Update(UpdateOrReplace::Replacement(self.replacement?)),
                self.options.map(FindAndModifyOptions::from),
                self.session,
            )
            .await
    }
}
