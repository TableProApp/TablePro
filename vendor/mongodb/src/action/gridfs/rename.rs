use crate::bson::{doc, Bson};

use crate::{
    action::action_impl,
    error::{ErrorKind, GridFsErrorKind, GridFsFileIdentifier, Result},
    gridfs::GridFsBucket,
};

impl GridFsBucket {
    /// Renames the file with the given 'id' to the provided `new_filename`. This method returns an
    /// error if the `id` does not match any files in the bucket.
    ///
    /// `await` will return [`Result<()>`].
    pub fn rename(&self, id: Bson, new_filename: impl Into<String>) -> Rename<'_> {
        Rename {
            bucket: self,
            id,
            new_filename: new_filename.into(),
        }
    }

    /// Renames all revisions of the file with the given name to the provided `new_filename`. This
    /// method returns an error if the name does not match any files in the bucket.
    ///
    /// `await` will return [`Result<()>`].
    pub fn rename_by_name(
        &self,
        filename: impl Into<String>,
        new_filename: impl Into<String>,
    ) -> RenameByName<'_> {
        RenameByName {
            bucket: self,
            filename: filename.into(),
            new_filename: new_filename.into(),
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::gridfs::GridFsBucket {
    /// Renames the file with the given `id` to the provided `new_filename`. This method returns an
    /// error if the `id` does not match any files in the bucket.
    ///
    /// [`run`](Rename::run) will return [`Result<()>`].
    pub fn rename(&self, id: Bson, new_filename: impl Into<String>) -> Rename<'_> {
        self.async_bucket.rename(id, new_filename)
    }

    /// Renames all revisions of the file with the given name to the provided `new_filename`. This
    /// method returns an error if the name does not match any files in the bucket.
    ///
    /// [`run`](RenameByName::run) will return [`Result<()>`].
    pub fn rename_by_name(
        &self,
        filename: impl Into<String>,
        new_filename: impl Into<String>,
    ) -> RenameByName<'_> {
        self.async_bucket.rename_by_name(filename, new_filename)
    }
}

/// Renames a file.  Construct with [`GridFsBucket::rename`].
#[must_use]
pub struct Rename<'a> {
    bucket: &'a GridFsBucket,
    id: Bson,
    new_filename: String,
}

#[action_impl]
impl<'a> Action for Rename<'a> {
    type Future = RenameFuture;

    async fn execute(self) -> Result<()> {
        let count = self
            .bucket
            .files()
            .update_one(
                doc! { "_id": { "$eq": self.id.clone() } },
                doc! { "$set": { "filename": self.new_filename } },
            )
            .await?
            .matched_count;
        if count == 0 {
            return Err(ErrorKind::GridFs(GridFsErrorKind::FileNotFound {
                identifier: GridFsFileIdentifier::Id(self.id),
            })
            .into());
        }

        Ok(())
    }
}

/// Renames a file selected by name.  Construct with [`GridFsBucket::rename_by_name`].
#[must_use]
pub struct RenameByName<'a> {
    bucket: &'a GridFsBucket,
    filename: String,
    new_filename: String,
}

#[action_impl]
impl<'a> Action for RenameByName<'a> {
    type Future = RenameByNameFuture;

    async fn execute(self) -> Result<()> {
        let count = self
            .bucket
            .files()
            .update_many(
                doc! { "filename": self.filename.clone() },
                doc! { "$set": { "filename": self.new_filename } },
            )
            .await?
            .matched_count;
        if count == 0 {
            return Err(ErrorKind::GridFs(GridFsErrorKind::FileNotFound {
                identifier: GridFsFileIdentifier::Filename(self.filename),
            })
            .into());
        }

        Ok(())
    }
}
