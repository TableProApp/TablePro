//! READY message (type 3) and ACK response (type 187).

use bytes::{BufMut, BytesMut};

use crate::error::Result;

/// Client->Server READY message (type 3).
///
/// Sent to confirm connection is ready or as a keepalive.
#[derive(Debug, Clone)]
pub struct ReadyMessage {
    pub flags: u8,
}

impl ReadyMessage {
    /// Create a new ready message.
    pub fn new() -> Self {
        Self { flags: 1 }
    }

    /// Encode to payload bytes.
    pub fn encode_payload(&self) -> BytesMut {
        let mut buf = BytesMut::new();
        buf.put_u8(self.flags);
        buf.put_u8(0);
        buf.put_u8(0);
        buf.put_u8(0);
        buf
    }
}

/// Server->Client ACK response (type 187).
///
/// Generic success response for most operations.
#[derive(Debug, Clone)]
pub struct AckResponse {
    pub status: u8,
    pub rows_affected: i64,
    pub statement_id: u32,
    pub message: String,
}

impl AckResponse {
    /// Parse from raw payload bytes.
    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        if data.len() < 4 {
            return Err(crate::error::Error::Incomplete);
        }

        let status = data[0];
        let _reserved = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
        let rows_affected = if data.len() >= 16 {
            i64::from_le_bytes([
                data[8], data[9], data[10], data[11], data[12], data[13], data[14], data[15],
            ])
        } else {
            0
        };

        let statement_id = if data.len() >= 36 {
            u32::from_le_bytes([data[32], data[33], data[34], data[35]])
        } else {
            0
        };

        // Message string at offset 52
        let message = if data.len() >= 56 {
            let msg_len = u32::from_le_bytes([data[52], data[53], data[54], data[55]]) as usize;
            let msg_end = (56 + msg_len).min(data.len());
            String::from_utf8_lossy(&data[56..msg_end]).to_string()
        } else {
            String::new()
        };

        Ok(Self {
            status,
            rows_affected,
            statement_id,
            message,
        })
    }

    /// Check if this is a success response.
    pub fn is_success(&self) -> bool {
        self.status == 1 || self.status == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ready_new() {
        let ready = ReadyMessage::new();
        assert_eq!(ready.flags, 1);
    }

    #[test]
    fn test_ready_encode_size() {
        let ready = ReadyMessage::new();
        let payload = ready.encode_payload();
        assert_eq!(payload.len(), 4);
    }

    #[test]
    fn test_ack_from_bytes_success() {
        let mut data = [0u8; 64];
        data[0] = 1; // status = success
                     // Message "Success" at offset 56
        data[52] = 7; // msg_len
        let msg = b"Success";
        data[56..56 + msg.len()].copy_from_slice(msg);

        let ack = AckResponse::from_bytes(&data).unwrap();
        assert_eq!(ack.status, 1);
        assert_eq!(ack.message, "Success");
        assert!(ack.is_success());
    }

    #[test]
    fn test_ack_from_bytes_incomplete() {
        let data = [0u8; 2];
        let result = AckResponse::from_bytes(&data);
        assert!(matches!(result, Err(crate::error::Error::Incomplete)));
    }

    #[test]
    fn test_ack_is_success() {
        let ack = AckResponse {
            status: 0,
            rows_affected: 0,
            statement_id: 0,
            message: String::new(),
        };
        assert!(ack.is_success());
    }

    #[test]
    fn test_ready_flags() {
        let ready = ReadyMessage { flags: 0 };
        let payload = ready.encode_payload();
        assert_eq!(payload[0], 0);
    }
}
