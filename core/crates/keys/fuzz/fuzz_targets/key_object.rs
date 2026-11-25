#![no_main]

use libfuzzer_sys::fuzz_target;
use tablepro_keys::body::{KeyObject, parse_sealed, sealed_json};
use tablepro_keys::record_id::KeyKind;

// Key object bodies with their record ids, and the clear fields of envelopes and history entries:
// whatever parses writes back fields that parse to the same object.
fuzz_target!(|data: &[u8]| {
    let Some((selector, rest)) = data.split_first() else {
        return;
    };
    let index = usize::from(*selector) % (KeyKind::ALL.len() + 1);
    let Some(kind) = KeyKind::ALL.get(index) else {
        if let Ok(sealed) = parse_sealed(rest) {
            assert_eq!(parse_sealed(sealed_json(&sealed).as_bytes()).expect("its own fields"), sealed);
        }
        return;
    };
    let split = rest.iter().position(|byte| *byte == 0).unwrap_or(rest.len());
    let Ok(id) = std::str::from_utf8(&rest[..split]) else {
        return;
    };
    let fields = rest.get(split + 1..).unwrap_or_default();
    if let Ok(object) = KeyObject::parse(kind.name(), id, fields) {
        assert_eq!(object.id.to_wire(), id);
        let again = KeyObject::parse(kind.name(), id, object.fields_json().as_bytes()).expect("its own fields");
        assert_eq!(again, object);
    }
});
