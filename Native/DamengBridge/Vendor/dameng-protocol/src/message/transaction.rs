//! Transaction control messages: COMMIT (type 8) and ROLLBACK (type 9).

use bytes::BytesMut;

/// Client->Server COMMIT message (type 8).
///
/// Commits the current transaction.
#[derive(Debug, Clone)]
pub struct CommitMessage;

impl CommitMessage {
    /// Encode to payload bytes (empty payload).
    pub fn encode_payload(&self) -> BytesMut {
        BytesMut::new()
    }
}

/// Client->Server ROLLBACK message (type 9).
///
/// Rolls back the current transaction.
#[derive(Debug, Clone)]
pub struct RollbackMessage;

impl RollbackMessage {
    /// Encode to payload bytes (empty payload).
    pub fn encode_payload(&self) -> BytesMut {
        BytesMut::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_commit_encode_empty() {
        let commit = CommitMessage;
        let payload = commit.encode_payload();
        assert!(payload.is_empty());
    }

    #[test]
    fn test_rollback_encode_empty() {
        let rollback = RollbackMessage;
        let payload = rollback.encode_payload();
        assert!(payload.is_empty());
    }

    #[test]
    fn test_commit_debug() {
        let commit = CommitMessage;
        let debug_str = format!("{:?}", commit);
        assert!(debug_str.contains("CommitMessage"));
    }

    #[test]
    fn test_rollback_debug() {
        let rollback = RollbackMessage;
        let debug_str = format!("{:?}", rollback);
        assert!(debug_str.contains("RollbackMessage"));
    }

    #[test]
    fn test_commit_clone() {
        let commit = CommitMessage;
        let _cloned = commit.clone();
    }

    #[test]
    fn test_rollback_clone() {
        let rollback = RollbackMessage;
        let _cloned = rollback.clone();
    }
}
