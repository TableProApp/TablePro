//! CLOSE message (type 20) for closing a statement handle.

use bytes::BytesMut;

/// Client->Server CLOSE message (type 20).
///
/// Closes a previously prepared statement, freeing server resources.
#[derive(Debug, Clone)]
pub struct CloseMessage;

impl CloseMessage {
    /// Encode to payload bytes (empty payload).
    pub fn encode_payload(&self) -> BytesMut {
        BytesMut::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_close_encode_empty() {
        let close = CloseMessage;
        let payload = close.encode_payload();
        assert!(payload.is_empty());
    }

    #[test]
    fn test_close_debug() {
        let close = CloseMessage;
        let debug_str = format!("{:?}", close);
        assert!(debug_str.contains("CloseMessage"));
    }

    #[test]
    fn test_close_clone() {
        let close = CloseMessage;
        let _cloned = close.clone();
    }
}
