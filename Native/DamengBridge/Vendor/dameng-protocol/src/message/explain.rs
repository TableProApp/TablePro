//! EXPLAIN response (type 149).
//!
//! DM8 returns a four-byte little-endian text length followed by a textual
//! execution plan encoded with the server connection encoding.

use dameng_types::encoding::{decode_from_server, ServerEncoding};

use crate::error::{Error, Result};

/// Upper bound for a textual query plan accepted from the server.
pub const MAX_EXPLAIN_TEXT_BYTES: usize = 16 * 1024 * 1024;

/// Parsed textual response for `EXPLAIN <statement>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExplainResponse {
    /// UTF-8 query plan text.
    pub plan: String,
}

impl ExplainResponse {
    /// Parse a length-prefixed plan from a DM8 EXPLAIN response.
    pub fn from_bytes(data: &[u8], server_encoding: ServerEncoding) -> Result<Self> {
        let length_bytes: [u8; 4] = data
            .get(..4)
            .ok_or(Error::Incomplete)?
            .try_into()
            .map_err(|_| Error::Incomplete)?;
        let text_length = u32::from_le_bytes(length_bytes) as usize;
        if text_length > MAX_EXPLAIN_TEXT_BYTES {
            return Err(Error::InvalidFrame(format!(
                "EXPLAIN text length {text_length} exceeds {MAX_EXPLAIN_TEXT_BYTES} bytes"
            )));
        }
        let text = data.get(4..4 + text_length).ok_or(Error::Incomplete)?;

        Ok(Self {
            plan: decode_from_server(server_encoding, text),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_utf8_plan() {
        let text = "1   #NSET2\n2     #CSCN2";
        let mut payload = (text.len() as u32).to_le_bytes().to_vec();
        payload.extend_from_slice(text.as_bytes());

        let response = ExplainResponse::from_bytes(&payload, ServerEncoding::Utf8).unwrap();

        assert_eq!(response.plan, text);
    }

    #[test]
    fn rejects_truncated_plan() {
        let payload = [8, 0, 0, 0, b'p', b'l', b'a', b'n'];

        assert!(matches!(
            ExplainResponse::from_bytes(&payload, ServerEncoding::Utf8),
            Err(Error::Incomplete)
        ));
    }

    #[test]
    fn rejects_oversized_plan() {
        let payload = ((MAX_EXPLAIN_TEXT_BYTES + 1) as u32).to_le_bytes().to_vec();

        assert!(matches!(
            ExplainResponse::from_bytes(&payload, ServerEncoding::Utf8),
            Err(Error::InvalidFrame(_))
        ));
    }
}
