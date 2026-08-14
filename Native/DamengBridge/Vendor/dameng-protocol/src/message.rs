//! Dameng protocol message types.
//!
//! This module defines all message types used in the DM wire protocol.
//! Messages are organized by their direction (client->server or server->client)
//! and their purpose in the connection lifecycle.

pub mod bind;
pub mod close;
pub mod exec;
pub mod explain;
pub mod fetch;
pub mod isolation;
pub mod lob;
pub mod lob_bind;
pub mod login;
pub mod ready;
pub mod response;
pub mod startup;
pub mod transaction;

pub use bind::*;
pub use close::*;
pub use exec::*;
pub use explain::*;
pub use fetch::*;
pub use isolation::*;
pub use lob::*;
pub use lob_bind::*;
pub use login::*;
pub use ready::*;
pub use response::*;
pub use startup::*;
pub use transaction::*;

// Re-export msg_type constants at top level for convenience
pub use self::msg_type::*;

use bytes::{BufMut, BytesMut};

use crate::frame::Frame;

/// Message type constants.
pub mod msg_type {
    /// STARTUP - Initial connection handshake (client->server)
    pub const STARTUP: u8 = 200;
    /// STARTUP_RESPONSE - Server hello (server->client)
    pub const STARTUP_RESPONSE: u8 = 228;
    /// LOGIN - Send credentials (client->server)
    pub const LOGIN: u8 = 1;
    /// LOGIN_RESPONSE - Authentication result (server->client)
    pub const LOGIN_RESPONSE: u8 = 163;
    /// STATEMENT_PREPARE - Allocate a statement handle (client->server).
    /// Previously named READY; kept for backward compatibility.
    pub const STATEMENT_PREPARE: u8 = 3;
    /// READY - Alias for STATEMENT_PREPARE (type 3). Send ready/keepalive (client->server).
    pub const READY: u8 = 3;
    /// STATEMENT_FREE - Free a statement handle (client->server).
    pub const STATEMENT_FREE: u8 = 4;
    /// ACK - Success/generic response (server->client)
    pub const ACK: u8 = 187;
    /// PREPARE/EXEC - Prepare and execute statement (client->server)
    pub const EXEC: u8 = 5;
    /// EXEC_RESPONSE - Statement result (server->client)
    pub const EXEC_RESPONSE: u8 = 0;
    /// EXPLAIN_RESPONSE - Text query plan (server->client)
    pub const EXPLAIN_RESPONSE: u8 = 149;
    /// FETCH - Fetch more rows from result set (client->server)
    pub const FETCH: u8 = 7;
    /// COMMIT - Commit transaction (client->server)
    pub const COMMIT: u8 = 8;
    /// ROLLBACK - Rollback transaction (client->server)
    pub const ROLLBACK: u8 = 9;
    /// BIND - Legacy bind parameters and execute (client->server)
    pub const BIND: u8 = 13;
    /// BIND_EXEC2 - Bind parameters and execute with EXEC2 protocol (client->server)
    pub const BIND_EXEC2: u8 = 90;
    /// CLOSE - Close statement (client->server)
    pub const CLOSE: u8 = 20;
    /// STATEMENT_SET_CURSOR - Set cursor position for a statement (client->server)
    pub const STATEMENT_SET_CURSOR: u8 = 27;
    /// FETCH_RESULT_SET - Fetch an entire result set (client->server)
    pub const FETCH_RESULT_SET: u8 = 44;
    /// SET_ISOLATION - Set transaction isolation level (client->server)
    pub const SET_ISOLATION: u8 = 52;
    /// OPTIMIZED_PREPARE_EXEC - Optimized prepare-and-execute path (client->server)
    pub const OPTIMIZED_PREPARE_EXEC: u8 = 91;
    /// LOB_FREE - Free a LOB locator (client->server)
    pub const LOB_FREE: u8 = 29;
    /// LOB_GETLEN - Get LOB length (client->server)
    pub const LOB_GETLEN: u8 = 31;
    /// LOB_READ - Read LOB data chunk (client->server)
    pub const LOB_READ: u8 = 32;
}

/// DM data type codes.
pub mod dm_type {
    pub const BIT: i32 = 1;
    pub const TINYINT: i32 = 2;
    pub const VARCHAR: i32 = 3;
    pub const INT: i32 = 4;
    pub const BIGINT: i32 = 5;
    pub const SMALLINT: i32 = 6;
    pub const FLOAT: i32 = 7;
    pub const DOUBLE: i32 = 8;
    pub const DECIMAL: i32 = 9;
    pub const DATE: i32 = 10;
    pub const TIME: i32 = 11;
    pub const TIMESTAMP: i32 = 12;
    pub const BLOB: i32 = 13;
    pub const CLOB: i32 = 14;
    pub const INTERVAL: i32 = 15;
    pub const CHAR: i32 = 16;
    pub const BINARY: i32 = 17;
    pub const VARBINARY: i32 = 18;
    pub const NUMERIC: i32 = 20;
    pub const BOOLEAN: i32 = 21;
    pub const DATETIME: i32 = 22;
    pub const VARCHAR2: i32 = 23;
    pub const DATETIME2: i32 = 24;
    pub const TIME_TZ: i32 = 25;
    pub const DATETIME_TZ: i32 = 26;
    pub const INTERVAL_YM: i32 = 27;
    pub const INTERVAL_DT: i32 = 28;
    pub const RAW: i32 = 29;
    pub const DATETIME2_TZ: i32 = 30;
    pub const REAL: i32 = 31;
}

/// DM encoding values.
pub mod encoding {
    pub const UTF8: u8 = 1;
    pub const GB18030: u8 = 2;
}

/// Language ID values.
pub mod language {
    pub const EN: u16 = 1;
    pub const CN: u16 = 2;
}

/// Encryption utility functions.
/// DM uses a simple XOR encryption for credentials.
pub mod crypto {

    /// Generate encrypted credentials using the server's challenge.
    /// The algorithm XORs the plaintext with the challenge bytes, cycling through.
    pub fn encrypt_with_challenge(plaintext: &[u8], challenge: &[u8], output: &mut [u8]) {
        let challenge_len = challenge.len();
        if challenge_len == 0 {
            output.copy_from_slice(plaintext);
            return;
        }
        for (i, (out, &plain)) in output.iter_mut().zip(plaintext.iter()).enumerate() {
            *out = plain ^ challenge[i % challenge_len];
        }
    }

    /// Build the startup message encrypted random key from server challenge.
    pub fn build_startup_key(challenge: &[u8]) -> [u8; 64] {
        let mut key = [0u8; 64];
        // Generate a simple key pattern based on challenge
        let challenge_len = challenge.len();
        if challenge_len > 0 {
            for i in 0..64 {
                key[i] = challenge[i % challenge_len] ^ (i as u8);
            }
        }
        key
    }
}

/// Build a complete message (frame + payload) and return it as BytesMut.
pub fn build_message(msg_type: u8, handle: u32, payload: &[u8]) -> BytesMut {
    let frame = Frame::new(msg_type, handle, payload.len() as i32);
    let mut result = frame.encode();
    result.put_slice(payload);
    result
}
