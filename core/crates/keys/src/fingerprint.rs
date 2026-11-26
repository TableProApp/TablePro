use crate::KeysError;
use crate::base32;
use crate::crypto;
use crate::encoding::{AccountId, Frame, Label, Origin};
use crate::keys::Ed25519Public;
use crate::words;

pub const FINGERPRINT_WORDS: usize = 6;
pub const QR_PREFIX: &str = "TPF1:";

// f = HKDF-SHA256(salt = none, IKM = IK pub, info = LP("tablepro/v1/fingerprint") || LP("tp1") || LP(origin) || LP(account)).
pub fn fingerprint(origin: &Origin, account: AccountId, ik: &Ed25519Public) -> Result<[u8; 32], KeysError> {
    let mut info = Frame::new(Label::Fingerprint);
    info.origin(origin).id(account.0);
    crypto::hkdf32(&ik.0, &info.finish()?).map(|okm| *okm)
}

// Words 0 to 5 of f, about 77 bits.
pub fn fingerprint_words(fingerprint: &[u8; 32]) -> Vec<&'static str> {
    words::words(fingerprint, FINGERPRINT_WORDS)
}

// `TPF1:` and the 52 Base32 symbols of f, upper case and ungrouped, its last 4 bits zero.
pub fn qr_text(fingerprint: &[u8; 32]) -> String {
    format!("{QR_PREFIX}{}", base32::encode(fingerprint))
}

pub fn parse_qr(text: &str) -> Result<[u8; 32], KeysError> {
    let symbols = text
        .strip_prefix(QR_PREFIX)
        .ok_or(KeysError::encoding("QR text does not start with TPF1:"))?;
    if symbols.len() != 52 {
        return Err(KeysError::encoding("QR text is not 52 symbols"));
    }
    let bytes = base32::decode(symbols)?;
    <[u8; 32]>::try_from(bytes.as_slice()).map_err(|_| KeysError::encoding("QR text is not 32 bytes"))
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::{parse_qr, qr_text};

    #[test]
    fn qr_text_is_strict() {
        let text = qr_text(&[0xff; 32]);
        assert_eq!(text.len(), 5 + 52);
        assert!(
            text.ends_with('G'),
            "the last symbol carries one bit and four zero bits: {text}"
        );
        assert_eq!(parse_qr(&text).unwrap(), [0xff; 32]);
        assert!(parse_qr(&text.replace("TPF1:", "TPF2:")).is_err());
        assert!(
            parse_qr(&format!("{}H", &text[..text.len() - 1])).is_err(),
            "non-zero final bits"
        );
        assert!(
            parse_qr(&text.to_lowercase().replace("tpf1:", "TPF1:")).is_err(),
            "lower case"
        );
        assert!(parse_qr(&text[..text.len() - 1]).is_err());
    }

    proptest! {
        #[test]
        fn qr_round_trips(bytes in any::<[u8; 32]>()) {
            prop_assert_eq!(parse_qr(&qr_text(&bytes)).unwrap(), bytes);
        }
    }
}
