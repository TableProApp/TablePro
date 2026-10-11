use std::{
    pin::Pin,
    sync::atomic::Ordering,
    task::{ready, Context, Poll},
};

use futures_util::{
    future::{BoxFuture, FutureExt},
    io::AsyncWrite,
    stream::TryStreamExt,
};

use super::{Chunk, FilesCollectionDocument, GridFsBucket};
use crate::{
    action::Action,
    bson::{doc, oid::ObjectId, spec::BinarySubtype, Bson, DateTime, Document, RawBinaryRef},
    bson_util::get_int,
    checked::Checked,
    client::AsyncDropToken,
    error::{Error, ErrorKind, GridFsErrorKind, Result},
    index::IndexModel,
    options::{ReadPreference, SelectionCriteria},
    Collection,
};

impl GridFsBucket {
    async fn create_indexes(&self) -> Result<()> {
        if !self.inner.created_indexes.load(Ordering::SeqCst) {
            if self
                .files()
                .clone_with_type::<Document>()
                .find_one(doc! {})
                .selection_criteria(SelectionCriteria::ReadPreference(ReadPreference::Primary))
                .projection(doc! { "_id": 1 })
                .await?
                .is_none()
            {
                self.create_index(self.files(), doc! { "filename": 1, "uploadDate": 1 })
                    .await?;
                self.create_index(self.chunks(), doc! { "files_id": 1, "n": 1 })
                    .await?;
            }
            self.inner.created_indexes.store(true, Ordering::SeqCst);
        }

        Ok(())
    }

    async fn create_index<T: Send + Sync>(
        &self,
        coll: &Collection<T>,
        keys: Document,
    ) -> Result<()> {
        // listIndexes returns an error if the collection has not yet been created.
        // Ignore NamespaceExists errors if the collection has already been created.
        if let Err(error) = self
            .inner
            .db
            .create_collection(coll.name())
            .optional(self.write_concern().cloned(), |b, wc| b.write_concern(wc))
            .await
        {
            if error.sdam_code() != Some(48) {
                return Err(error);
            }
        }

        // From the spec: Drivers MUST check whether the indexes already exist before attempting to
        // create them.
        let mut indexes = coll.list_indexes().await?;
        'outer: while let Some(index_model) = indexes.try_next().await? {
            if index_model.keys.len() != keys.len() {
                continue;
            }
            // Indexes should be considered equivalent regardless of numeric value type.
            // e.g. { "filename": 1, "uploadDate": 1 } is equivalent to
            // { "filename": 1.0, "uploadDate": 1.0 }
            let number_matches = |key: &str, value: &Bson| {
                if let Some(model_value) = index_model.keys.get(key) {
                    match get_int(value) {
                        Some(num) => get_int(model_value) == Some(num),
                        None => model_value == value,
                    }
                } else {
                    false
                }
            };
            for (key, value) in keys.iter() {
                if !number_matches(key, value) {
                    continue 'outer;
                }
            }
            return Ok(());
        }

        let index_model = IndexModel::builder().keys(keys).build();
        coll.create_index(index_model).await?;

        Ok(())
    }
}

/// A stream to which bytes can be written to be uploaded to a GridFS bucket.
///
/// # Uploading to the Stream
///  The `GridFsUploadStream` type implements [`futures_io::AsyncWrite`]. It is recommended that
/// users call the utility methods in [`AsyncWriteExt`](futures_util::io::AsyncWriteExt) to interact
/// with the stream.
///
/// Bytes can be written to the stream using the write methods in `AsyncWriteExt`. When
/// [`close`](futures_util::io::AsyncWriteExt::close) is invoked on the stream, any remaining bytes
/// in the buffer are written to the chunks collection and a corresponding
/// [`FilesCollectionDocument`] is written to the files collection. It is an error to write to,
/// abort, or close the stream after `close` has been called.
///
/// ```rust
/// # use mongodb::{error::Result, gridfs::{GridFsBucket, GridFsUploadStream}};
/// # async fn upload_example(bucket: GridFsBucket) -> Result<()> {
/// use futures_util::io::AsyncWriteExt;
///
/// let bytes = vec![0u8; 100];
/// let mut upload_stream = bucket.open_upload_stream("example_file").await?;
/// upload_stream.write_all(&bytes[..]).await?;
/// upload_stream.close().await?;
/// # Ok(())
/// # }
/// ```
///
/// If the data is a local file (or other `AsyncRead` byte source), its contents can be efficiently
/// written to the stream with [`futures_util::io::copy`].
///
/// # Aborting the Stream
/// A stream can be aborted by calling the `abort` method. This will remove any chunks associated
/// with the stream from the chunks collection. It is an error to write to, abort, or close the
/// stream after `abort` has been called.
///
/// ```rust
/// # use mongodb::{error::Result, gridfs::{GridFsBucket, GridFsUploadStream}};
/// # async fn abort_example(bucket: GridFsBucket) -> Result<()> {
/// use futures_util::io::AsyncWriteExt;
///
/// let bytes = vec![0u8; 100];
/// let mut upload_stream = bucket.open_upload_stream("example_file").await?;
/// upload_stream.write_all(&bytes[..]).await?;
/// upload_stream.abort().await?;
/// # Ok(())
/// # }
/// ```
///
/// In the event of an error during any operation on the `GridFsUploadStream`, any chunks associated
/// with the stream will be removed from the chunks collection. Any subsequent attempts to write to,
/// abort, or close the stream will return an error.
///
/// If a `GridFsUploadStream` is dropped prior to `abort` or `close` being called, its [`Drop`]
/// implementation will spawn a task to remove any chunks associated with the stream from the chunks
/// collection. Users should prefer calling `abort` explicitly to relying on the `Drop`
/// implementation in order to `await` the task and inspect the result of the delete operation.
///
/// # Flushing the Stream
/// Because all chunks besides the final chunk of a file must be exactly `chunk_size_bytes`, calling
/// [`flush`](futures_util::io::AsyncWriteExt::flush) is not guaranteed to flush all bytes to the
/// chunks collection. Any remaining buffered bytes will be written to the chunks collection upon a
/// call to `close`.
///
/// # Using [`tokio::io::AsyncWrite`]
/// Users who prefer to use tokio's `AsyncWrite` trait can use the [`tokio_util::compat`] module.
///
/// ```rust
/// # use mongodb::gridfs::{GridFsBucket, GridFsUploadStream};
/// # use mongodb::error::Result;
/// # async fn compat_example(bucket: GridFsBucket) -> Result<()> {
/// use tokio_util::compat::FuturesAsyncWriteCompatExt;
///
/// let futures_upload_stream = bucket.open_upload_stream("example_file").await?;
/// let tokio_upload_stream = futures_upload_stream.compat_write();
/// # Ok(())
/// # }
/// ```
pub struct GridFsUploadStream {
    bucket: GridFsBucket,
    state: State,
    current_n: u32,
    id: Bson,
    chunk_size_bytes: u32,
    // Additional metadata for the file. These values are stored as Options so that they can be
    // taken and inserted into a FilesCollectionDocument when the stream is closed.
    filename: Option<String>,
    metadata: Option<Option<Document>>,
    drop_token: AsyncDropToken,
}

type WriteBytesFuture = BoxFuture<'static, Result<(u32, Vec<u8>)>>;
type CloseFuture = BoxFuture<'static, Result<()>>;

enum State {
    // The buffer is stored as an option so that it can be moved into futures without requiring
    // ownership of the state. It can always be unwrapped safely.
    Idle(Option<Vec<u8>>),
    Writing(WriteBytesFuture),
    Closing(CloseFuture),
    Closed,
}

impl State {
    fn set_writing(&mut self, new_future: WriteBytesFuture) -> &mut WriteBytesFuture {
        *self = Self::Writing(new_future);
        match self {
            Self::Writing(future) => future,
            _ => unreachable!(),
        }
    }

    fn set_closing(&mut self, new_future: CloseFuture) -> &mut CloseFuture {
        *self = Self::Closing(new_future);
        match self {
            Self::Closing(future) => future,
            _ => unreachable!(),
        }
    }
}

impl GridFsUploadStream {
    pub(crate) fn new(
        bucket: GridFsBucket,
        id: Bson,
        filename: String,
        chunk_size_bytes: u32,
        metadata: Option<Document>,
        drop_token: AsyncDropToken,
    ) -> Self {
        Self {
            bucket,
            state: State::Idle(Some(Vec::new())),
            current_n: 0,
            id,
            filename: Some(filename),
            chunk_size_bytes,
            metadata: Some(metadata),
            drop_token,
        }
    }

    /// Gets the stream's unique [`Bson`] identifier. This value will be the `id` field for the
    /// [`FilesCollectionDocument`] uploaded to the files collection when the stream is closed.
    pub fn id(&self) -> &Bson {
        &self.id
    }

    /// Aborts the stream, discarding any chunks that have already been written to the chunks
    /// collection. Once this method has been called, it is an error to attempt to write to, abort,
    /// or close the stream.
    pub async fn abort(&mut self) -> Result<()> {
        match self.state {
            State::Closed => Err(ErrorKind::GridFs(GridFsErrorKind::UploadStreamClosed).into()),
            _ => {
                self.state = State::Closed;
                clean_up_chunks(self.id.clone(), self.bucket.chunks().clone(), None).await
            }
        }
    }
}

impl Drop for GridFsUploadStream {
    fn drop(&mut self) {
        if !matches!(self.state, State::Closed) {
            let chunks = self.bucket.chunks().clone();
            let id = self.id.clone();
            self.drop_token.spawn(async move {
                let _result = chunks.delete_many(doc! { "files_id": id }).await;
            })
        }
    }
}

impl AsyncWrite for GridFsUploadStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::result::Result<usize, futures_io::Error>> {
        let stream = self.get_mut();

        let future = match &mut stream.state {
            State::Idle(buffer) => {
                let buffer_ref = buffer.as_mut().unwrap();

                buffer_ref.extend_from_slice(buf);
                if buffer_ref.len() < stream.chunk_size_bytes as usize {
                    return Poll::Ready(Ok(buf.len()));
                }

                let new_future = write_bytes(
                    stream.bucket.clone(),
                    buffer.take().unwrap(),
                    stream.current_n,
                    stream.chunk_size_bytes,
                    stream.id.clone(),
                )
                .boxed();
                stream.state.set_writing(new_future)
            }
            State::Writing(future) => future,
            State::Closing(_) | State::Closed => return Poll::Ready(Err(get_closed_error())),
        };

        match ready!(future.poll_unpin(cx)) {
            Ok((chunks_written, buffer)) => {
                stream.current_n += chunks_written;
                stream.state = State::Idle(Some(buffer));
                Poll::Ready(Ok(buf.len()))
            }
            Err(error) => {
                stream.state = State::Closed;
                Poll::Ready(Err(error.into_futures_io_error()))
            }
        }
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<tokio::io::Result<()>> {
        // The buffer only contains leftover bytes that couldn't fill an entire chunk, so there's
        // nothing to flush.
        match self.state {
            State::Closed => Poll::Ready(Err(get_closed_error())),
            _ => Poll::Ready(Ok(())),
        }
    }

    fn poll_close(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<tokio::io::Result<()>> {
        let stream = self.get_mut();

        let future = match &mut stream.state {
            State::Idle(buffer) => {
                let buffer = buffer.take().unwrap();

                let file = FilesCollectionDocument {
                    id: stream.id.clone(),
                    length: stream.current_n as u64 * stream.chunk_size_bytes as u64
                        + buffer.len() as u64,
                    chunk_size_bytes: stream.chunk_size_bytes,
                    upload_date: DateTime::now(),
                    filename: stream.filename.take(),
                    metadata: stream.metadata.take().unwrap(),
                };

                let new_future = close(stream.bucket.clone(), buffer, file).boxed();
                stream.state.set_closing(new_future)
            }
            State::Writing(_) => {
                let error: Error = ErrorKind::GridFs(GridFsErrorKind::WriteInProgress).into();
                let new_future = clean_up_chunks(
                    stream.id.clone(),
                    stream.bucket.chunks().clone(),
                    Some(error),
                )
                .boxed();
                stream.state.set_closing(new_future)
            }
            State::Closing(future) => future,
            State::Closed => return Poll::Ready(Err(get_closed_error())),
        };

        let result = ready!(future.poll_unpin(cx));
        stream.state = State::Closed;
        match result {
            Ok(()) => Poll::Ready(Ok(())),
            Err(error) => Poll::Ready(Err(error.into_futures_io_error())),
        }
    }
}

// Writes the data in the buffer to the database and returns the number of chunks written and any
// leftover bytes that didn't fill an entire chunk.
async fn write_bytes(
    bucket: GridFsBucket,
    mut buffer: Vec<u8>,
    starting_n: u32,
    chunk_size_bytes: u32,
    files_id: Bson,
) -> Result<(u32, Vec<u8>)> {
    let chunk_size_bytes: usize = Checked::new(chunk_size_bytes).try_into()?;
    bucket.create_indexes().await?;

    let mut n = Checked::new(0);
    let mut chunks = vec![];

    while (Checked::new(buffer.len()) - (n * chunk_size_bytes)).get()? >= chunk_size_bytes {
        let start = n * chunk_size_bytes;
        let end = (n + 1) * chunk_size_bytes;
        let chunk = Chunk {
            id: ObjectId::new(),
            files_id: files_id.clone(),
            n: starting_n + n.try_into::<u32>()?,
            data: RawBinaryRef {
                subtype: BinarySubtype::Generic,
                bytes: &buffer[start.get()?..end.get()?],
            },
        };
        n += 1;
        chunks.push(chunk);
    }

    match bucket.chunks().insert_many(chunks).await {
        Ok(_) => {
            buffer.drain(..(n * chunk_size_bytes).get()?);
            Ok((n.try_into()?, buffer))
        }
        Err(error) => match clean_up_chunks(files_id, bucket.chunks().clone(), Some(error)).await {
            // clean_up_chunks will always return an error if one is passed in, so this case is
            // unreachable
            Ok(()) => unreachable!(),
            Err(error) => Err(error),
        },
    }
}

async fn close(bucket: GridFsBucket, buffer: Vec<u8>, file: FilesCollectionDocument) -> Result<()> {
    let insert_result: Result<()> = async {
        if !buffer.is_empty() {
            debug_assert!(buffer.len() < file.chunk_size_bytes as usize);
            let final_chunk = Chunk {
                id: ObjectId::new(),
                n: file.n() - 1,
                files_id: file.id.clone(),
                data: RawBinaryRef {
                    subtype: BinarySubtype::Generic,
                    bytes: &buffer[..],
                },
            };
            bucket.chunks().insert_one(final_chunk).await?;
        }
        bucket.files().insert_one(&file).await?;
        Ok(())
    }
    .await;

    match insert_result {
        Ok(()) => Ok(()),
        Err(error) => clean_up_chunks(file.id.clone(), bucket.chunks().clone(), Some(error)).await,
    }
}

async fn clean_up_chunks(
    id: Bson,
    chunks: Collection<Chunk<'static>>,
    original_error: Option<Error>,
) -> Result<()> {
    match chunks.delete_many(doc! { "files_id": { "$eq": id } }).await {
        Ok(_) => match original_error {
            Some(error) => Err(error),
            None => Ok(()),
        },
        Err(delete_error) => Err(ErrorKind::GridFs(GridFsErrorKind::AbortError {
            original_error,
            delete_error,
        })
        .into()),
    }
}

fn get_closed_error() -> futures_io::Error {
    let error: Error = ErrorKind::GridFs(GridFsErrorKind::UploadStreamClosed).into();
    error.into_futures_io_error()
}
