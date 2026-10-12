use std::time::Duration;

use tablepro_core::{LivenessPolicy, WriteKind};

use super::{DeadlinePolicy, OperationKind};

/// The deadlines a desktop session runs with.
#[derive(Debug, Clone, Copy)]
pub struct DefaultDeadlines {
    pub liveness: LivenessPolicy,
}

impl DefaultDeadlines {
    pub const METADATA: Duration = Duration::from_secs(15);
    pub const PAGE: Duration = Duration::from_secs(60);
    pub const ROW_CHANGES: Duration = Duration::from_secs(120);

    pub fn new(liveness: LivenessPolicy) -> Self {
        Self { liveness }
    }
}

impl DeadlinePolicy for DefaultDeadlines {
    fn deadline(&self, kind: OperationKind) -> Option<Duration> {
        match kind {
            OperationKind::Metadata => Some(Self::METADATA),
            OperationKind::Page | OperationKind::Count => Some(Self::PAGE),
            OperationKind::Save(WriteKind::RowChanges) => Some(Self::ROW_CHANGES),
            OperationKind::Save(WriteKind::SchemaChanges) => None,
            OperationKind::Probe => Some(self.liveness.probe_timeout),
            OperationKind::Close => Some(self.liveness.close_timeout),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_schema_change_has_no_client_deadline() {
        let deadlines = DefaultDeadlines::new(LivenessPolicy::DESKTOP);
        let seconds = |kind| deadlines.deadline(kind).map(|deadline| deadline.as_secs());

        assert_eq!(seconds(OperationKind::Metadata), Some(15));
        assert_eq!(seconds(OperationKind::Page), Some(60));
        assert_eq!(seconds(OperationKind::Count), Some(60));
        assert_eq!(seconds(OperationKind::Save(WriteKind::RowChanges)), Some(120));
        assert_eq!(seconds(OperationKind::Save(WriteKind::SchemaChanges)), None);
        assert_eq!(seconds(OperationKind::Probe), Some(5));
        assert_eq!(seconds(OperationKind::Close), Some(10));
    }
}
