//! SET_ISOLATION message (type 52) for setting transaction isolation level.
//!
//! DM server protocol values (verified against Go driver dm_go/m.go g2dbIsoLevel):
//! - 0: Read Uncommitted
//! - 1: Read Committed
//! - 2: Repeatable Read
//! - 3: Serializable

use bytes::{BufMut, BytesMut};

use crate::frame::FRAME_HEADER_SIZE;
use crate::message::SET_ISOLATION;

/// Transaction isolation levels supported by DM.
///
/// Note: The DM protocol uses 0/1/2/3 for these values, NOT the standard
/// SQL 1/2/4/6 values. The Go driver's `g2dbIsoLevel()` does the same mapping.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IsolationLevel {
    /// Read Uncommitted - can read uncommitted changes from other transactions.
    ReadUncommitted,
    /// Read Committed - only reads committed data.
    ReadCommitted,
    /// Repeatable Read - guarantees same result for repeated reads.
    RepeatableRead,
    /// Serializable - complete isolation, transactions run serially.
    Serializable,
}

impl IsolationLevel {
    /// Convert to DM protocol value (0/1/2/3).
    pub fn to_protocol_value(self) -> i32 {
        match self {
            IsolationLevel::ReadUncommitted => 0,
            IsolationLevel::ReadCommitted => 1,
            IsolationLevel::RepeatableRead => 2,
            IsolationLevel::Serializable => 3,
        }
    }

    /// Create from DM protocol value (0/1/2/3).
    pub fn from_protocol_value(value: i32) -> Option<Self> {
        match value {
            0 => Some(IsolationLevel::ReadUncommitted),
            1 => Some(IsolationLevel::ReadCommitted),
            2 => Some(IsolationLevel::RepeatableRead),
            3 => Some(IsolationLevel::Serializable),
            _ => None,
        }
    }
}

/// SET_ISOLATION message (type 52) to change transaction isolation level.
#[derive(Debug, Clone)]
pub struct SetIsolationMessage {
    /// The isolation level to set.
    pub level: IsolationLevel,
}

impl SetIsolationMessage {
    /// Create a new SET_ISOLATION message.
    pub fn new(level: IsolationLevel) -> Self {
        Self { level }
    }

    /// Encode to a complete frame (header + no payload).
    ///
    /// Verified against Go driver (dm_build_828): the isolation level is
    /// written **inside** the 64-byte frame header at offset 20 (i32 LE),
    /// with body_len=0. No extra payload is sent.
    pub fn encode_frame(&self, handle: u32) -> BytesMut {
        let mut buf = BytesMut::with_capacity(FRAME_HEADER_SIZE);
        buf.put_bytes(0, FRAME_HEADER_SIZE);

        // Offset 0: handle (u32 LE)
        buf[0..4].copy_from_slice(&handle.to_le_bytes());
        // Offset 4: msg_type (SET_ISOLATION=52)
        buf[4] = SET_ISOLATION;
        // Offset 6: body_len (i32 LE) = 0
        // Offset 10: response_code (i32 LE) = 0

        // Offset 20: isolation_level (i32 LE) — written into reserved area
        buf[20..24].copy_from_slice(&self.level.to_protocol_value().to_le_bytes());

        // Compute XOR checksum at offset 19 (bytes 0..19)
        let mut cs: u8 = 0;
        for i in 0..19 {
            cs ^= buf[i];
        }
        buf[19] = cs;

        buf
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_isolation_level_protocol_values() {
        assert_eq!(IsolationLevel::ReadUncommitted.to_protocol_value(), 0);
        assert_eq!(IsolationLevel::ReadCommitted.to_protocol_value(), 1);
        assert_eq!(IsolationLevel::RepeatableRead.to_protocol_value(), 2);
        assert_eq!(IsolationLevel::Serializable.to_protocol_value(), 3);
    }

    #[test]
    fn test_isolation_level_from_protocol() {
        assert_eq!(
            IsolationLevel::from_protocol_value(0),
            Some(IsolationLevel::ReadUncommitted)
        );
        assert_eq!(
            IsolationLevel::from_protocol_value(1),
            Some(IsolationLevel::ReadCommitted)
        );
        assert_eq!(
            IsolationLevel::from_protocol_value(2),
            Some(IsolationLevel::RepeatableRead)
        );
        assert_eq!(
            IsolationLevel::from_protocol_value(3),
            Some(IsolationLevel::Serializable)
        );
        assert_eq!(IsolationLevel::from_protocol_value(99), None);
    }

    #[test]
    fn test_set_isolation_encode() {
        let msg = SetIsolationMessage::new(IsolationLevel::ReadCommitted);
        let frame = msg.encode_frame(0);
        assert_eq!(frame.len(), FRAME_HEADER_SIZE);
        // isolation_level at offset 20
        assert_eq!(
            i32::from_le_bytes([frame[20], frame[21], frame[22], frame[23]]),
            1 // ReadCommitted = 1 in protocol
        );
        // msg_type at offset 4
        assert_eq!(frame[4], SET_ISOLATION);
    }

    #[test]
    fn test_set_isolation_all_levels() {
        for level in [
            IsolationLevel::ReadUncommitted,
            IsolationLevel::ReadCommitted,
            IsolationLevel::RepeatableRead,
            IsolationLevel::Serializable,
        ] {
            let msg = SetIsolationMessage::new(level);
            let frame = msg.encode_frame(7);
            assert_eq!(frame.len(), FRAME_HEADER_SIZE);
            assert_eq!(frame[4], SET_ISOLATION);
            assert_eq!(
                i32::from_le_bytes([frame[20], frame[21], frame[22], frame[23]]),
                level.to_protocol_value()
            );
            // verify handle
            assert_eq!(
                u32::from_le_bytes([frame[0], frame[1], frame[2], frame[3]]),
                7
            );
        }
    }

    #[test]
    fn test_isolation_roundtrip() {
        for level in [
            IsolationLevel::ReadUncommitted,
            IsolationLevel::ReadCommitted,
            IsolationLevel::RepeatableRead,
            IsolationLevel::Serializable,
        ] {
            let pv = level.to_protocol_value();
            let recovered = IsolationLevel::from_protocol_value(pv).unwrap();
            assert_eq!(level, recovered, "roundtrip failed for {:?}", level);
        }
    }
}
