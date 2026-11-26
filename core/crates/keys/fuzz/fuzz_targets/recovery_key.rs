#![no_main]

use libfuzzer_sys::fuzz_target;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::secrecy::ExposeSecret;

// Recovery key text: whatever reads gives a key whose own text reads back to it.
fuzz_target!(|text: &str| {
    if let Ok(key) = RecoveryKey::parse(text) {
        let written = key.to_text().expect("text");
        let again = RecoveryKey::parse(written.expose_secret()).expect("its own text");
        assert_eq!(again.expose(), key.expose());
    }
});
