use crate::Client;

use super::{export_doc, options_doc};

impl Client {
    /// Shut down this `Client`, terminating background thread workers and closing connections.
    /// Using this method is not required under most circumstances (resources will be cleaned up in
    /// the background when dropped) but can be needed when creating `Client`s in a loop or precise
    /// control of lifespan timing is required. This will wait for any live handles to
    /// server-side resources (see below) to be dropped and any associated server-side
    /// operations to finish.
    ///
    /// IMPORTANT: Any live resource handles that are not dropped will cause this method to wait
    /// indefinitely.  It's strongly recommended to structure your usage to avoid this, e.g. by
    /// only using those types in shorter-lived scopes than the `Client`.  If this is not possible,
    /// see [`immediate`](Shutdown::immediate).  For example:
    ///
    /// ```rust
    /// # use mongodb::{Client, error::Result, gridfs::GridFsBucket};
    /// async fn upload_data(bucket: &GridFsBucket) -> Result<()> {
    ///   let stream = bucket.open_upload_stream("test").await?;
    ///    // .. write to the stream ..
    /// # Ok(())
    /// }
    ///
    /// # async fn run() -> Result<()> {
    /// let client = Client::with_uri_str("mongodb://example.com").await?;
    /// let bucket = client.database("test").gridfs_bucket(None);
    /// upload_data(&bucket).await;
    /// client.shutdown().await;
    /// // Background cleanup work from `upload_data` is guaranteed to have run.
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// If the handle is used in the same scope as `shutdown`, explicit `drop` may be needed:
    ///
    /// ```rust
    /// # use mongodb::{Client, error::Result};
    /// # async fn run() -> Result<()> {
    /// let client = Client::with_uri_str("mongodb://example.com").await?;
    /// let bucket = client.database("test").gridfs_bucket(None);
    /// let stream = bucket.open_upload_stream("test").await?;
    /// // .. write to the stream ..
    /// drop(stream);
    /// client.shutdown().await;
    /// // Background cleanup work for `stream` is guaranteed to have run.
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// Calling any methods on clones of this `Client` or derived handles after this will return
    /// errors.
    ///
    /// Handles to server-side resources are `Cursor`, `SessionCursor`, `Session`, or
    /// `GridFsUploadStream`.
    ///
    /// `await` will return `()`.
    #[options_doc(shutdown)]
    pub fn shutdown(self) -> Shutdown {
        Shutdown {
            client: self,
            immediate: false,
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Client {
    /// Shut down this `Client`, terminating background thread workers and closing connections.
    /// Using this method is not required under most circumstances (resources will be cleaned up in
    /// the background when dropped) but can be needed when creating `Client`s in a loop or precise
    /// control of lifespan timing is required. This will wait for any live handles to
    /// server-side resources (see below) to be dropped and any associated server-side
    /// operations to finish.
    ///
    /// IMPORTANT: Any live resource handles that are not dropped will cause this method to wait
    /// indefinitely.  It's strongly recommended to structure your usage to avoid this, e.g. by
    /// only using those types in shorter-lived scopes than the `Client`.  If this is not possible,
    /// see [`immediate`](Shutdown::immediate).  For example:
    ///
    /// ```rust
    /// # use mongodb::{sync::{Client, gridfs::GridFsBucket}, error::Result};
    /// fn upload_data(bucket: &GridFsBucket) -> Result<()> {
    ///   let stream = bucket.open_upload_stream("test").run()?;
    ///    // .. write to the stream ..
    /// # Ok(())
    /// }
    ///
    /// # fn run() -> Result<()> {
    /// let client = Client::with_uri_str("mongodb://example.com")?;
    /// let bucket = client.database("test").gridfs_bucket(None);
    /// upload_data(&bucket)?;
    /// client.shutdown();
    /// // Background cleanup work from `upload_data` is guaranteed to have run.
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// If the handle is used in the same scope as `shutdown`, explicit `drop` may be needed:
    ///
    /// ```rust
    /// # use mongodb::{sync::Client, error::Result};
    /// # fn run() -> Result<()> {
    /// let client = Client::with_uri_str("mongodb://example.com")?;
    /// let bucket = client.database("test").gridfs_bucket(None);
    /// let stream = bucket.open_upload_stream("test").run()?;
    /// // .. write to the stream ..
    /// drop(stream);
    /// client.shutdown();
    /// // Background cleanup work for `stream` is guaranteed to have run.
    /// # Ok(())
    /// # }
    /// ```
    ///
    /// Calling any methods on  clones of this `Client` or derived handles after this will return
    /// errors.
    ///
    /// Handles to server-side resources are `Cursor`, `SessionCursor`, `Session`, or
    /// `GridFsUploadStream`.
    ///
    /// [`run`](Shutdown::run) will return `()`.
    #[options_doc(shutdown, "run")]
    pub fn shutdown(self) -> Shutdown {
        self.async_client.shutdown()
    }
}

/// Shut down this `Client`, terminating background thread workers and closing connections.  Create
/// by calling [`Client::shutdown`].
#[must_use]
pub struct Shutdown {
    pub(crate) client: Client,
    pub(crate) immediate: bool,
}

#[export_doc(shutdown)]
impl Shutdown {
    /// If `true`, execution will not wait for pending resources to be cleaned up,
    /// which may cause both client-side errors and server-side resource leaks.  Defaults to
    /// `false`.
    pub fn immediate(mut self, value: bool) -> Self {
        self.immediate = value;
        self
    }
}

// IntoFuture impl in src/client/action/shutdown.rs
