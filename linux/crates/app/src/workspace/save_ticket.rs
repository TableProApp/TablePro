use tokio_util::sync::CancellationToken;

use super::SaveId;

/// What a started save runs under: its id, to settle it by, and the
/// token Stop Saving fires.
#[derive(Debug, Clone)]
pub struct SaveTicket {
    pub id: SaveId,
    pub cancel: CancellationToken,
}
