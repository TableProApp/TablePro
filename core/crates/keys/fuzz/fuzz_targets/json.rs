#![no_main]

use libfuzzer_sys::fuzz_target;
use tablepro_keys::KeysError;
use tablepro_keys::json;

// The strict JSON reader against serde_json: it takes nothing serde_json refuses but a number past
// f64's range, which it keeps as text; it refuses what serde_json takes only for a duplicate name or
// the nesting limit; and what it reads writes back to an equal value.
fuzz_target!(|data: &[u8]| {
    let parsed = serde_json::from_slice::<serde_json::Value>(data);
    let theirs = parsed.is_ok();
    match json::parse(data) {
        Ok(value) => {
            if let Err(error) = parsed {
                assert!(error.to_string().starts_with("number out of range"), "serde_json refuses what this reader took: {error}");
            }
            let written = value.to_json();
            let again = json::parse(written.as_bytes()).expect("its own output");
            assert!(again.same_as(&value));
            assert_eq!(again.to_json(), written);
        }
        Err(KeysError::Encoding { what }) => {
            if theirs {
                assert!(matches!(what, "a duplicate member name" | "JSON nested too deep"), "{what}");
            }
        }
        Err(other) => panic!("{other:?}"),
    }
});
