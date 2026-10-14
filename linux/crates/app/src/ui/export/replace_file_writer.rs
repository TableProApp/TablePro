use std::cell::RefCell;
use std::collections::HashSet;

use futures::channel::oneshot;
use gtk4::prelude::*;
use gtk4::{gio, glib};
use thiserror::Error;

/// How a stopped export left its file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AbortOutcome {
    /// The export made the file, and it is gone again.
    Removed,
    /// The file that was there is as it was.
    Untouched,
    /// The file holds part of the export.
    Incomplete,
}

/// A close that failed, and what it left of the file.
#[derive(Debug)]
pub(crate) struct FinishError {
    pub error: glib::Error,
    pub file: AbortOutcome,
}

#[derive(Debug, Error)]
pub(crate) enum OpenError {
    /// Another export in this process is writing the file. Both would
    /// race for it, and the one that stopped would remove what the
    /// other finished.
    #[error("another export is writing to this file")]
    InUse,
    #[error(transparent)]
    File(#[from] glib::Error),
}

/// How the writer came to hold the file.
#[derive(Debug, Clone)]
enum Strategy {
    /// `made` names the file the writer made, so a stopped export
    /// removes that one and not a file put at its path since. `None`
    /// where the backend has no inode, and the file then stays, since
    /// it cannot be told from one put there since.
    Created { made: Option<FileIdentity> },
    /// `before` is the file's tag when it was opened, to tell afterwards
    /// whether a stopped export changed it.
    Replaced { before: Option<glib::GString> },
}

/// Writes an export to its file without losing the file that was there
/// when the export stops partway.
///
/// GIO writes on its own worker threads, so the GTK thread only waits.
/// A local replace stream renames its temporary file over the
/// destination when it closes, unless the close sees a cancelled
/// cancellable, and dispose closes without one. GLib takes the
/// temporary-file path only for an existing regular file with a single
/// link whose directory takes the temporary file; otherwise it truncates
/// the destination when it opens it. So an abort leaves the old file
/// untouched only on that path, and comparing tags reports the rest.
pub(crate) struct ReplaceFileWriter {
    file: gio::File,
    /// Taken by `finish` or `abort`. One still here at drop belongs to an
    /// export that never finished.
    stream: Option<gio::FileOutputStream>,
    strategy: Strategy,
    /// Let go once the file is cleaned up, which for a dropped writer is
    /// after its abort.
    claim: Option<DestinationClaim>,
}

impl ReplaceFileWriter {
    pub(crate) async fn open(file: &gio::File) -> Result<Self, OpenError> {
        let claim = DestinationClaim::take(file).ok_or(OpenError::InUse)?;
        // An export holds table rows or query history, so a new file is
        // the user's alone. A replaced file keeps the mode it had.
        let (stream, strategy) = match file
            .create_future(gio::FileCreateFlags::PRIVATE, glib::Priority::DEFAULT)
            .await
        {
            Ok(stream) => {
                let made = FileIdentity::of_stream(&stream).await;
                (stream, Strategy::Created { made })
            }
            Err(error) if error.matches(gio::IOErrorEnum::Exists) => {
                let before = etag(file).await;
                // Writing through a symbolic link rather than replacing
                // it, as GtkSourceView's file saver does.
                let stream = file
                    .replace_future(None, false, gio::FileCreateFlags::NONE, glib::Priority::DEFAULT)
                    .await?;
                (stream, Strategy::Replaced { before })
            }
            Err(error) => return Err(error.into()),
        };
        Ok(Self {
            file: file.clone(),
            stream: Some(stream),
            strategy,
            claim: Some(claim),
        })
    }

    pub(crate) async fn write(&self, chunk: Vec<u8>) -> Result<(), glib::Error> {
        let Some(stream) = self.stream.as_ref() else {
            return Err(closed());
        };
        match stream.write_all_future(chunk, glib::Priority::DEFAULT).await {
            Ok((_, _, None)) => Ok(()),
            Ok((_, _, Some(error))) | Err((_, error)) => Err(error),
        }
    }

    /// Close the file, which for a replaced one puts the new content in
    /// its place. A close can still fail, on a network or full disk, and
    /// the file is then cleaned up as a stopped export's is.
    pub(crate) async fn finish(mut self) -> Result<(), FinishError> {
        let Some(stream) = self.stream.take() else {
            return Err(FinishError {
                error: closed(),
                file: AbortOutcome::Incomplete,
            });
        };
        match stream.close_future(glib::Priority::DEFAULT).await {
            Ok(()) => Ok(()),
            Err(error) => Err(FinishError {
                error,
                file: left_behind(&self.file, &self.strategy).await,
            }),
        }
    }

    /// Stop writing and leave the file as close to how it was as GIO
    /// allows.
    pub(crate) async fn abort(mut self) -> AbortOutcome {
        match self.stream.take() {
            Some(stream) => abort(&self.file, &stream, &self.strategy).await,
            None => AbortOutcome::Incomplete,
        }
    }
}

impl Drop for ReplaceFileWriter {
    fn drop(&mut self) {
        if let Some(stream) = self.stream.take() {
            let (file, strategy, claim) = (self.file.clone(), self.strategy.clone(), self.claim.take());
            glib::spawn_future_local(async move {
                let outcome = abort(&file, &stream, &strategy).await;
                drop(claim);
                tracing::debug!(?outcome, "an unfinished export was abandoned");
            });
        }
    }
}

async fn abort(file: &gio::File, stream: &gio::FileOutputStream, strategy: &Strategy) -> AbortOutcome {
    close_cancelled(stream).await;
    left_behind(file, strategy).await
}

/// Remove a file the export made, if it is still the one at the path,
/// and tell whether one it replaced is as it was. A replace stream
/// whose close failed before its rename has dropped its temporary file,
/// so the old file can still be whole.
async fn left_behind(file: &gio::File, strategy: &Strategy) -> AbortOutcome {
    match strategy {
        Strategy::Created { made: None } => AbortOutcome::Incomplete,
        Strategy::Created { made: Some(made) } => {
            if FileIdentity::at_path(file).await != Some(*made) {
                tracing::debug!("a stopped export's file was replaced at its path, which is left as it is");
                return AbortOutcome::Removed;
            }
            match file.delete_future(glib::Priority::DEFAULT).await {
                Ok(()) => AbortOutcome::Removed,
                Err(error) => {
                    tracing::warn!(%error, "a stopped export's file could not be removed");
                    AbortOutcome::Incomplete
                }
            }
        }
        Strategy::Replaced { before } => match (before, etag(file).await) {
            (Some(before), Some(after)) if *before == after => AbortOutcome::Untouched,
            _ => AbortOutcome::Incomplete,
        },
    }
}

/// Close `stream` with a cancellable that is already cancelled, which
/// a replace stream takes as the order to drop its temporary file.
async fn close_cancelled(stream: &gio::FileOutputStream) {
    let cancellable = gio::Cancellable::new();
    cancellable.cancel();
    let (sender, receiver) = oneshot::channel();
    stream.close_async(glib::Priority::DEFAULT, Some(&cancellable), move |closed| {
        let _ = sender.send(closed);
    });
    // The close reports the cancel; what it did to the file is read
    // back by the caller.
    let _ = receiver.await;
}

async fn etag(file: &gio::File) -> Option<glib::GString> {
    file.query_info_future(
        gio::FILE_ATTRIBUTE_ETAG_VALUE,
        gio::FileQueryInfoFlags::NONE,
        glib::Priority::DEFAULT,
    )
    .await
    .ok()
    .and_then(|info| info.etag())
}

const IDENTITY_ATTRIBUTES: &str = "unix::device,unix::inode";

/// A file as the file system knows it, whatever path leads to it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    device: u32,
    inode: u64,
}

impl FileIdentity {
    async fn of_stream(stream: &gio::FileOutputStream) -> Option<Self> {
        let info = stream
            .query_info_future(IDENTITY_ATTRIBUTES, glib::Priority::DEFAULT)
            .await
            .inspect_err(|error| tracing::debug!(%error, "an export's new file has no identity"))
            .ok()?;
        Self::from_info(&info)
    }

    async fn at_path(file: &gio::File) -> Option<Self> {
        let info = file
            .query_info_future(
                IDENTITY_ATTRIBUTES,
                gio::FileQueryInfoFlags::NOFOLLOW_SYMLINKS,
                glib::Priority::DEFAULT,
            )
            .await
            .ok()?;
        Self::from_info(&info)
    }

    fn from_info(info: &gio::FileInfo) -> Option<Self> {
        let known =
            info.has_attribute(gio::FILE_ATTRIBUTE_UNIX_DEVICE) && info.has_attribute(gio::FILE_ATTRIBUTE_UNIX_INODE);
        known.then(|| Self {
            device: info.attribute_uint32(gio::FILE_ATTRIBUTE_UNIX_DEVICE),
            inode: info.attribute_uint64(gio::FILE_ATTRIBUTE_UNIX_INODE),
        })
    }
}

thread_local! {
    /// The destinations a writer in this process holds. Every window
    /// writes to the same file system, so one list serves them all.
    static CLAIMED: RefCell<HashSet<String>> = RefCell::default();
}

#[derive(Debug)]
struct DestinationClaim(String);

impl DestinationClaim {
    fn take(file: &gio::File) -> Option<Self> {
        let uri = file.uri().to_string();
        CLAIMED
            .with_borrow_mut(|claimed| claimed.insert(uri.clone()))
            .then(|| Self(uri))
    }
}

impl Drop for DestinationClaim {
    fn drop(&mut self) {
        CLAIMED.with_borrow_mut(|claimed| claimed.remove(&self.0));
    }
}

fn closed() -> glib::Error {
    glib::Error::new(gio::IOErrorEnum::Closed, "the export's file is already closed")
}

#[cfg(test)]
mod tests;
