#![no_main]

use libfuzzer_sys::fuzz_target;
use tablepro_keys::encoding::{HistoryId, uuid_from_wire};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_keys::record_id::{KeyKind, KeyRecordId};

// Record ids: key objects', envelopes' and history entries'. Whatever parses writes back the same id.
fuzz_target!(|text: &str| {
    for kind in KeyKind::ALL {
        if let Ok(id) = KeyRecordId::parse(kind, text) {
            assert_eq!(id.to_wire(), text);
        }
    }
    if let Ok(id) = EnvelopeId::parse(text) {
        assert_eq!(id.to_wire(), text);
    }
    if let Ok(id) = HistoryId::from_wire(text) {
        assert_eq!(id.to_wire(), text);
    }
    if let Ok(uuid) = uuid_from_wire(text) {
        assert_eq!(uuid.hyphenated().to_string().to_uppercase(), text);
    }
});
