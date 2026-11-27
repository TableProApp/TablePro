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
    // file, sealed with `key`, so a crash before the host takes it loses nothing and a record anyone else wrote there
    // is never reported. The host gives the same key at every launch.
    pub fn report_library_writes(&self, key: SecretString) -> Result<(), CoreError> {
        self.connection_store()?.report_writes(key);
        Ok(())
    }

    // The writes recorded since the last call, oldest first, each once; the record is empty after. Empty until
    // `report_library_writes`.
    pub async fn take_library_writes(&self) -> Result<Vec<LibraryWriteReport>, CoreError> {
        let store = self.connection_store()?;
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            let taken = tasks
                .spawn_blocking_task(move || store.take_written_blocking())
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
            Ok(taken
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
}
