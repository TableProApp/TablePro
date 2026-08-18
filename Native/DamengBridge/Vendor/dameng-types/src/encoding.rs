//! Encoding conversion between server encoding (UTF-8 / GB18030) and Rust UTF-8.
//!
//! DM server may use different character encodings. The encoding is determined
//! from the LOGIN_RESPONSE (type=163):
//! - 1: UTF-8
//! - 2: GB18030
//!
//! All string data sent to the server must be encoded in the server's encoding.
//! All string data received from the server must be decoded from the server's
//! encoding to Rust's native UTF-8.

use encoding_rs::{Encoding, GB18030, UTF_8};

/// Server-side encoding determined from LOGIN_RESPONSE.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerEncoding {
    /// UTF-8 encoding (encoding value = 1).
    Utf8,
    /// GB18030 encoding (encoding value = 2).
    Gb18030,
}

impl ServerEncoding {
    /// Create from DM protocol encoding value.
    ///
    /// Per DM Go driver (dm_build_425), the LOGIN_RESPONSE encoding field maps:
    /// - 0: GB18030
    /// - 1: UTF-8
    /// - 2: EUC-KR
    /// Defaults to GB18030 (matching DM Go driver behavior).
    pub fn from_protocol_value(value: u8) -> Self {
        match value {
            1 => ServerEncoding::Utf8,
            _ => ServerEncoding::Gb18030, // 0, 2, and default → GB18030
        }
    }
    /// Get the encoding_rs Encoding instance for this server encoding.
    pub fn encoding(&self) -> &'static Encoding {
        match self {
            ServerEncoding::Utf8 => UTF_8,
            ServerEncoding::Gb18030 => GB18030,
        }
    }
}

/// Convert a UTF-8 string to the server's encoding.
///
/// Used when sending SQL text or string parameters to the server.
/// If the server uses UTF-8, this is a no-op that returns the input as-is.
///
/// # Arguments
/// * `server_encoding` - The server's character encoding
/// * `s` - The UTF-8 string to encode
///
/// # Returns
/// Bytes in the server's encoding.
pub fn encode_to_server(server_encoding: ServerEncoding, s: &str) -> Vec<u8> {
    let enc = server_encoding.encoding();
    let (result, _, had_errors) = enc.encode(s);
    if had_errors {
        // Fallback: should not happen for valid UTF-8 input
        // If encoding fails, return the raw UTF-8 bytes as a last resort
        return s.as_bytes().to_vec();
    }
    result.to_vec()
}

/// Convert bytes from the server's encoding to a UTF-8 String.
///
/// Used when receiving string data from the server (column values,
/// error messages, etc.).
/// If the server uses UTF-8, this is a no-op.
///
/// # Arguments
/// * `server_encoding` - The server's character encoding
/// * `data` - Raw bytes from the server
///
/// # Returns
/// A UTF-8 String. Invalid bytes are replaced with the Unicode
/// replacement character (U+FFFD), matching encoding_rs behavior.
pub fn decode_from_server(server_encoding: ServerEncoding, data: &[u8]) -> String {
    let enc = server_encoding.encoding();
    let (result, _, _) = enc.decode(data);
    result.into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_from_protocol_value_utf8() {
        assert_eq!(ServerEncoding::from_protocol_value(1), ServerEncoding::Utf8);
    }

    #[test]
    fn test_from_protocol_value_gb18030() {
        assert_eq!(
            ServerEncoding::from_protocol_value(0),
            ServerEncoding::Gb18030
        );
        assert_eq!(
            ServerEncoding::from_protocol_value(2),
            ServerEncoding::Gb18030
        );
    }

    #[test]
    fn test_from_protocol_value_default() {
        assert_eq!(
            ServerEncoding::from_protocol_value(255),
            ServerEncoding::Gb18030
        );
    }

    #[test]
    fn test_utf8_roundtrip() {
        let s = "Hello, 世界!";
        let encoded = encode_to_server(ServerEncoding::Utf8, s);
        let decoded = decode_from_server(ServerEncoding::Utf8, &encoded);
        assert_eq!(decoded, s);
    }

    #[test]
    fn test_gb18030_roundtrip() {
        let s = "达梦数据库测试";
        let encoded = encode_to_server(ServerEncoding::Gb18030, s);
        let decoded = decode_from_server(ServerEncoding::Gb18030, &encoded);
        assert_eq!(decoded, s);
    }

    #[test]
    fn test_gb18030_ascii_passthrough() {
        let s = "SELECT * FROM TABLE";
        let encoded = encode_to_server(ServerEncoding::Gb18030, s);
        // ASCII should be identical in GB18030
        assert_eq!(encoded, s.as_bytes());
        let decoded = decode_from_server(ServerEncoding::Gb18030, &encoded);
        assert_eq!(decoded, s);
    }

    #[test]
    fn test_gb18030_chinese() {
        // These Chinese characters should encode to multi-byte GB18030
        let s = "中文";
        let encoded = encode_to_server(ServerEncoding::Gb18030, s);
        // GB18030 encoding of Chinese chars is multi-byte
        assert!(encoded.len() > s.len().min(2));
        let decoded = decode_from_server(ServerEncoding::Gb18030, &encoded);
        assert_eq!(decoded, s);
    }

    #[test]
    fn test_empty_string() {
        let encoded = encode_to_server(ServerEncoding::Gb18030, "");
        assert!(encoded.is_empty());
        let decoded = decode_from_server(ServerEncoding::Gb18030, &[]);
        assert!(decoded.is_empty());
    }

    #[test]
    fn test_invalid_gb18030_fallback() {
        // Invalid bytes in GB18030 should produce replacement chars
        let invalid_data = vec![0xFF, 0xFE, 0xFF, 0xFE];
        let decoded = decode_from_server(ServerEncoding::Gb18030, &invalid_data);
        // encoding_rs replaces invalid bytes with U+FFFD
        assert!(!decoded.is_empty());
    }
}
