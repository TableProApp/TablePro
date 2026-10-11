use std::time::Duration;

use crate::bson::Document;

use crate::{
    action::{action_impl, deeplink, export_doc, option_setters, options_doc},
    coll::options::{FindOneOptions, FindOptions},
    error::Result,
    gridfs::{FilesCollectionDocument, GridFsBucket, GridFsFindOneOptions, GridFsFindOptions},
    Cursor,
};

impl GridFsBucket {
    /// Finds and returns the [`FilesCollectionDocument`]s within this bucket that match the given
    /// filter.
    ///
    /// `await` will return d[`Result<Cursor<FilesCollectionDocument>>`].
    #[deeplink]
    #[options_doc(find)]
    pub fn find(&self, filter: Document) -> Find<'_> {
        Find {
            bucket: self,
            filter,
            options: None,
        }
    }

    /// Finds and returns a single [`FilesCollectionDocument`] within this bucket that matches the
    /// given filter.
    ///
    /// `await` will return d[`Result<Option<FilesCollectionDocument>>`].
    #[deeplink]
    #[options_doc(find_one)]
    pub fn find_one(&self, filter: Document) -> FindOne<'_> {
        FindOne {
            bucket: self,
            filter,
            options: None,
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::gridfs::GridFsBucket {
    /// Finds and returns the [`FilesCollectionDocument`]s within this bucket that match the given
    /// filter.
    ///
    /// [`run`](Find::run) will return d[`Result<crate::sync::Cursor<FilesCollectionDocument>>`].
    #[deeplink]
    #[options_doc(find, "run")]
    pub fn find(&self, filter: Document) -> Find<'_> {
        self.async_bucket.find(filter)
    }

    /// Finds and returns a single [`FilesCollectionDocument`] within this bucket that matches the
    /// given filter.
    ///
    /// [`run`](FindOne::run) will return d[`Result<Option<FilesCollectionDocument>>`].
    #[deeplink]
    #[options_doc(find_one, "run")]
    pub fn find_one(&self, filter: Document) -> FindOne<'_> {
        self.async_bucket.find_one(filter)
    }
}

/// Finds and returns the [`FilesCollectionDocument`]s within a bucket that match a given
/// filter.  Construct with [`GridFsBucket::find`].
#[must_use]
pub struct Find<'a> {
    bucket: &'a GridFsBucket,
    filter: Document,
    options: Option<GridFsFindOptions>,
}

#[option_setters(crate::gridfs::options::GridFsFindOptions)]
#[export_doc(find)]
impl Find<'_> {}

#[action_impl(sync = crate::sync::Cursor<FilesCollectionDocument>)]
impl<'a> Action for Find<'a> {
    type Future = FindFuture;

    async fn execute(self) -> Result<Cursor<FilesCollectionDocument>> {
        let find_options = self.options.map(FindOptions::from);
        self.bucket
            .files()
            .find(self.filter)
            .with_options(find_options)
            .await
    }
}

/// Finds and returns a single [`FilesCollectionDocument`] within a bucket that matches a
/// given filter.  Construct with [`GridFsBucket::find_one`].
#[must_use]
pub struct FindOne<'a> {
    bucket: &'a GridFsBucket,
    filter: Document,
    options: Option<GridFsFindOneOptions>,
}

#[option_setters(crate::gridfs::options::GridFsFindOneOptions)]
#[export_doc(find_one)]
impl FindOne<'_> {}

#[action_impl]
impl<'a> Action for FindOne<'a> {
    type Future = FindOneFuture;

    async fn execute(self) -> Result<Option<FilesCollectionDocument>> {
        let find_options = self.options.map(FindOneOptions::from);
        self.bucket
            .files()
            .find_one(self.filter)
            .with_options(find_options)
            .await
    }
}
