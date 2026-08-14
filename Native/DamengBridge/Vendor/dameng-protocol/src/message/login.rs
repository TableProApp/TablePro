//! LOGIN message (type 1) and LOGIN_RESPONSE (type 163).
//!
//! Wire format reverse-engineered from captured traffic of the official
//! Python dmPython driver via proxy (see proxy_capture.log).

use bytes::{BufMut, BytesMut};

use crate::error::Result;

/// Client->Server LOGIN message (type 1).
///
/// Payload layout (from capture):
/// ```text
/// Offset  Size  Field
/// 0       4     Encrypted username length (i32 LE)
/// 4       N     Encrypted username bytes (XOR with challenge)
/// 4+N     4     Encrypted password length (i32 LE)
/// 4+N+4   M     Encrypted password bytes (XOR with challenge)
/// 4+N+4+M 4     Separator (4 bytes of zeros)
/// ...      4     OS name length (i32 LE)
/// ...      K     OS name bytes (plaintext)
/// ...      4     Hostname length (i32 LE)
/// ...      L     Hostname bytes + null terminator
/// ```
#[derive(Debug, Clone)]
pub struct LoginMessage {
    pub username: String,
    pub password: String,
    pub hostname: String,
    pub os_name: String,
}

impl LoginMessage {
    pub fn new(username: &str, password: &str, hostname: &str) -> Self {
        Self {
            username: username.to_string(),
            password: password.to_string(),
            hostname: hostname.to_string(),
            os_name: format!("{} {}", std::env::consts::FAMILY, std::env::consts::OS),
        }
    }

    pub fn encode_payload(&self, challenge: &[u8]) -> BytesMut {
        let mut buf = BytesMut::with_capacity(128);

        // Encrypted username (i32 length + XOR-encrypted bytes)
        let un_len = self.username.len();
        buf.put_i32_le(un_len as i32);
        for i in 0..un_len {
            let key_byte = if !challenge.is_empty() {
                challenge[i % challenge.len()]
            } else {
                0
            };
            buf.put_u8(self.username.as_bytes()[i] ^ key_byte);
        }

        // Encrypted password (i32 length + XOR-encrypted bytes)
        let pw_len = self.password.len();
        buf.put_i32_le(pw_len as i32);
        for i in 0..pw_len {
            let key_byte = if !challenge.is_empty() {
                challenge[i % challenge.len()]
            } else {
                0
            };
            buf.put_u8(self.password.as_bytes()[i] ^ key_byte);
        }

        // Separator (4 bytes of zeros)
        buf.put_bytes(0, 4);

        // OS name (i32 length + plaintext bytes)
        let os_bytes = self.os_name.as_bytes();
        buf.put_i32_le(os_bytes.len() as i32);
        buf.put_slice(os_bytes);

        // Hostname + null terminator (i32 length + plaintext bytes + null)
        let host_bytes = self.hostname.as_bytes();
        buf.put_i32_le(host_bytes.len() as i32);
        buf.put_slice(host_bytes);
        buf.put_u8(0);

        buf
    }
}

/// Server->Client LOGIN_RESPONSE message (type 163).
///
/// Wire format from capture:
/// ```text
/// Offset  Size  Field
/// 0       16    Reserved (zeros)
/// 16      4     Server name length (i32 LE)
/// 20      N     Server name string
/// 20+N    4     Authenticated username length (i32 LE)
/// 20+N+4  M     Authenticated username string
/// 20+N+4+M 4    Client IP length (i32 LE)
/// ...      K     Client IP string
/// ...      4     Login datetime length (i32 LE)
/// ...      L     Login datetime string
/// ...      4     Session flags
/// ...      4     More flags
/// ...      var   Database name length + string
/// ```
#[derive(Debug, Clone)]
pub struct LoginResponse {
    pub session_id: u32,
    pub encoding: u8,
    pub server_status: u8,
    pub server_name: String,
    pub username: String,
    pub client_ip: String,
    pub login_datetime: String,
    pub db_name: String,
}

impl LoginResponse {
    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        if data.len() < 0x50 {
            return Err(crate::error::Error::Incomplete);
        }

        // Session ID at offset 2
        let session_id = u32::from_le_bytes([data[2], data[3], data[4], data[5]]);

        let encoding = match data[0x0A] {
            0 => 0u8, // GB18030
            1 => 1u8, // UTF-8
            2 => 2u8, // EUC-KR
            _ => 0u8, // default to GB18030 (matching DM Go driver)
        };

        let server_status = data[0x0E];

        // Server name at offset 0x10 (16): i32 length + string
        let sn_len = u32::from_le_bytes([data[0x10], data[0x11], data[0x12], data[0x13]]) as usize;
        let sn_start = 0x14;
        let sn_end = (sn_start + sn_len).min(data.len());
        let server_name = String::from_utf8_lossy(&data[sn_start..sn_end])
            .trim_matches('\0')
            .to_string();

        // Authenticated username after server name
        let un_offset = sn_start + sn_len;
        let mut username = String::new();
        let mut client_ip = String::new();
        let mut login_datetime = String::new();
        let mut db_name = String::new();

        if data.len() > un_offset + 4 {
            let un_len = u32::from_le_bytes([
                data[un_offset],
                data.get(un_offset + 1).copied().unwrap_or(0),
                data.get(un_offset + 2).copied().unwrap_or(0),
                data.get(un_offset + 3).copied().unwrap_or(0),
            ]) as usize;
            let un_start = un_offset + 4;
            if un_len > 0 && data.len() > un_start + un_len {
                username = String::from_utf8_lossy(&data[un_start..un_start + un_len]).to_string();
            }

            // Client IP
            let ip_offset = un_start + un_len;
            if data.len() > ip_offset + 4 {
                let ip_len = u32::from_le_bytes([
                    data[ip_offset],
                    data.get(ip_offset + 1).copied().unwrap_or(0),
                    data.get(ip_offset + 2).copied().unwrap_or(0),
                    data.get(ip_offset + 3).copied().unwrap_or(0),
                ]) as usize;
                let ip_start = ip_offset + 4;
                if ip_len > 0 && data.len() > ip_start + ip_len {
                    client_ip =
                        String::from_utf8_lossy(&data[ip_start..ip_start + ip_len]).to_string();
                }

                // Login datetime
                let dt_offset = ip_start + ip_len;
                if data.len() > dt_offset + 4 {
                    let dt_len = u32::from_le_bytes([
                        data[dt_offset],
                        data.get(dt_offset + 1).copied().unwrap_or(0),
                        data.get(dt_offset + 2).copied().unwrap_or(0),
                        data.get(dt_offset + 3).copied().unwrap_or(0),
                    ]) as usize;
                    let dt_start = dt_offset + 4;
                    if dt_len > 0 && data.len() > dt_start + dt_len {
                        login_datetime =
                            String::from_utf8_lossy(&data[dt_start..dt_start + dt_len]).to_string();
                    }

                    // DB name
                    let db_offset = dt_start + dt_len;
                    if data.len() > db_offset + 4 {
                        let db_len = u32::from_le_bytes([
                            data[db_offset],
                            data.get(db_offset + 1).copied().unwrap_or(0),
                            data.get(db_offset + 2).copied().unwrap_or(0),
                            data.get(db_offset + 3).copied().unwrap_or(0),
                        ]) as usize;
                        let db_start = db_offset + 4;
                        if db_len > 0 && data.len() > db_start + db_len {
                            db_name = String::from_utf8_lossy(&data[db_start..db_start + db_len])
                                .to_string();
                        }
                    }
                }
            }
        }

        Ok(Self {
            session_id,
            encoding,
            server_status,
            server_name,
            username,
            client_ip,
            login_datetime,
            db_name,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_login_new() {
        let login = LoginMessage::new("SYSDBA", "SYSDBA", "localhost");
        assert_eq!(login.username, "SYSDBA");
        assert_eq!(login.password, "SYSDBA");
    }

    #[test]
    fn test_login_encode_payload_no_challenge() {
        let login = LoginMessage::new("SYSDBA", "SYSDBA", "localhost");
        let payload = login.encode_payload(&[]);
        // un_len(4) + "SYSDBA"(6) + pw_len(4) + "SYSDBA"(6) + sep(4) + os_len(4) + os + host_len(4) + host(9) + null(1)
        let expected = 4 + 6 + 4 + 6 + 4 + 4 + login.os_name.len() + 4 + 9 + 1;
        assert_eq!(payload.len(), expected);
        // Username should be plaintext without challenge
        assert_eq!(&payload[4..10], b"SYSDBA");
    }

    #[test]
    fn test_login_xor_encryption() {
        let challenge = [0xAAu8; 48];
        let login = LoginMessage::new("AB", "CD", "localhost");
        let payload = login.encode_payload(&challenge);
        // 'A' ^ 0xAA = 0x55, 'B' ^ 0xAA = 0xA8
        assert_eq!(payload[4], 0x41 ^ 0xAA);
        assert_eq!(payload[5], 0x42 ^ 0xAA);
    }

    #[test]
    fn test_login_response_from_bytes() {
        let mut data = [0u8; 256];
        data[2] = 0x40;
        data[3] = 0x1F; // session_id = 0x1F40
        data[0x0A] = 0x01; // UTF-8
        data[0x0E] = 0x01; // server_status
                           // Server name at 0x10: len + string
        let sn = b"DMSERVER";
        data[0x10] = sn.len() as u8;
        data[0x14..0x14 + sn.len()].copy_from_slice(sn);
        // Username at 0x14 + 8 = 0x1C: len + string
        let un = b"SYSDBA";
        data[0x1C] = un.len() as u8;
        data[0x20..0x20 + un.len()].copy_from_slice(un);

        let resp = LoginResponse::from_bytes(&data).unwrap();
        assert_eq!(resp.server_name, "DMSERVER");
        assert_eq!(resp.username, "SYSDBA");
        assert_eq!(resp.encoding, 1);
    }

    #[test]
    fn test_login_response_incomplete() {
        let data = [0u8; 32];
        let result = LoginResponse::from_bytes(&data);
        assert!(matches!(result, Err(crate::error::Error::Incomplete)));
    }

    #[test]
    fn test_login_payload_matches_capture() {
        // From capture: un_len=6, encrypted_un, pw_len=6, encrypted_pw, sep=4, os_len=8, os, host_len, host, null
        let challenge = [0xBBu8; 48];
        let login = LoginMessage::new("SYSDBA", "SYSDBA", "localhost");
        let payload = login.encode_payload(&challenge);
        assert_eq!(
            i32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]),
            6
        );
        // Encrypted username
        assert_eq!(payload[4], b'S' ^ 0xBB);
        // Password starts at offset 10
        assert_eq!(
            i32::from_le_bytes([payload[10], payload[11], payload[12], payload[13]]),
            6
        );
        // Separator at offset 20
        assert_eq!(&payload[20..24], &[0u8; 4]);
    }
}
