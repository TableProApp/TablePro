use crate::api::ids::EpochId;
use crate::api::scopes::LineageEpoch;
use crate::api::state::BaseRow;
use crate::api::transport::PulledRecord;

// The device's lineage against the server's, which tells which of its writes a restore lost (0051, Lost writes). Each
// base is judged against the cut that ended its own history, however many epochs the device missed.
#[derive(Debug, Clone)]
pub(super) struct Cut {
    server: Vec<LineageEpoch>,
    // Where in the server's lineage the newest epoch both lineages hold sits.
    shared: Option<usize>,
}

impl Cut {
    pub(super) fn new(device: &[LineageEpoch], server: &[LineageEpoch]) -> Self {
        let shared = server
            .iter()
            .rposition(|epoch| device.iter().any(|held| held.id == epoch.id));
        Self {
            server: server.to_vec(),
            shared,
        }
    }

    fn index(&self, epoch: EpochId) -> Option<usize> {
        self.server.iter().position(|held| held.id == epoch)
    }

    // The place in the server's lineage of the epoch that ended a base's history.
    fn cut_of(&self, base: &BaseRow) -> usize {
        match base.epoch.and_then(|epoch| self.index(epoch)) {
            Some(index) => index + 1,
            None => self.shared.map_or(0, |shared| shared + 1),
        }
    }

    // A base whose epoch the server does not list began after the restore point; one written in an earlier epoch is
    // lost when its revision is above what the next epoch's cut kept.
    pub(super) fn lost(&self, base: &BaseRow) -> bool {
        let Some(epoch) = base.epoch else {
            return false;
        };
        match self.index(epoch) {
            None => true,
            Some(index) => self
                .server
                .get(index + 1)
                .is_some_and(|cut| base.revision.is_none_or(|revision| revision > cut.kept_revision)),
        }
    }

    // A copy written in the cut's epoch or a later one was written after the recovery.
    pub(super) fn written_after(&self, base: &BaseRow, pulled: &PulledRecord) -> bool {
        let cut = self.cut_of(base);
        pulled
            .service
            .as_ref()
            .and_then(|meta| self.index(meta.epoch))
            .is_some_and(|index| index >= cut)
    }
}
