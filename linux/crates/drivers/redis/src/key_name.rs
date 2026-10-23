use std::fmt::Write as _;

use tablepro_core::sql_syntax::redis::split_command;

/// A key's name as text that reads back to the same bytes.
///
/// A key is any bytes. One that is UTF-8 with no control character and
/// does not open with `"` is shown as it is; any other, and the empty
/// name, is written as a quoted argument, as redis-cli shows it:
/// `"\xff\x00raw"`. So a name is quoted exactly when it opens with `"`,
/// and either form can be pasted into the editor as the command's
/// argument.
pub fn key_text(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(text) if !text.is_empty() && !text.starts_with('"') && !text.chars().any(char::is_control) => {
            text.to_owned()
        }
        _ => quoted_argument(bytes),
    }
}

/// The bytes a name from `key_text` stands for. `None` for quoted text
/// that is not one argument.
pub fn key_bytes(text: &str) -> Option<Vec<u8>> {
    if !text.starts_with('"') {
        return Some(text.as_bytes().to_vec());
    }
    let mut arguments = split_command(text).ok()?;
    match arguments.len() {
        1 => arguments.pop(),
        _ => None,
    }
}

/// `bytes` as one double-quoted argument, with C escapes for what
/// redis-cli would read otherwise.
pub(crate) fn quoted_argument(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len() + 2);
    text.push('"');
    let mut rest = bytes;
    while !rest.is_empty() {
        let (valid, invalid) = match std::str::from_utf8(rest) {
            Ok(valid) => (valid, &[][..]),
            Err(error) => {
                let (valid, invalid) = rest.split_at(error.valid_up_to());
                (std::str::from_utf8(valid).unwrap_or_default(), invalid)
            }
        };
        for c in valid.chars() {
            match c {
                '"' => text.push_str("\\\""),
                '\\' => text.push_str("\\\\"),
                '\n' => text.push_str("\\n"),
                '\r' => text.push_str("\\r"),
                '\t' => text.push_str("\\t"),
                c if c.is_control() => {
                    let mut buffer = [0; 4];
                    for byte in c.encode_utf8(&mut buffer).bytes() {
                        let _ = write!(text, "\\x{byte:02x}");
                    }
                }
                c => text.push(c),
            }
        }
        // One byte that does not start valid UTF-8, written as its hex.
        match invalid.split_first() {
            Some((byte, after)) => {
                let _ = write!(text, "\\x{byte:02x}");
                rest = after;
            }
            None => rest = &[],
        }
    }
    text.push('"');
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_names_are_shown_as_they_are() {
        for name in ["user:1", "a key with spaces", "đơn:hàng", "it's", "x\"y"] {
            assert_eq!(key_text(name.as_bytes()), name);
            assert_eq!(key_bytes(name).as_deref(), Some(name.as_bytes()));
        }
    }

    #[test]
    fn other_names_are_quoted_and_read_back() {
        let cases: [&[u8]; 6] = [
            b"\xff\x00raw",
            b"\"starts with a quote",
            b"line\nbreak",
            b"tab\there\\",
            b"\x7f",
            b"",
        ];
        for bytes in cases {
            let text = key_text(bytes);
            assert!(text.starts_with('"'), "{text}");
            assert_eq!(key_bytes(&text).as_deref(), Some(bytes), "{text}");
        }
        assert_eq!(key_text(b"\xff\x00raw"), r#""\xff\x00raw""#);
        assert_eq!(key_text(b""), r#""""#);
    }

    #[test]
    fn quoted_text_that_is_not_one_argument_names_no_key() {
        assert_eq!(key_bytes("\"open"), None);
        assert_eq!(key_bytes("\"a\" b"), None);
    }
}
