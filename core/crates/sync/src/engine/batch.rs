use tablepro_records::limits;

use crate::api::ids::ChangeTag;
use crate::api::scopes::ServerLimits;
use crate::api::transport::{Change, ChangeOp};

// A change's share of a push body: its patch as the server measures fields, its names and tag, and the JSON around them.
pub fn change_bytes(change: &Change) -> usize {
    const FRAME: usize = 96;
    let patch = match &change.op {
        ChangeOp::Write { patch, .. } => limits::encoded_len(patch),
        ChangeOp::Delete => 0,
    };
    let tag = change.base.as_ref().map_or(0, |tag| match tag {
        ChangeTag::Service(text) => text.len(),
        ChangeTag::CloudKit(bytes) => bytes.len(),
    });
    FRAME + change.kind.as_str().len() + change.record_id.len() + tag + patch
}

// Pushes of at most the advertised count and body size, in the diff's order (0051, Limits). A change over the body
// size on its own goes alone, and the server answers it.
pub fn split<T>(items: Vec<T>, limits: &ServerLimits, size: impl Fn(&T) -> usize) -> Vec<Vec<T>> {
    let max_changes = usize::try_from(limits.changes_per_push).unwrap_or(usize::MAX).max(1);
    let max_bytes = usize::try_from(limits.body_bytes).unwrap_or(usize::MAX);
    let mut batches = Vec::new();
    let mut batch: Vec<T> = Vec::new();
    let mut bytes = 0;
    for item in items {
        let item_bytes = size(&item);
        if !batch.is_empty() && (batch.len() == max_changes || bytes + item_bytes > max_bytes) {
            batches.push(std::mem::take(&mut batch));
            bytes = 0;
        }
        bytes += item_bytes;
        batch.push(item);
    }
    if !batch.is_empty() {
        batches.push(batch);
    }
    batches
}
