use std::hash::{BuildHasher, RandomState};
use std::sync::LazyLock;

use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;
use unicode_segmentation::UnicodeSegmentation;

use super::MaskingStyle;
use crate::column::ColumnType;
use crate::export::value_text;
use crate::value::Value;

pub const BULLETS: &str = "••••";

// Drawn once per process and never stored, so equal values hash alike within a run but a hash cannot be looked up
// across runs or apps.
static HASH_KEY: LazyLock<[u8; 32]> = LazyLock::new(|| {
    let mut key = [0_u8; 32];
    if getrandom::fill(&mut key).is_err() {
        // The standard library's own per-process keys, from the same system source by another path.
        for (index, chunk) in key.chunks_mut(8).enumerate() {
            chunk.copy_from_slice(&RandomState::new().hash_one(index).to_ne_bytes());
        }
    }
    key
});

// The cell masked by its text form, which `value_text` writes at the column's declared precision. NULL stays NULL;
// bytes hash as they are and otherwise show bullets.
pub fn mask_value(value: &Value, column: &ColumnType, style: MaskingStyle) -> Value {
    match (style, value) {
        (MaskingStyle::Null, _) | (_, Value::Null) => Value::Null,
        (MaskingStyle::Hash, Value::Bytes(bytes)) => Value::Text(stable_hash(bytes)),
        (_, Value::Bytes(_) | Value::Undecodable(_)) => Value::Text(BULLETS.to_owned()),
        (style, value) => match value_text(value, column) {
            Some(text) => mask_text(&text, style).map_or(Value::Null, Value::Text),
            None => Value::Text(BULLETS.to_owned()),
        },
    }
}

// None for the NULL style.
pub fn mask_text(text: &str, style: MaskingStyle) -> Option<String> {
    Some(match style {
        MaskingStyle::Null => return None,
        MaskingStyle::Full => BULLETS.to_owned(),
        MaskingStyle::LastFour => last_four(text),
        MaskingStyle::Email => email(text),
        MaskingStyle::Hash => stable_hash(text.as_bytes()),
    })
}

// HMAC-SHA256 under the process's key, its first 6 bytes as 12 lower-case hex digits.
pub fn stable_hash(bytes: &[u8]) -> String {
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(&*HASH_KEY) else {
        return BULLETS.to_owned();
    };
    mac.update(bytes);
    crate::hex::encode_lower(&mac.finalize().into_bytes()[..6])
}

fn last_four(text: &str) -> String {
    let clusters: Vec<&str> = text.graphemes(true).collect();
    match clusters.len() {
        0..=4 => BULLETS.to_owned(),
        count => format!("{BULLETS}{}", clusters[count - 4..].concat()),
    }
}

// The domain after the last `@`, which must not be the first character and must be followed by something.
fn email(text: &str) -> String {
    let clusters: Vec<&str> = text.graphemes(true).collect();
    match clusters.iter().rposition(|cluster| *cluster == "@") {
        Some(at) if at > 0 && at + 1 < clusters.len() => {
            format!("{}•••@{}", clusters[0], clusters[at + 1..].concat())
        }
        _ => BULLETS.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::{ColumnKind, ReadForm, TextLength};
    use crate::value::{SqlDecimal, UndecodableReason, UndecodedValue};

    fn masked(text: &str, style: MaskingStyle) -> Option<String> {
        mask_text(text, style)
    }

    fn text_column() -> ColumnType {
        ColumnType {
            name: "text".to_owned(),
            kind: ColumnKind::Text {
                length: TextLength::Unbounded,
            },
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        }
    }

    // MASKING-RESEARCH.md section 1, each example as the macOS app masks it.
    #[test]
    fn last_four_keeps_the_last_four_grapheme_clusters_past_four() {
        let cases = [
            ("", "••••"),
            ("abcd", "••••"),
            ("abcde", "••••bcde"),
            ("-12.50", "••••2.50"),
            ("e\u{301}e\u{301}e\u{301}e\u{301}", "••••"),
            ("👨‍👩‍👧abcd", "••••abcd"),
            ("0123456789", "••••6789"),
        ];
        for (text, expected) in cases {
            assert_eq!(
                masked(text, MaskingStyle::LastFour).as_deref(),
                Some(expected),
                "{text:?}"
            );
        }
    }

    #[test]
    fn email_keeps_the_first_character_and_the_domain_after_the_last_at() {
        let cases = [
            ("ann@example.com", "a•••@example.com"),
            ("a@b@c.com", "a•••@c.com"),
            ("ann@x", "a•••@x"),
            ("@b.com", "••••"),
            ("a@", "••••"),
            ("a@\u{301}b", "••••"),
            ("no-at-sign", "••••"),
            ("", "••••"),
            ("é\u{301}x@d.io", "é\u{301}•••@d.io"),
        ];
        for (text, expected) in cases {
            assert_eq!(masked(text, MaskingStyle::Email).as_deref(), Some(expected), "{text:?}");
        }
    }

    #[test]
    fn full_shows_four_bullets_and_null_shows_nothing() {
        assert_eq!(masked("secret", MaskingStyle::Full).as_deref(), Some("••••"));
        assert_eq!(masked("", MaskingStyle::Full).as_deref(), Some("••••"));
        assert_eq!(masked("secret", MaskingStyle::Null), None);
        assert_eq!(BULLETS.chars().collect::<Vec<_>>(), ['\u{2022}'; 4]);
    }

    #[test]
    fn a_stable_hash_is_twelve_hex_digits_equal_for_equal_values_in_one_process() {
        let first = stable_hash(b"ann@example.com");

        assert_eq!(first.len(), 12);
        assert!(
            first
                .chars()
                .all(|digit| digit.is_ascii_hexdigit() && !digit.is_ascii_uppercase())
        );
        assert_eq!(stable_hash(b"ann@example.com"), first);
        assert_ne!(stable_hash(b"bob@example.com"), first);
        assert_eq!(masked("ann@example.com", MaskingStyle::Hash), Some(first));
    }

    #[test]
    fn the_hash_is_hmac_sha256_cut_to_six_bytes() {
        let mut mac = Hmac::<Sha256>::new_from_slice(&*HASH_KEY).expect("a key");
        mac.update(b"x");
        let full = crate::hex::encode_lower(&mac.finalize().into_bytes());

        assert_eq!(stable_hash(b"x"), full[..12]);
    }

    #[test]
    fn values_mask_by_their_text_and_null_stays_null() {
        let column = text_column();
        let decimal = Value::Decimal("-12.50".parse::<SqlDecimal>().expect("a decimal"));

        assert_eq!(mask_value(&Value::Null, &column, MaskingStyle::Full), Value::Null);
        assert_eq!(
            mask_value(&Value::Text("x".to_owned()), &column, MaskingStyle::Null),
            Value::Null
        );
        assert_eq!(
            mask_value(&decimal, &column, MaskingStyle::LastFour),
            Value::Text("••••2.50".to_owned())
        );
        assert_eq!(
            mask_value(&Value::Int(1_234_567), &column, MaskingStyle::LastFour),
            Value::Text("••••4567".to_owned())
        );
    }

    #[test]
    fn bytes_hash_raw_and_otherwise_show_bullets() {
        let column = text_column();
        let bytes = Value::Bytes(vec![0xca, 0xfe]);
        let undecodable = Value::Undecodable(Box::new(UndecodedValue {
            type_name: "geometry".to_owned(),
            reason: UndecodableReason::UnsupportedType,
        }));

        assert_eq!(
            mask_value(&bytes, &column, MaskingStyle::Hash),
            Value::Text(stable_hash(&[0xca, 0xfe]))
        );
        for style in [MaskingStyle::Full, MaskingStyle::LastFour, MaskingStyle::Email] {
            assert_eq!(mask_value(&bytes, &column, style), Value::Text(BULLETS.to_owned()));
            assert_eq!(
                mask_value(&undecodable, &column, style),
                Value::Text(BULLETS.to_owned())
            );
        }
        assert_eq!(mask_value(&bytes, &column, MaskingStyle::Null), Value::Null);
    }
}
