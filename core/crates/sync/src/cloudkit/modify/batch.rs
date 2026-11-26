// How a push is cut into modify calls (0054, A push). CloudKit's `limitExceeded` documentation gives 400 items per
// operation as its guideline and the Swift engine sent 250, which never met it. CloudKit publishes no request size, so
// a call also stays under 1 MiB of fields, and one it still finds too large goes again in halves.

use super::{Item, Op};
use crate::api::cloudkit::CloudKitValue;

const ITEMS_PER_CALL: usize = 250;
const BYTES_PER_CALL: usize = 1 << 20;

fn value_bytes(value: &CloudKitValue) -> usize {
    match value {
        CloudKitValue::Text(text) => text.len(),
        CloudKitValue::Int64(_) | CloudKitValue::Double(_) | CloudKitValue::Timestamp(_) => 8,
        CloudKitValue::Bytes(bytes) => bytes.len(),
        CloudKitValue::TextList(items) => items.iter().map(String::len).sum(),
    }
}

// A record's share of a call: its name, its system fields and its fields, with room for their framing.
fn bytes(item: &Item) -> usize {
    const FRAME: usize = 64;
    let record = match &item.op {
        Op::Save { record, .. } => {
            record.record_type.len()
                + record.system_fields.as_ref().map_or(0, Vec::len)
                + record
                    .fields
                    .iter()
                    .map(|field| FRAME + field.name.len() + field.value.as_ref().map_or(0, value_bytes))
                    .sum::<usize>()
        }
        Op::Delete { .. } => 0,
    };
    FRAME + item.name().len() + record
}

// In the diff's order. A record over the byte budget on its own goes alone, and CloudKit answers it.
pub(super) fn calls(items: Vec<Item>) -> Vec<Vec<Item>> {
    let mut calls = Vec::new();
    let mut call: Vec<Item> = Vec::new();
    let mut held = 0;
    for item in items {
        let size = bytes(&item);
        if !call.is_empty() && (call.len() == ITEMS_PER_CALL || held + size > BYTES_PER_CALL) {
            calls.push(std::mem::take(&mut call));
            held = 0;
        }
        held += size;
        call.push(item);
    }
    if !call.is_empty() {
        calls.push(call);
    }
    calls
}

pub(super) fn halves(mut call: Vec<Item>) -> (Vec<Item>, Vec<Item>) {
    let second = call.split_off(call.len() / 2);
    (call, second)
}
