#![no_main]

use libfuzzer_sys::fuzz_target;
use tablepro_keys::{base32, fingerprint};

// Crockford Base32 and the fingerprint QR text: whatever parses writes back the same text.
fuzz_target!(|text: &str| {
    if let Ok(bytes) = base32::decode(text) {
        assert_eq!(base32::encode(&bytes), text);
    }
    if let Ok(fingerprint) = fingerprint::parse_qr(text) {
        assert_eq!(fingerprint::qr_text(&fingerprint), text);
    }
});
