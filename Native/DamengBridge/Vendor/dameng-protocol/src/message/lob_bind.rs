//! LOB data streaming message for binding large CLOB/BLOB parameters.
//!
//! When a CLOB/BLOB parameter exceeds 2048 bytes (DM_OFF_ROW_THRESHOLD),
//! the data is streamed to the server in chunks BEFORE the bind execute
//! message. This uses message type 14.
//!
//! Wire format (per Go driver `dm_build_811`):
//! ```text
//! Offset  Size  Field
//! 0       1     msg_type (14)
//! 1       2     param_index (i16 LE) - which parameter this chunk belongs to
//! 3       4     data_length (i32 LE) - length of data in this chunk
//! 7       N     data bytes
//! ```
//!
//! After all chunks are sent for all off-row parameters, the bind execute
//! message is sent with empty placeholders for those parameters.

use bytes::{BufMut, BytesMut};

/// DM off-row threshold — LOBs larger than this use streaming.
pub const DM_OFF_ROW_THRESHOLD: usize = 2048;

/// Maximum chunk size for streaming LOB data to the server.
pub const DM_LOB_CHUNK_SIZE: usize = 16000;

/// Message type for LOB data streaming.
pub const DM_LOB_DATA_MSG_TYPE: u8 = 14;

/// A single chunk of LOB data to stream to the server.
///
/// This is sent as msg_type=14 with the parameter index and chunk data.
#[derive(Debug, Clone)]
pub struct LobDataMessage {
    /// Parameter index (0-based) this chunk belongs to.
    pub param_index: i16,
    /// The data chunk bytes.
    pub data: Vec<u8>,
}

impl LobDataMessage {
    /// Create a new LOB data chunk message.
    pub fn new(param_index: i16, data: Vec<u8>) -> Self {
        Self { param_index, data }
    }

    /// Encode to payload bytes (without frame header).
    ///
    /// Matches the Go driver's dm_build_811 message format:
    /// - 20 bytes reserved (zeros)
    /// - param_index (i16 LE, USINT) at offset 20
    /// - data_length (i32 LE, ULINT) at offset 22
    /// - if NewLobFlag: -1 (i32 LE, ULINT) at offset 26
    /// - data bytes starting at offset 28 (or 26 if no NewLobFlag)
    pub fn encode_payload(&self, new_lob_flag: bool) -> BytesMut {
        let mut buf = BytesMut::new();

        // 20 bytes reserved (matching Go's Dm_build_810 = Dm_build_327 = 20)
        buf.put_bytes(0, 20);

        // param_index (USINT = i16 LE) at offset 20
        buf.put_i16_le(self.param_index);

        // data_length (ULINT = i32 LE) at offset 22
        buf.put_i32_le(self.data.len() as i32);

        // if NewLobFlag: write -1 (ULINT) at offset 26
        if new_lob_flag {
            buf.put_i32_le(-1);
        }

        // data bytes
        buf.put_slice(&self.data);

        buf
    }
}

/// Split LOB data into chunks for streaming.
///
/// Returns a list of chunks, each at most DM_LOB_CHUNK_SIZE bytes.
pub fn split_lob_data(data: &[u8]) -> Vec<Vec<u8>> {
    let mut chunks = Vec::new();
    let mut start = 0;
    while start < data.len() {
        let end = (start + DM_LOB_CHUNK_SIZE).min(data.len());
        chunks.push(data[start..end].to_vec());
        start = end;
    }
    chunks
}

/// Check if a LOB value should use off-row streaming.
///
/// CLOB/BLOB types with data > 2048 bytes use the off-row protocol.
/// DM type codes: CLOB=14, BLOB=13.
pub fn is_off_row(dtype: i32, length: usize) -> bool {
    let is_lob = dtype == 13 || dtype == 14;
    is_lob && length > DM_OFF_ROW_THRESHOLD
}

/// Encode a CLOB value to bytes for binding.
///
/// CLOB values are UTF-8 encoded text.
pub fn encode_clob_value(text: &str) -> Vec<u8> {
    text.as_bytes().to_vec()
}

/// Encode a BLOB value from hex string for binding.
///
/// BLOB values are raw bytes. If provided as hex, decode them.
pub fn encode_blob_from_hex(hex_str: &str) -> Vec<u8> {
    // Simple hex decode (trim "0x" prefix if present)
    let hex = hex_str.strip_prefix("0x").unwrap_or(hex_str);
    let mut result = Vec::with_capacity(hex.len() / 2);
    for i in (0..hex.len()).step_by(2) {
        if i + 1 < hex.len() {
            if let Ok(byte) = u8::from_str_radix(&hex[i..i + 2], 16) {
                result.push(byte);
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_off_row_clob_large() {
        assert!(is_off_row(14, 3000)); // CLOB > 2048
    }

    #[test]
    fn test_is_off_row_clob_small() {
        assert!(!is_off_row(14, 100)); // CLOB <= 2048
    }

    #[test]
    fn test_is_off_row_blob_large() {
        assert!(is_off_row(13, 5000)); // BLOB > 2048
    }

    #[test]
    fn test_is_off_row_blob_small() {
        assert!(!is_off_row(13, 500)); // BLOB <= 2048
    }

    #[test]
    fn test_is_off_row_non_lob() {
        assert!(!is_off_row(4, 10000)); // INT never off-row
    }

    #[test]
    fn test_is_off_row_boundary() {
        assert!(!is_off_row(14, 2048)); // exactly at threshold = inline
        assert!(is_off_row(14, 2049)); // 1 byte over = off-row
    }

    #[test]
    fn test_split_lob_data_small() {
        let data = vec![1u8; 100];
        let chunks = split_lob_data(&data);
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].len(), 100);
    }

    #[test]
    fn test_split_lob_data_single_chunk() {
        let data = vec![1u8; DM_LOB_CHUNK_SIZE];
        let chunks = split_lob_data(&data);
        assert_eq!(chunks.len(), 1);
    }

    #[test]
    fn test_split_lob_data_multiple_chunks() {
        let data = vec![1u8; 50000];
        let chunks = split_lob_data(&data);
        assert_eq!(chunks.len(), 4); // ceil(50000/16000)
        assert_eq!(chunks[0].len(), 16000);
        assert_eq!(chunks[1].len(), 16000);
        assert_eq!(chunks[2].len(), 16000);
        assert_eq!(chunks[3].len(), 2000);
    }

    #[test]
    fn test_split_lob_data_empty() {
        let data: Vec<u8> = vec![];
        let chunks = split_lob_data(&data);
        assert!(chunks.is_empty());
    }

    #[test]
    fn test_lob_data_message_encode_no_new_flag() {
        let msg = LobDataMessage::new(0, vec![1, 2, 3, 4, 5]);
        let payload = msg.encode_payload(false);
        // reserved(20) + param_index(2) + data_len(4) + data(5) = 31
        assert_eq!(payload.len(), 31);
        assert!(payload[..20].iter().all(|&b| b == 0));
        assert_eq!(i16::from_le_bytes([payload[20], payload[21]]), 0);
        assert_eq!(
            i32::from_le_bytes([payload[22], payload[23], payload[24], payload[25]]),
            5
        );
        assert_eq!(&payload[26..], &[1, 2, 3, 4, 5]);
    }

    #[test]
    fn test_lob_data_message_encode_with_new_flag() {
        let msg = LobDataMessage::new(2, vec![1, 2, 3, 4, 5]);
        let payload = msg.encode_payload(true);
        // reserved(20) + param_index(2) + data_len(4) + new_flag_marker(4) + data(5) = 35
        assert_eq!(payload.len(), 35);
        assert!(payload[..20].iter().all(|&b| b == 0));
        assert_eq!(i16::from_le_bytes([payload[20], payload[21]]), 2);
        assert_eq!(
            i32::from_le_bytes([payload[22], payload[23], payload[24], payload[25]]),
            5
        );
        // NewLobFlag marker: -1
        assert_eq!(
            i32::from_le_bytes([payload[26], payload[27], payload[28], payload[29]]),
            -1
        );
        assert_eq!(&payload[30..], &[1, 2, 3, 4, 5]);
    }

    #[test]
    fn test_encode_clob_value() {
        let encoded = encode_clob_value("hello");
        assert_eq!(encoded, b"hello");
    }

    #[test]
    fn test_encode_clob_value_unicode() {
        let encoded = encode_clob_value("你好");
        // UTF-8 bytes for 你好
        assert_eq!(encoded.len(), 6);
    }

    #[test]
    fn test_encode_blob_from_hex() {
        let blob = encode_blob_from_hex("48656c6c6f");
        assert_eq!(blob, b"Hello");
    }

    #[test]
    fn test_encode_blob_from_hex_with_prefix() {
        let blob = encode_blob_from_hex("0x48656c6c6f");
        assert_eq!(blob, b"Hello");
    }

    #[test]
    fn test_constants() {
        assert_eq!(DM_OFF_ROW_THRESHOLD, 2048);
        assert_eq!(DM_LOB_CHUNK_SIZE, 16000);
        assert_eq!(DM_LOB_DATA_MSG_TYPE, 14);
    }
}
