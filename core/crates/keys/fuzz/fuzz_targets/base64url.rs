#![no_main]

use libfuzzer_sys::fuzz_target;
use tablepro_keys::b64;

// Whatever decodes is canonical: it encodes back to the same text.
fuzz_target!(|text: &str| {
    if let Ok(bytes) = b64::decode(text) {
        assert_eq!(b64::encode(&bytes), text);
    }
    let _ = b64::decode_exact::<32>(text);
});
