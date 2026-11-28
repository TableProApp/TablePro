// The library writes the core commits itself, a sync pull's among them, for a host that tags `connections.json` and
// re-tags only a digest the core reports (the Mac). A host's own write through `ConnectionLibrary::replace_library`
// or `rebuild_library` returns its digest instead and is not reported again.

use secrecy::SecretString;

use crate::core_handle::Core;
use crate::error::CoreError;
use crate::history::millis;
use crate::runtime::on_runtime;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryWriteReport {
    // SHA-256 in hex of the exact bytes the core wrote, as `LibraryWritten::digest`.
    pub digest: String,
    // SHA-256 in hex of the file the write replaced, None for no file. A host takes a write on only from a digest it
    // already vouches for, so one made over a file someone else wrote never reaches its tag.
    pub over: Option<String>,
    // Milliseconds from the Unix epoch.
    pub at_ms: i64,
}

#[uniffi::export]
impl Core {
    // Before the library or sync is first used. From here on each write the core commits itself is recorded beside the
    // file, sealed with `key`, until the host acknowledges it, so a crash before the host has stamped it loses nothing
    // and a record anyone else wrote there is never reported. The host gives the same key at every launch.
    pub fn report_library_writes(&self, key: SecretString) -> Result<(), CoreError> {
        self.connection_store()?.report_writes(key);
        Ok(())
    }

    // The writes recorded and not acknowledged yet, oldest first. Each comes again until `ack_library_writes` names it
    // or a later one, so a host stamps them, then acknowledges them. Empty until `report_library_writes`.
    pub async fn peek_library_writes(&self) -> Result<Vec<LibraryWriteReport>, CoreError> {
        let store = self.connection_store()?;
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            let peeked = tasks
                .spawn_blocking_task(move || store.peek_written_blocking())
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
            Ok(peeked
                .into_iter()
                .map(|write| LibraryWriteReport {
                    digest: write.digest,
                    over: write.over,
                    at_ms: millis(write.at),
                })
                .collect())
        })
        .await
    }

    // Once the host has stamped them: clears every record through the one whose digest is `through_digest`, oldest
    // first. A digest no record holds clears nothing, as when another process acknowledged it already.
    pub async fn ack_library_writes(&self, through_digest: String) -> Result<(), CoreError> {
        let store = self.connection_store()?;
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            tasks
                .spawn_blocking_task(move || store.ack_written_blocking(&through_digest))
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
            Ok(())
        })
        .await
    }
}
