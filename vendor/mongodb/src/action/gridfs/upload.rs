use crate::bson::{oid::ObjectId, Bson, Document};

#[cfg(docsrs)]
use crate::gridfs::FilesCollectionDocument;
use crate::{
    action::{action_impl, deeplink, export_doc, option_setters, options_doc},
    error::Result,
    gridfs::{GridFsBucket, GridFsUploadOptions, GridFsUploadStream},
};

impl GridFsBucket {
    /// Creates and returns a [`GridFsUploadStream`] that the application can write the contents of
    /// the file to.
    ///
    /// `await` will return d[`Result<GridFsUploadStream>`].
    #[deeplink]
    #[options_doc(open_upload_stream)]
    pub fn open_upload_stream(&self, filename: impl AsRef<str>) -> OpenUploadStream<'_> {
        OpenUploadStream {
            bucket: self,
            filename: filename.as_ref().to_owned(),
            id: None,
            options: None,
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::gridfs::GridFsBucket {
    /// Creates and returns a [`GridFsUploadStream`] that the application can write the contents of
    /// the file to.
    ///
    /// [`run`](OpenUploadStream::run) will return d[`Result<GridFsUploadStream>`].
    #[deeplink]
    #[options_doc(open_upload_stream, "run")]
    pub fn open_upload_stream(&self, filename: impl AsRef<str>) -> OpenUploadStream<'_> {
        self.async_bucket.open_upload_stream(filename)
    }
}

/// Creates and returns a [`GridFsUploadStream`] that the application can write the contents of
/// a file to.  Construct with [`GridFsBucket::open_upload_stream`].
#[must_use]
pub struct OpenUploadStream<'a> {
    bucket: &'a GridFsBucket,
    filename: String,
    id: Option<Bson>,
    options: Option<GridFsUploadOptions>,
}

#[option_setters(crate::gridfs::options::GridFsUploadOptions)]
#[export_doc(open_upload_stream)]
impl OpenUploadStream<'_> {
    /// Set the value to be used for the corresponding [`FilesCollectionDocument`]'s `id`
    /// field.  If not set, a unique [`ObjectId`] will be generated that can be accessed via the
    /// stream's [`id`](GridFsUploadStream::id) method.
    pub fn id(mut self, value: Bson) -> Self {
        self.id = Some(value);
        self
    }
}

#[action_impl(sync = crate::sync::gridfs::GridFsUploadStream)]
impl<'a> Action for OpenUploadStream<'a> {
    type Future = OpenUploadStreamFuture;

    async fn execute(self) -> Result<GridFsUploadStream> {
        let id = self.id.unwrap_or_else(|| ObjectId::new().into());
        let chunk_size_bytes = self
            .options
            .as_ref()
            .and_then(|opts| opts.chunk_size_bytes)
            .unwrap_or_else(|| self.bucket.chunk_size_bytes());
        let metadata = self.options.and_then(|opts| opts.metadata);
        Ok(GridFsUploadStream::new(
            self.bucket.clone(),
            id,
            self.filename,
            chunk_size_bytes,
            metadata,
            self.bucket.client().register_async_drop(),
        ))
    }
}
