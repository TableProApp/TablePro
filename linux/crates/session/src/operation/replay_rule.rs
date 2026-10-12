use tablepro_core::ErrorCategory;

use super::{OperationError, OperationKind};
use crate::health::LinkGeneration;

/// Whether a failed operation runs once more on the replacement link.
#[derive(Debug, Clone, Copy)]
pub struct ReplayRule;

impl ReplayRule {
    /// Only a read, only a lost connection, and only once the link has
    /// already moved past the connection it failed on. A loss before any
    /// reconnect is left to the caller's own link watch, so the runner
    /// never waits on a reconnect that may not come.
    pub fn should_replay(
        kind: OperationKind,
        error: &OperationError,
        lease: LinkGeneration,
        current: LinkGeneration,
    ) -> bool {
        kind.is_replayable()
            && matches!(
                error.category(),
                Some(ErrorCategory::ConnectionLost | ErrorCategory::Network)
            )
            && current > lease
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{
        ConfigError, DriverError, LossPhase, NetworkEndpoint, TimeoutPhase, TransportError, WriteKind,
    };

    use super::*;

    fn error_of(category: ErrorCategory) -> OperationError {
        let endpoint = NetworkEndpoint::new("db", 5432).unwrap();
        let driver = match category {
            ErrorCategory::ConnectionLost => DriverError::ConnectionLost {
                during: LossPhase::Statement,
            },
            ErrorCategory::Network => DriverError::Transport(TransportError::Refused { endpoint }),
            ErrorCategory::Timeout => DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true,
            },
            ErrorCategory::Server => DriverError::server("relation does not exist"),
            ErrorCategory::Busy => DriverError::Busy,
            ErrorCategory::Authentication => DriverError::auth(None),
            ErrorCategory::Configuration => DriverError::Config(ConfigError::DatabaseRequired),
            _ => DriverError::Protocol("other".to_owned()),
        };
        OperationError::Driver(driver)
    }

    #[test]
    fn replay_table() {
        let old = LinkGeneration::FIRST;
        let new = old.next();
        let kinds = [
            (OperationKind::Metadata, true),
            (OperationKind::Page, true),
            (OperationKind::Count, true),
            (OperationKind::Save(WriteKind::RowChanges), false),
            (OperationKind::Save(WriteKind::SchemaChanges), false),
            (OperationKind::Probe, false),
            (OperationKind::Close, false),
        ];
        let categories = [
            (ErrorCategory::ConnectionLost, true),
            (ErrorCategory::Network, true),
            (ErrorCategory::Timeout, false),
            (ErrorCategory::Server, false),
            (ErrorCategory::Busy, false),
            (ErrorCategory::Authentication, false),
            (ErrorCategory::Configuration, false),
        ];

        for (kind, replayable) in kinds {
            for (category, lost) in categories {
                let error = error_of(category);
                assert_eq!(
                    ReplayRule::should_replay(kind, &error, old, new),
                    replayable && lost,
                    "{kind:?} after {category:?} on a replaced link"
                );
                assert!(
                    !ReplayRule::should_replay(kind, &error, new, new),
                    "{kind:?} after {category:?} replayed with no newer link"
                );
            }
        }
        for error in [OperationError::Cancelled, OperationError::Closed] {
            assert!(!ReplayRule::should_replay(OperationKind::Page, &error, old, new));
        }
    }
}
