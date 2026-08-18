//! STARTUP message (type 200) and STARTUP_RESPONSE (type 228).
//!
//! Reverse-engineered from captured wire protocol traffic of the official
//! Python dmPython driver. See scripts/proxy.py and capture logs.

use bytes::{BufMut, BytesMut};

use crate::error::Result;

/// Client->Server STARTUP message (type 200).
///
/// Wire format (captured from working Python driver):
/// ```text
/// Offset  Size  Field
/// 0       4     Driver version string length (i32 LE)
/// 4       N     Driver version string (UTF-8, e.g. "8.1.1.126")
/// N+4     1     Null terminator (0x00)
/// N+5     4     Encryption key length (i32 LE, always 64)
/// N+9     64    Encryption key bytes (client-generated random)
/// ```
#[derive(Debug, Clone)]
pub struct StartupMessage {
    /// Driver version string (e.g. "8.1.1.126" or "7.6.0.0").
    pub driver_version: String,
    /// 64-byte encryption key.
    pub encryption_key: [u8; 64],
}

impl StartupMessage {
    /// Create a new startup message with default values.
    pub fn new() -> Self {
        // Generate random-looking key bytes (XOR pattern to avoid all-zeros)
        let mut key = [0u8; 64];
        for i in 0..64 {
            key[i] = ((i * 7 + 13) & 0xFF) as u8;
        }
        Self {
            driver_version: "7.6.0.0".to_string(),
            encryption_key: key,
        }
    }

    /// Encode to payload bytes.
    pub fn encode_payload(&self) -> BytesMut {
        let ver_bytes = self.driver_version.as_bytes();
        let key_len = self.encryption_key.len();
        let total = 4 + ver_bytes.len() + 1 + 4 + key_len;
        let mut buf = BytesMut::with_capacity(total);

        // i32 LE: version string length
        buf.put_i32_le(ver_bytes.len() as i32);
        // Version string bytes
        buf.put_slice(ver_bytes);
        // Null terminator
        buf.put_u8(0);
        // i32 LE: encryption key length (always 64)
        buf.put_i32_le(key_len as i32);
        // 64 bytes of encryption key
        buf.put_slice(&self.encryption_key);

        buf
    }
}

/// Server->Client STARTUP_RESPONSE message (type 228 for success, type 187 for error).
///
/// Wire format (captured from working Python driver):
/// ```text
/// Offset  Size  Field
/// 0       16    Reserved (zeros)
/// 16      4     Server version string length (i32 LE)
/// 20      N     Server version string (UTF-8, e.g. "8.1.3.62")
/// 20+N    4     Padding/sentinel (i32 LE, usually -1)
/// 24+N    4     Challenge length (i32 LE, always 64)
/// 28+N    64    Challenge/encryption key bytes
/// 92+N    var   Additional server data
/// ```
#[derive(Debug, Clone)]
pub struct StartupResponse {
    /// Server encoding (1=UTF-8, 2=GB18030).
    pub encoding: u8,
    /// Server challenge for encryption (48-64 bytes).
    pub challenge: Vec<u8>,
    /// Server version string.
    pub server_version: String,
    /// Server encryption public key.
    pub encryption_key: Vec<u8>,
    /// Response code from server frame header.
    pub response_code: i32,
    /// Session ID from server.
    pub session_id: u32,
}

impl StartupResponse {
    /// Parse from payload bytes and response code from the frame header.
    pub fn from_bytes(data: &[u8], response_code: i32) -> Result<Self> {
        // Check for error response (negative response code)
        if response_code < 0 {
            let mut server_version = String::new();
            if data.len() >= 12 {
                let msg_len = u32::from_le_bytes([
                    data[8].min(255),
                    data.get(9).copied().unwrap_or(0),
                    data.get(10).copied().unwrap_or(0),
                    data.get(11).copied().unwrap_or(0),
                ]) as usize;
                if data.len() > 12 + msg_len {
                    server_version = String::from_utf8_lossy(&data[12..12 + msg_len]).to_string();
                }
            }
            return Ok(Self {
                encoding: 0,
                challenge: vec![],
                server_version,
                encryption_key: vec![],
                response_code,
                session_id: 0,
            });
        }

        // Parse successful startup response
        let mut server_version = String::new();
        let mut challenge = Vec::new();
        let encryption_key = Vec::new();
        let mut encoding = 1u8; // default UTF-8
        let session_id = 0u32;

        if data.len() >= 20 {
            // Server version string length at offset 16
            let ver_len = u32::from_le_bytes([
                data[16],
                data.get(17).copied().unwrap_or(0),
                data.get(18).copied().unwrap_or(0),
                data.get(19).copied().unwrap_or(0),
            ]) as usize;

            let ver_start = 20;
            if ver_len > 0 && data.len() > ver_start + ver_len {
                server_version =
                    String::from_utf8_lossy(&data[ver_start..ver_start + ver_len]).to_string();
            }

            // After version: sentinel (-1), then key length (64)
            let after_ver = ver_start + ver_len;
            if after_ver + 8 <= data.len() {
                // Key length at after_ver+4
                let key_len = u32::from_le_bytes([
                    data[after_ver + 4],
                    data.get(after_ver + 5).copied().unwrap_or(0),
                    data.get(after_ver + 6).copied().unwrap_or(0),
                    data.get(after_ver + 7).copied().unwrap_or(0),
                ]) as usize;

                let key_start = after_ver + 8;
                if key_len > 0 && data.len() > key_start + key_len.min(64) {
                    challenge = data[key_start..key_start + key_len.min(64)].to_vec();
                }
            }
        }

        // Try to extract encoding from the payload
        // From the capture, encoding seems to be embedded in the response
        // For now, default to UTF-8
        if data.len() >= 44 {
            // Encoding might be at specific offsets in the response
            encoding = 1; // UTF-8
        }

        Ok(Self {
            encoding,
            challenge,
            server_version,
            encryption_key,
            response_code,
            session_id,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_startup_encode_default_version() {
        let msg = StartupMessage::new();
        let payload = msg.encode_payload();
        // 4 (len) + 7 (ver) + 1 (null) + 4 (key_len) + 64 (key) = 80
        assert_eq!(payload.len(), 80);

        // Verify version length field
        assert_eq!(
            i32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]),
            7
        );
        // Verify version string
        assert_eq!(&payload[4..11], b"7.6.0.0");
        // Verify null terminator
        assert_eq!(payload[11], 0);
        // Verify key length
        assert_eq!(
            i32::from_le_bytes([payload[12], payload[13], payload[14], payload[15]]),
            64
        );
    }

    #[test]
    fn test_startup_encode_custom_version() {
        let msg = StartupMessage {
            driver_version: "8.1.1.126".to_string(),
            encryption_key: [0xAB; 64],
        };
        let payload = msg.encode_payload();
        // 4 + 9 + 1 + 4 + 64 = 82
        assert_eq!(payload.len(), 82);
        assert_eq!(&payload[4..13], b"8.1.1.126");
        assert_eq!(payload[13], 0);
        assert_eq!(&payload[18..82], &[0xAB; 64]);
    }

    #[test]
    fn test_startup_response_error() {
        let mut data = [0u8; 64];
        data[8] = 28; // msg_len
        let msg = b"Fail to establish connection";
        data[12..12 + msg.len()].copy_from_slice(msg);
        let resp = StartupResponse::from_bytes(&data, -6003).unwrap();
        assert_eq!(resp.response_code, -6003);
        assert_eq!(resp.encoding, 0);
        assert_eq!(resp.challenge.len(), 0);
    }

    #[test]
    fn test_startup_response_invalid_version() {
        let mut data = [0u8; 64];
        data[8] = 20;
        let msg = b"Invalid client version";
        data[12..12 + msg.len()].copy_from_slice(msg);
        let resp = StartupResponse::from_bytes(&data, -118).unwrap();
        assert_eq!(resp.response_code, -118);
        assert!(resp.server_version.contains("Invalid"));
    }

    #[test]
    fn test_startup_response_success() {
        let mut data = [0u8; 112];
        // 16 bytes of zeros (reserved)
        // Server version length at offset 16
        let ver = b"8.1.3.62";
        data[16] = ver.len() as u8;
        data[20..20 + ver.len()].copy_from_slice(ver);
        // Sentinel at offset 28: -1
        data[28] = 0xFF;
        data[29] = 0xFF;
        data[30] = 0xFF;
        data[31] = 0xFF;
        // Key length at offset 32: 64
        data[32] = 64;
        // Challenge bytes at offset 36
        for i in 0..48 {
            data[36 + i] = 0xBB;
        }

        let resp = StartupResponse::from_bytes(&data, 0).unwrap();
        assert_eq!(resp.server_version, "8.1.3.62");
        assert_eq!(resp.response_code, 0);
    }

    #[test]
    fn test_startup_key_not_all_zeros() {
        let msg = StartupMessage::new();
        // Key should not be all zeros
        let non_zero_count = msg.encryption_key.iter().filter(|&&b| b != 0).count();
        assert!(non_zero_count > 0, "encryption key should not be all zeros");
    }
}
