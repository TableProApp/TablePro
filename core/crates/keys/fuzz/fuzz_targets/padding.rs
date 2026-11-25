#![no_main]

use libfuzzer_sys::fuzz_target;
use tablepro_keys::padding;

// ISO/IEC 7816-4 padding: what unpads pads back to a length on the scale, and padding round trips.
fuzz_target!(|data: &[u8]| {
    if let Ok(plaintext) = padding::unpad(data) {
        assert!(plaintext.len() < data.len());
        assert!(padding::on_scale(data.len()));
        let padded = padding::pad(plaintext).expect("pad");
        assert_eq!(padding::unpad(&padded).expect("unpad"), plaintext);
    }
    if data.len() < 70_000 {
        let padded = padding::pad(data).expect("pad");
        assert_eq!(padding::unpad(&padded).expect("unpad"), data);
    }
});
