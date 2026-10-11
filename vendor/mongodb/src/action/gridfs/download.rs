use crate::bson::{doc, Bson};

use crate::{
    action::{action_impl, deeplink, export_doc, option_setters, options_doc},
    error::{ErrorKind, GridFsErrorKind, GridFsFileIdentifier, Result},
    gridfs::{
        FilesCollectionDocument,
        GridFsBucket,
        GridFsDownloadByNameOptions,
        GridFsDownloadStream,
    },
};

impl GridFsBucket {
    /// Opens and returns a [`GridFsDownloadStream`] from which the application can read
    /// the contents of the stored file specified by `id`.
    ///
    /// `await` will return d[`Result<GridFsDownloadStream>`].
    #[deeplink]
    pub fn open_download_stream(&self, id: Bson) -> OpenDownloadStream<'_> {
        OpenDownloadStream { bucket: self, id }
    }

    /// Opens and returns a [`GridFsDownloadStream`] from which the application can read
    /// the contents of the stored file specified by `filename`.
    ///
    /// If there are multiple files in the bucket with the given filename, the `revision` in the
    /// options provided is used to determine which one to download. See the documentation for
    /// [`GridFsDownloadByNameOptions`] for details on how to specify a revision. If no revision is
    /// provided, the file with `filename` most recently uploaded will be downloaded.
    ///
    /// `await` will return d[`Result<GridFsDownloadStream>`].
    #[deeplink]
    #[options_doc(download_by_name)]
    pub fn open_download_stream_by_name(
        &self,
        filename: impl Into<String>,
    ) -> OpenDownloadStreamByName<'_> {
        OpenDownloadStreamByName {
            bucket: self,
            filename: filename.into(),
            options: None,
        }
    }

    // Utility functions for finding files within the bucket.

    async fn find_file_by_id(&self, id: &Bson) -> Result<FilesCollectionDocument> {
        match self.find_one(doc! { "_id":  { "$eq": id } }).await? {
            Some(file) => Ok(file),
            None => Err(ErrorKind::GridFs(GridFsErrorKind::FileNotFound {
                identifier: GridFsFileIdentifier::Id(id.clone()),
            })
            .into()),
        }
    }

    async fn find_file_by_name(
        &self,
        filename: &str,
        options: Option<GridFsDownloadByNameOptions>,
    ) -> Result<FilesCollectionDocument> {
        let revision = options.and_then(|opts| opts.revision).unwrap_or(-1);
        let (sort, skip) = if revision >= 0 {
            (1, revision)
        } else {
            (-1, -revision - 1)
        };
        // unwrap safety: `skip` is always >= 0
        let skip: u64 = skip.try_into().unwrap();

        match self
            .files()
            .find_one(doc! { "filename": filename })
            .sort(doc! { "uploadDate": sort })
            .skip(skip)
            .await?
        {
            Some(fcd) => Ok(fcd),
            None => {
                if self
                    .files()
                    .find_one(doc! { "filename": filename })
                    .await?
                    .is_some()
                {
                    Err(ErrorKind::GridFs(GridFsErrorKind::RevisionNotFound { revision }).into())
                } else {
                    Err(ErrorKind::GridFs(GridFsErrorKind::FileNotFound {
                        identifier: GridFsFileIdentifier::Filename(filename.into()),
                    })
                    .into())
                }
            }
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::gridfs::GridFsBucket {
    /// Opens and returns a [`GridFsDownloadStream`] from which the application can read
    /// the contents of the stored file specified by `id`.
    ///
    /// [`run`](OpenDownloadStream::run) will return d[`Result<GridFsDownloadStream>`].
    #[deeplink]
    pub fn open_download_stream(&self, id: Bson) -> OpenDownloadStream<'_> {
        self.async_bucket.open_download_stream(id)
    }

    /// Opens and returns a [`GridFsDownloadStream`] from which the application can read
    /// the contents of the stored file specified by `filename`.
    ///
    /// If there are multiple files in the bucket with the given filename, the `revision` in the
    /// options provided is used to determine which one to download. See the documentation for
    /// [`GridFsDownloadByNameOptions`] for details on how to specify a revision. If no revision is
    /// provided, the file with `filename` most recently uploaded will be downloaded.
    ///
    /// [`run`](OpenDownloadStreamByName::run) will return d[`Result<GridFsDownloadStream>`].
    #[deeplink]
    #[options_doc(download_by_name, "run")]
    pub fn open_download_stream_by_name(
        &self,
        filename: impl Into<String>,
    ) -> OpenDownloadStreamByName<'_> {
        self.async_bucket.open_download_stream_by_name(filename)
    }
}

/// Opens and returns a [`GridFsDownloadStream`] from which the application can read
/// the contents of the stored file specified by an id.  Construct with
/// [`GridFsBucket::open_download_stream`].
#[must_use]
pub struct OpenDownloadStream<'a> {
    bucket: &'a GridFsBucket,
    id: Bson,
}

#[action_impl(sync = crate::sync::gridfs::GridFsDownloadStream)]
impl<'a> Action for OpenDownloadStream<'a> {
    type Future = OpenDownloadStreamFuture;

    async fn execute(self) -> Result<GridFsDownloadStream> {
        let file = self.bucket.find_file_by_id(&self.id).await?;
        GridFsDownloadStream::new(file, self.bucket.chunks()).await
    }
}

/// Opens and returns a [`GridFsDownloadStream`] from which the application can read
/// the contents of the stored file specified by a filename.  Construct with
/// [`GridFsBucket::open_download_stream_by_name`].
#[must_use]
pub struct OpenDownloadStreamByName<'a> {
    bucket: &'a GridFsBucket,
    filename: String,
    options: Option<GridFsDownloadByNameOptions>,
}

#[option_setters(crate::gridfs::GridFsDownloadByNameOptions)]
#[export_doc(download_by_name)]
impl OpenDownloadStreamByName<'_> {}

#[action_impl(sync = crate::sync::gridfs::GridFsDownloadStream)]
impl<'a> Action for OpenDownloadStreamByName<'a> {
    type Future = OpenDownloadStreamByNameFuture;

    async fn execute(self) -> Result<GridFsDownloadStream> {
        let file = self
            .bucket
            .find_file_by_name(&self.filename, self.options)
            .await?;
        GridFsDownloadStream::new(file, self.bucket.chunks()).await
    }
}
