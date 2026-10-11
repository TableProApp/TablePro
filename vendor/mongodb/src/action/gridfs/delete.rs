use crate::bson::{doc, Bson};

#[cfg(docsrs)]
use crate::gridfs::FilesCollectionDocument;
use crate::{
    action::action_impl,
    error::{ErrorKind, GridFsErrorKind, GridFsFileIdentifier, Result},
    gridfs::GridFsBucket,
};

impl GridFsBucket {
    /// Deletes the [`FilesCollectionDocument`] with the given `id` and its associated chunks from
    /// this bucket. This method returns an error if the `id` does not match any files in the
    /// bucket.
    ///
    /// `await` will return [`Result<()>`].
    pub fn delete(&self, id: Bson) -> Delete<'_> {
        Delete { bucket: self, id }
    }

    /// Deletes the [`FilesCollectionDocument`] with the given name and its associated chunks from
    /// this bucket. This method returns an error if the name does not match any files in the
    /// bucket.
    ///
    /// `await` will return [`Result<()>`].
    pub fn delete_by_name(&self, filename: impl Into<String>) -> DeleteByName<'_> {
        DeleteByName {
            bucket: self,
            filename: filename.into(),
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::gridfs::GridFsBucket {
    /// Deletes the [`FilesCollectionDocument`] with the given `id` and its associated chunks from
    /// this bucket. This method returns an error if the `id` does not match any files in the
    /// bucket.
    ///
    /// [`run`](Delete::run) will return [`Result<()>`].
    pub fn delete(&self, id: Bson) -> Delete<'_> {
        self.async_bucket.delete(id)
    }

    /// Deletes the [`FilesCollectionDocument`] with the given name and its associated chunks from
    /// this bucket. This method returns an error if the name does not match any files in the
    /// bucket.
    ///
    /// [`run`](DeleteByName::run) will return [`Result<()>`].
    pub fn delete_by_name(&self, filename: impl Into<String>) -> DeleteByName<'_> {
        self.async_bucket.delete_by_name(filename)
    }
}

/// Deletes a specific [`FilesCollectionDocument`] and its associated chunks.  Construct with
/// [`GridFsBucket::delete`].
#[must_use]
pub struct Delete<'a> {
    bucket: &'a GridFsBucket,
    id: Bson,
}

#[action_impl]
impl<'a> Action for Delete<'a> {
    type Future = DeleteFuture;

    async fn execute(self) -> Result<()> {
        let delete_result = self
            .bucket
            .files()
            .delete_one(doc! { "_id": { "$eq": self.id.clone() } })
            .await?;
        // Delete chunks regardless of whether a file was found. This will remove any possibly
        // orphaned chunks.
        self.bucket
            .chunks()
            .delete_many(doc! { "files_id": { "$eq": self.id.clone() } })
            .await?;

        if delete_result.deleted_count == 0 {
            return Err(ErrorKind::GridFs(GridFsErrorKind::FileNotFound {
                identifier: GridFsFileIdentifier::Id(self.id),
            })
            .into());
        }

        Ok(())
    }
}

/// Deletes a named [`FilesCollectionDocument`] and its associated chunks.  Construct with
/// [`GridFsBucket::delete_by_name`].
#[must_use]
pub struct DeleteByName<'a> {
    bucket: &'a GridFsBucket,
    filename: String,
}

#[action_impl]
impl<'a> Action for DeleteByName<'a> {
    type Future = DeleteByNameFuture;

    async fn execute(self) -> Result<()> {
        use futures_util::stream::{StreamExt, TryStreamExt};
        let ids: Vec<_> = self
            .bucket
            .files()
            .find(doc! { "filename": self.filename.clone() })
            .projection(doc! { "_id": 1 })
            .await?
            .with_type::<crate::bson::Document>()
            .map(|r| match r {
                Ok(mut d) => d
                    .remove("_id")
                    .ok_or_else(|| crate::error::Error::internal("_id field expected")),
                Err(e) => Err(e),
            })
            .try_collect()
            .await?;

        let count = self
            .bucket
            .files()
            .delete_many(doc! { "_id": { "$in": ids.clone() } })
            .await?
            .deleted_count;
        self.bucket
            .chunks()
            .delete_many(doc! { "files_id": { "$in": ids } })
            .await?;

        if count == 0 {
            return Err(ErrorKind::GridFs(GridFsErrorKind::FileNotFound {
                identifier: GridFsFileIdentifier::Filename(self.filename),
            })
            .into());
        }

        Ok(())
    }
}
