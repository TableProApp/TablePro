use std::{
    pin::Pin,
    task::{ready, Context, Poll},
};

use futures_util::{
    future::{BoxFuture, FutureExt},
    io::AsyncRead,
    stream::StreamExt,
};

use super::{Chunk, FilesCollectionDocument};
use crate::{
    bson::doc,
    error::{Error, ErrorKind, GridFsErrorKind, Result},
    raw_batch_cursor::RawBatchCursor,
    Collection,
};

/// A stream from which a file stored in a GridFS bucket can be downloaded.
///
/// # Downloading from the Stream
/// The `GridFsDownloadStream` type implements [`futures_io::AsyncRead`]. It is recommended that
/// users call the utility methods in [`AsyncReadExt`](futures_util::io::AsyncReadExt) to interact
/// with the stream.
///
/// ```rust
/// # use mongodb::{bson::Bson, error::Result, gridfs::{GridFsBucket, GridFsDownloadStream}};
/// # async fn download_example(bucket: GridFsBucket, id: Bson) -> Result<()> {
/// use futures_util::io::AsyncReadExt;
///
/// let mut buf = Vec::new();
/// let mut download_stream = bucket.open_download_stream(id).await?;
/// download_stream.read_to_end(&mut buf).await?;
/// # Ok(())
/// # }
/// ```
///
/// If the destination is a local file (or other `AsyncWrite` byte sink), the contents of the stream
/// can be efficiently written to it with [`futures_util::io::copy`].
///
/// # Using [`tokio::io::AsyncRead`]
/// Users who prefer to use tokio's `AsyncRead` trait can use the [`tokio_util::compat`] module.
///
/// ```rust
/// # use mongodb::{bson::Bson, error::Result, gridfs::{GridFsBucket, GridFsUploadStream}};
/// # async fn compat_example(bucket: GridFsBucket, id: Bson) -> Result<()> {
/// use tokio_util::compat::FuturesAsyncReadCompatExt;
///
/// let futures_upload_stream = bucket.open_download_stream(id).await?;
/// let tokio_upload_stream = futures_upload_stream.compat();
/// # Ok(())
/// # }
/// ```
pub struct GridFsDownloadStream {
    state: State,
    file: FilesCollectionDocument,
}

type GetBytesFuture = BoxFuture<'static, Result<Box<Idle>>>;

enum State {
    // Idle is stored as an option so that its fields can be moved into a GetBytesFuture
    // without requiring ownership of the state. It can always be unwrapped safely.
    Idle(Option<Box<Idle>>),
    Busy(GetBytesFuture),
    Done,
}

struct Idle {
    buffer: Vec<u8>,
    cursor: RawBatchCursor,
    current_n: u32,
}

impl State {
    fn set_busy(&mut self, new_future: GetBytesFuture) -> &mut GetBytesFuture {
        *self = State::Busy(new_future);
        match self {
            Self::Busy(ref mut future) => future,
            _ => unreachable!(),
        }
    }
}

impl GridFsDownloadStream {
    pub(crate) async fn new(
        file: FilesCollectionDocument,
        chunks: &Collection<Chunk<'static>>,
    ) -> Result<Self> {
        let initial_state = if file.length == 0 {
            State::Done
        } else {
            let cursor = chunks
                .find(doc! { "files_id": { "$eq": &file.id } })
                .sort(doc! { "n": 1 })
                .batch()
                .await?;
            State::Idle(Some(Box::new(Idle {
                buffer: Vec::new(),
                cursor,
                current_n: 0,
            })))
        };
        Ok(Self {
            state: initial_state,
            file,
        })
    }
}

impl AsyncRead for GridFsDownloadStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut [u8],
    ) -> Poll<std::result::Result<usize, futures_util::io::Error>> {
        let stream = self.get_mut();

        let result = match &mut stream.state {
            State::Idle(idle) => {
                let idle = idle.take().unwrap();

                if !idle.buffer.is_empty() {
                    Ok(idle)
                } else {
                    let new_future = stream.state.set_busy(
                        get_bytes(
                            idle,
                            stream.file.chunk_size_bytes,
                            stream.file.length,
                            buf.len(),
                        )
                        .boxed(),
                    );

                    ready!(new_future.poll_unpin(cx))
                }
            }
            State::Busy(future) => ready!(future.poll_unpin(cx)),
            State::Done => return Poll::Ready(Ok(0)),
        };

        match result {
            Ok(mut idle) => {
                let bytes_to_write = std::cmp::min(idle.buffer.len(), buf.len());
                buf[..bytes_to_write]
                    .copy_from_slice(idle.buffer.drain(0..bytes_to_write).as_slice());

                if !idle.buffer.is_empty() || idle.cursor.has_next() {
                    stream.state = State::Idle(Some(idle));
                } else {
                    stream.state = State::Done;
                    if idle.current_n != stream.file.n() {
                        return Poll::Ready(Err(Error::from(ErrorKind::GridFs(
                            GridFsErrorKind::MissingChunk { n: idle.current_n },
                        ))
                        .into_futures_io_error()));
                    }
                }

                Poll::Ready(Ok(bytes_to_write))
            }
            Err(error) => {
                stream.state = State::Done;
                Poll::Ready(Err(error.into_futures_io_error()))
            }
        }
    }
}

async fn get_bytes(
    mut idle: Box<Idle>,
    chunk_size_bytes: u32,
    file_len: u64,
    buf_size: usize,
) -> Result<Box<Idle>> {
    while idle.buffer.len() < buf_size {
        let batch = match idle.cursor.next().await.transpose()? {
            Some(batch) => batch,
            None => return Ok(idle),
        };

        for doc in batch.doc_slices()? {
            let doc = doc?;
            let doc = match doc.as_document() {
                Some(doc) => doc,
                None => {
                    return Err(Error::invalid_response(format!(
                        "invalid cursor batch value, expected document, got {:?}",
                        doc.element_type(),
                    )));
                }
            };

            let chunk: Chunk<'_> = crate::bson_compat::deserialize_from_slice(doc.as_bytes())?;
            let chunk_bytes = chunk.data.bytes;

            if chunk.n != idle.current_n {
                return Err(
                    ErrorKind::GridFs(GridFsErrorKind::MissingChunk { n: idle.current_n }).into(),
                );
            }

            let expected_len = FilesCollectionDocument::expected_chunk_length_from_vals(
                file_len,
                chunk_size_bytes,
                idle.current_n,
            );
            if chunk_bytes.len() != (expected_len as usize) {
                return Err(ErrorKind::GridFs(GridFsErrorKind::WrongSizeChunk {
                    actual_size: chunk_bytes.len(),
                    expected_size: expected_len,
                    n: idle.current_n,
                })
                .into());
            }

            idle.buffer.extend_from_slice(chunk_bytes);
            idle.current_n += 1;
        }
    }

    Ok(idle)
}
