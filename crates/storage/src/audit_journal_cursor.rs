use std::collections::HashMap;
use std::fs::File;
use std::os::unix::fs::MetadataExt;

use tablepro_policy::AuditEvent;
use uuid::Uuid;

use super::{GENESIS_HASH, JournalTail, VerifiedJournal};
use crate::error::StorageError;

pub(super) struct JournalState {
    pub(super) tail: JournalTail,
    pub(super) pending: HashMap<Uuid, AuditEvent>,
    pub(super) unresolved: HashMap<Uuid, Uuid>,
}

impl JournalState {
    pub(super) fn genesis() -> Self {
        Self {
            tail: JournalTail {
                seq: 0,
                hash: GENESIS_HASH.to_string(),
            },
            pending: HashMap::new(),
            unresolved: HashMap::new(),
        }
    }

    pub(super) fn from_verified(verified: VerifiedJournal) -> Self {
        Self {
            tail: verified.tail,
            pending: verified
                .pending_intents
                .into_iter()
                .map(|event| (event.operation_id, event))
                .collect(),
            unresolved: verified.unresolved_operation_connections,
        }
    }
}

pub(super) struct JournalCursor {
    pub(super) state: JournalState,
    pub(super) offset: u64,
    device: u64,
    inode: u64,
}

impl JournalCursor {
    pub(super) fn at_end_of(file: &File, state: JournalState) -> Result<Self, StorageError> {
        let metadata = file.metadata()?;
        Ok(Self {
            state,
            offset: metadata.len(),
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }

    pub(super) fn still_describes(&self, metadata: &std::fs::Metadata) -> bool {
        self.device == metadata.dev() && self.inode == metadata.ino() && self.offset <= metadata.len()
    }
}
