#![no_main]

use libfuzzer_sys::fuzz_target;
use tablepro_keys::envelope::{envelope_plaintext, history_plaintext, parse_envelope_plaintext, parse_history_plaintext};
use tablepro_keys::secrecy::ExposeSecret;
use tablepro_keys::trust::TrustPlaintext;

// The JSON plaintexts: the trust wrap's, an envelope's and a history entry's.
fuzz_target!(|data: &[u8]| {
    let Some((selector, plaintext)) = data.split_first() else {
        return;
    };
    match selector % 3 {
        0 => {
            if let Ok(trust) = TrustPlaintext::parse(plaintext) {
                assert_eq!(TrustPlaintext::parse(trust.encode().as_bytes()).expect("its own encoding"), trust);
            }
        }
        1 => {
            if let Ok(opened) = parse_envelope_plaintext(plaintext) {
                let written = envelope_plaintext(opened.secret.expose_secret(), &opened.dest).expect("write");
                let again = parse_envelope_plaintext(written.as_bytes()).expect("its own plaintext");
                assert_eq!(again.secret.expose_secret(), opened.secret.expose_secret());
                assert!(again.dest.same_as(&opened.dest));
            }
        }
        _ => {
            if let Ok(entry) = parse_history_plaintext(plaintext) {
                let written = history_plaintext(&entry).expect("write");
                assert!(parse_history_plaintext(written.as_bytes()).expect("its own plaintext").same_as(&entry));
            }
        }
    }
});
