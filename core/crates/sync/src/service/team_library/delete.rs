// The verified delete of an owner's Team Library data: the store file, then every library record of the team scopes
// in this state file, each read back to show it went. This state database marks the owner first and clears its own
// mark last, so a delete a crash or a failure cut off keeps Team Library off here, after a restart too, until it
// finishes; another database's mark stays for its own rows (K8t leftover: one marker per state database).

use std::sync::atomic::Ordering;

use super::super::{ServiceSync, begin};
use super::{library_kind, team_of};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::state::{Row, RowKey, RowRange, Table};
use crate::api::team_library::TeamLibraryError;

// The tables that hold a record's data or what waits on it. Scope rows keep their cursor and key version, which hold
// nothing of the library: a store that starts over refills from a snapshot.
const LIBRARY_TABLES: [Table; 8] = [
    Table::Bases,
    Table::PendingBases,
    Table::Standing,
    Table::Held,
    Table::Deferred,
    Table::Refused,
    Table::Approvals,
    Table::Conflicts,
];

const STORE: &str = "team_library.json";

fn failed(error: &SyncError) -> SyncError {
    TeamLibraryError::DeleteFailed {
        detail: error.to_string(),
    }
    .into()
}

fn library_row(row: &Row, only: &[ScopeName]) -> bool {
    let key = match row {
        Row::Base(row) | Row::PendingBase(row) => &row.key,
        Row::Standing(row) => &row.key,
        Row::Held(row) => &row.key,
        Row::Deferred(row) => &row.key,
        Row::Refused(row) => &row.key,
        Row::Approval(row) => &row.key,
        Row::Conflict(row) => &row.key,
        _ => return false,
    };
    team_of(key.scope).is_some()
        && (only.is_empty() || only.contains(&key.scope))
        && key.kind.known().and_then(library_kind).is_some()
}

impl ServiceSync {
    // A mark that cannot be written keeps nothing back: the delete goes ahead, and fails only if data stays behind.
    pub(super) async fn delete_all(&self) -> Result<(), SyncError> {
        self.team_library.off.store(true, Ordering::SeqCst);
        let database = self.database();
        if let Err(error) = self
            .store_call(move |store| store.mark_deleting_blocking(&database))
            .await
        {
            tracing::warn!(
                code = error.code(),
                "the team library delete goes ahead without its mark"
            );
        }
        // The file goes whether or not the mark landed, and stays owed here until it went.
        self.team_library.file_owed.store(true, Ordering::SeqCst);
        self.finish_delete().await
    }

    // What this database's mark still owes: the store file unless a delete already saw it go, the state file's library
    // rows and the store's stamp, then the mark itself.
    pub(super) async fn finish_delete(&self) -> Result<(), SyncError> {
        let database = self.database();
        let finished = async {
            self.delete_store_file().await?;
            self.drop_library_rows(&[]).await?;
            self.store_call(move |store| store.clear_deleting_blocking(&database))
                .await
        }
        .await;
        finished.map_err(|error| failed(&error))?;
        self.team_library.off.store(false, Ordering::SeqCst);
        self.refresh_counts().await;
        Ok(())
    }

    // The owner's file, once per delete: a mark that already saw it go owes only its database's rows, so a database
    // finishing late never takes a file another sign-in has refilled since. A delete whose mark did not land owes the
    // file all the same.
    async fn delete_store_file(&self) -> Result<(), SyncError> {
        let owed = self.team_library.file_owed.load(Ordering::SeqCst);
        self.store_call(move |store| store.delete_owed_blocking(owed)).await?;
        self.team_library.file_owed.store(false, Ordering::SeqCst);
        Ok(())
    }

    // The name this state database's mark carries.
    pub(super) fn database(&self) -> String {
        crate::state::state_name(self.state.identity()).0
    }

    // Every library record of `only`, or of every team scope, and with all of them the store's stamp, so the store's
    // next copy refills from the team. Read back before it answers.
    pub(super) async fn drop_library_rows(&self, only: &[ScopeName]) -> Result<(), SyncError> {
        self.check_stop()?;
        let mut txn = begin(&self.state).await?;
        for table in LIBRARY_TABLES {
            for row in txn.scan(&RowRange::Table(table)).await? {
                if library_row(&row, only) {
                    txn.delete(&row.key()).await?;
                }
            }
        }
        if only.is_empty() {
            txn.delete(&RowKey::Store(STORE.to_owned())).await?;
        }
        txn.commit().await?;
        self.state.purge().await?;
        let mut check = begin(&self.state).await?;
        for table in LIBRARY_TABLES {
            if check
                .scan(&RowRange::Table(table))
                .await?
                .iter()
                .any(|row| library_row(row, only))
            {
                return Err(TeamLibraryError::DeleteFailed {
                    detail: format!("the {} table still holds library records", table.name()),
                }
                .into());
            }
        }
        if only.is_empty() && check.get(&RowKey::Store(STORE.to_owned())).await?.is_some() {
            return Err(TeamLibraryError::DeleteFailed {
                detail: "the stores table still holds the library's stamp".to_owned(),
            }
            .into());
        }
        Ok(())
    }
}
