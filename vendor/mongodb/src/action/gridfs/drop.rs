use crate::{action::action_impl, error::Result, gridfs::GridFsBucket};

impl GridFsBucket {
    /// Removes all of the files and their associated chunks from this bucket.
    ///
    /// `await` will return [`Result<()>`].
    pub fn drop(&self) -> Drop<'_> {
        Drop { bucket: self }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::gridfs::GridFsBucket {
    /// Removes all of the files and their associated chunks from this bucket.
    ///
    /// [`run`](Drop::run) will return [`Result<()>`].
    pub fn drop(&self) -> Drop<'_> {
        self.async_bucket.drop()
    }
}

/// Removes all of the files and their associated chunks from a bucket.  Construct with
/// [`GridFsBucket::drop`].
#[must_use]
pub struct Drop<'a> {
    bucket: &'a GridFsBucket,
}

#[action_impl]
impl<'a> Action for Drop<'a> {
    type Future = DropFuture;

    async fn execute(self) -> Result<()> {
        self.bucket.files().drop().await?;
        self.bucket.chunks().drop().await?;

        Ok(())
    }
}
