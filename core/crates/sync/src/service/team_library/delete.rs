// The verified delete of an owner's Team Library data: the store file, then every library record of the team scopes
// in this state file, each read back to show it went. The store is marked first and the mark goes last, so a delete a
// crash or a failure cut off keeps Team Library off, after a restart too, until a delete finishes.

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
        if let Err(error) = self.store_call(|store| store.mark_deleting_blocking()).await {
            tracing::warn!(
                code = error.code(),
                "the team library delete goes ahead without its mark"
            );
        }
        self.finish_delete().await
    }

    // What the store's mark still owes: the state file's library rows and the store's stamp, then the mark itself.
    pub(super) async fn finish_delete(&self) -> Result<(), SyncError> {
        let finished = async {
            self.store_call(|store| store.delete_blocking()).await?;
            self.drop_library_rows(&[]).await?;
            self.store_call(|store| store.clear_deleting_blocking()).await
        }
        .await;
        finished.map_err(|error| failed(&error))?;
        self.team_library.off.store(false, Ordering::SeqCst);
        self.refresh_counts().await;
        Ok(())
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
