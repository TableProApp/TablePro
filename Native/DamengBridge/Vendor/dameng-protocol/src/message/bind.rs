//! BIND message (type 13) for binding parameters to prepared statements.
//!
//! Also includes statement handle management messages:
//! - StatementAllocate (type 3): allocate a new statement handle
//! - StatementFree (type 4): free a statement handle

use bytes::{BufMut, BytesMut};

use crate::error::Result;

/// Parameter direction for binding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParameterDirection {
    /// Input parameter (default).
    Input = 1,
    /// Output parameter.
    Output = 2,
    /// Input/Output parameter.
    InputOutput = 3,
}

/// A single parameter to bind.
#[derive(Debug, Clone)]
pub struct BindParam {
    /// SQL type name (e.g., "INT", "VARCHAR").
    pub type_name: String,
    /// DM type code.
    pub type_code: i32,
    /// Precision for numeric types.
    pub precision: i32,
    /// Scale for numeric types.
    pub scale: i32,
    /// Parameter direction.
    pub direction: ParameterDirection,
    /// The parameter value as bytes (None = NULL).
    pub value: Option<Vec<u8>>,
}

/// Client->Server BIND message (type 13).
///
/// Legacy format — kept for backward compatibility.
#[derive(Debug, Clone)]
pub struct BindMessage {
    /// Whether to fetch results after binding.
    pub fetch_flag: u8,
    /// Parameters to bind.
    pub params: Vec<BindParam>,
}

impl BindMessage {
    /// Create a new bind message.
    pub fn new(fetch: bool, params: Vec<BindParam>) -> Self {
        Self {
            fetch_flag: if fetch { 1 } else { 0 },
            params,
        }
    }

    /// Encode to payload bytes (legacy format).
    pub fn encode_payload(&self) -> BytesMut {
        let mut buf = BytesMut::new();

        buf.put_u8(self.fetch_flag);
        buf.put_u8(0); // reserved
        buf.put_u16_le(0); // reserved
        buf.put_u16_le(self.params.len() as u16);
        buf.put_u16_le(0); // reserved
        buf.put_u32_le(0); // reserved
        buf.put_u32_le(0); // reserved
        buf.put_u32_le(0); // reserved
        buf.put_u32_le(0); // reserved
        buf.put_u32_le(0); // reserved

        for param in &self.params {
            // Type name
            let tn = param.type_name.as_bytes();
            buf.put_u16_le(tn.len() as u16);
            buf.put_slice(tn);

            // Type code, precision, scale
            buf.put_u32_le(param.type_code as u32);
            buf.put_u32_le(param.precision as u32);
            buf.put_u16_le(param.scale as u16);

            // Value
            if let Some(ref val) = param.value {
                buf.put_u16_le(val.len() as u16);
                buf.put_u16_le(0); // reserved
                buf.put_slice(val);
            } else {
                buf.put_u16_le(0xFFFF); // NULL marker
            }
        }

        buf
    }
}

/// Client->Server BIND_EXEC2 message (type 13).
///
/// Matches the Go driver's BIND_EXEC2 format exactly.
/// Used to execute a prepared statement with bound parameters.
///
/// Wire format:
/// ```text
/// Offset  Size  Field
/// 0       1     auto_commit (0 or 1)
/// 1       2     param_count (u16 LE)
/// 3       1     has_result_set (1=SELECT, 0=DML)
/// 4       8     offset (i64 LE) - pagination start
/// 12      8     cursor_update_row (i64 LE)
/// 20      8     max_rows (i64 LE) - 0=unlimited
/// 28      1     flags
/// 29      3     reserved
/// 32      4     query_timeout (i32 LE) - 0=default
/// 36      4     batch_allow_max_errors (i32 LE)
/// 40      1     innerExec
/// 41      1     bind_options (MsgVersion >= 8)
/// 42      N     Parameter descriptors + values
/// ```
#[derive(Debug, Clone)]
pub struct BindExec2Message {
    /// Auto-commit mode (true = commit after execution).
    pub auto_commit: bool,
    /// Whether this query returns a result set (SELECT vs DML).
    pub has_result_set: bool,
    /// Pagination offset (0 = start from beginning).
    pub offset: i64,
    /// Maximum rows to return (0 = unlimited).
    pub max_rows: i64,
    /// Query timeout in seconds (0 = default).
    pub query_timeout: i32,
    /// Parameters to bind.
    pub params: Vec<BindParam>,
}

impl BindExec2Message {
    /// Create a new BIND_EXEC2 message.
    pub fn new(auto_commit: bool, has_result_set: bool, params: Vec<BindParam>) -> Self {
        Self {
            auto_commit,
            has_result_set,
            offset: 0,
            max_rows: 0,
            query_timeout: 0,
            params,
        }
    }

    /// Create with pagination.
    pub fn with_pagination(
        auto_commit: bool,
        has_result_set: bool,
        offset: i64,
        max_rows: i64,
        params: Vec<BindParam>,
    ) -> Self {
        Self {
            auto_commit,
            has_result_set,
            offset,
            max_rows,
            query_timeout: 0,
            params,
        }
    }

    /// Encode to payload bytes.
    pub fn encode_payload(&self) -> BytesMut {
        let mut buf = BytesMut::new();

        // Header
        buf.put_u8(if self.auto_commit { 1 } else { 0 });
        buf.put_u16_le(self.params.len() as u16);
        buf.put_u8(if self.has_result_set { 1 } else { 0 });

        // Pagination and execution options
        buf.put_i64_le(self.offset); // offset
        buf.put_i64_le(0); // cursor_update_row
        buf.put_i64_le(self.max_rows); // max_rows
        buf.put_u8(0); // flags
        buf.put_u8(0); // reserved
        buf.put_u8(0); // reserved
        buf.put_u8(0); // reserved
        buf.put_i32_le(self.query_timeout); // query_timeout
        buf.put_i32_le(0); // batch_allow_max_errors
        buf.put_u8(0); // innerExec
        buf.put_u8(0); // bind_options

        // Parameter descriptors
        for param in &self.params {
            buf.put_u8(param.direction as u8); // ioType
            buf.put_i32_le(param.type_code); // colType
            buf.put_i32_le(param.precision); // prec
            buf.put_i32_le(param.scale); // scale
        }

        // Parameter values
        for param in &self.params {
            match &param.value {
                None => {
                    // NULL marker: -1 as u16
                    buf.put_u16_le(0xFFFF);
                }
                Some(val) if val.len() > 0xFFFF => {
                    // Large data marker: -2 (0xFFFE) + 4-byte length + data
                    buf.put_u16_le(0xFFFE);
                    buf.put_u32_le(val.len() as u32);
                    buf.put_slice(val);
                }
                Some(val) => {
                    // Regular value: length + data
                    buf.put_u16_le(val.len() as u16);
                    buf.put_slice(val);
                }
            }
        }

        buf
    }
}

/// Client->Server STATEMENT_PREPARE message (type 3).
///
/// Allocates a new statement handle from the server.
/// Payload: 1 byte (readBaseColName flag, 1 = include base column names).
///
/// Response: statement ID at offset 0 of the response payload (u32 LE).
#[derive(Debug, Clone)]
pub struct StatementAllocateMessage {
    /// Whether to include base column names in responses.
    pub read_base_col_name: bool,
}

impl StatementAllocateMessage {
    /// Create with default settings.
    pub fn new() -> Self {
        Self {
            read_base_col_name: true,
        }
    }

    /// Encode to payload bytes.
    pub fn encode_payload(&self) -> BytesMut {
        let mut buf = BytesMut::new();
        buf.put_u8(if self.read_base_col_name { 1 } else { 0 });
        buf
    }

    /// Parse the statement ID from the response payload.
    pub fn parse_response(payload: &[u8]) -> Result<u32> {
        if payload.len() < 4 {
            return Err(crate::error::Error::Incomplete);
        }
        let stmt_id = u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]);
        Ok(stmt_id)
    }
}

/// Client->Server STATEMENT_FREE message (type 4).
///
/// Frees a previously allocated statement handle.
/// Payload: statement ID as u32 LE.
#[derive(Debug, Clone)]
pub struct StatementFreeMessage {
    /// Statement handle to free.
    pub stmt_id: u32,
}

impl StatementFreeMessage {
    /// Create to free the given statement.
    pub fn new(stmt_id: u32) -> Self {
        Self { stmt_id }
    }

    /// Encode to payload bytes.
    pub fn encode_payload(&self) -> BytesMut {
        let mut buf = BytesMut::new();
        buf.put_u32_le(self.stmt_id);
        buf
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- BindMessage tests ---

    #[test]
    fn test_bind_new() {
        let bind = BindMessage::new(true, vec![]);
        assert_eq!(bind.fetch_flag, 1);
        assert!(bind.params.is_empty());
    }

    #[test]
    fn test_bind_encode_with_param() {
        let params = vec![BindParam {
            type_name: "INT".to_string(),
            type_code: 4,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(vec![0xC8, 0x03, 0x00, 0x00]),
        }];
        let bind = BindMessage::new(true, params);
        let payload = bind.encode_payload();
        assert!(payload.len() > 30);
        let param_count = u16::from_le_bytes([payload[4], payload[5]]);
        assert_eq!(param_count, 1);
    }

    #[test]
    fn test_bind_encode_no_fetch() {
        let bind = BindMessage::new(false, vec![]);
        assert_eq!(bind.fetch_flag, 0);
        let payload = bind.encode_payload();
        assert_eq!(payload[0], 0);
    }

    #[test]
    fn test_bind_multiple_params() {
        let params = vec![
            BindParam {
                type_name: "INT".to_string(),
                type_code: 4,
                precision: 0,
                scale: 0,
                direction: ParameterDirection::Input,
                value: Some(vec![1, 0, 0, 0]),
            },
            BindParam {
                type_name: "VARCHAR".to_string(),
                type_code: 3,
                precision: 0,
                scale: 0,
                direction: ParameterDirection::Input,
                value: Some(b"test".to_vec()),
            },
        ];
        let bind = BindMessage::new(true, params);
        let payload = bind.encode_payload();
        assert_eq!(u16::from_le_bytes([payload[4], payload[5]]), 2);
    }

    #[test]
    fn test_bind_param_fields() {
        let param = BindParam {
            type_name: "BIGINT".to_string(),
            type_code: 5,
            precision: 19,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(vec![0; 8]),
        };
        assert_eq!(param.type_name, "BIGINT");
        assert_eq!(param.type_code, 5);
    }

    #[test]
    fn test_bind_encode_vchar_param() {
        let params = vec![BindParam {
            type_name: "VARCHAR".to_string(),
            type_code: 3,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: Some(b"BindTest".to_vec()),
        }];
        let bind = BindMessage::new(true, params);
        let payload = bind.encode_payload();
        assert!(payload.windows(8).any(|w| w == b"BindTest"));
    }

    // --- BindExec2Message tests ---

    #[test]
    fn test_bind_exec2_new() {
        let msg = BindExec2Message::new(true, true, vec![]);
        assert!(msg.auto_commit);
        assert!(msg.has_result_set);
        assert!(msg.params.is_empty());
    }

    #[test]
    fn test_bind_exec2_encode_header() {
        let msg = BindExec2Message::new(false, true, vec![]);
        let payload = msg.encode_payload();
        // Minimum header is 42 bytes
        assert!(payload.len() >= 42);
        assert_eq!(payload[0], 0); // auto_commit = false
        assert_eq!(payload[1], 0); // param_count low
        assert_eq!(payload[2], 0); // param_count high
        assert_eq!(payload[3], 1); // has_result_set = true
    }

    #[test]
    fn test_bind_exec2_encode_with_params() {
        let params = vec![
            BindParam {
                type_name: "INT".to_string(),
                type_code: 4,
                precision: 0,
                scale: 0,
                direction: ParameterDirection::Input,
                value: Some(42i32.to_le_bytes().to_vec()),
            },
            BindParam {
                type_name: "VARCHAR".to_string(),
                type_code: 3,
                precision: 0,
                scale: 0,
                direction: ParameterDirection::Input,
                value: Some(b"hello".to_vec()),
            },
        ];
        let msg = BindExec2Message::new(true, true, params);
        let payload = msg.encode_payload();
        // Header(42) + 2 descriptors(16 each) + values
        assert!(payload.len() > 42);
        // param_count at offset 1-2
        assert_eq!(u16::from_le_bytes([payload[1], payload[2]]), 2);
    }

    #[test]
    fn test_bind_exec2_null_param() {
        let params = vec![BindParam {
            type_name: "INT".to_string(),
            type_code: 4,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Input,
            value: None, // NULL
        }];
        let msg = BindExec2Message::new(true, false, params);
        let payload = msg.encode_payload();
        // After header(42) + descriptor(13) = 55, null marker should be 0xFFFF
        let null_marker_offset = 42 + 13; // descriptor = 1+4+4+4 = 13
        assert_eq!(
            u16::from_le_bytes([payload[null_marker_offset], payload[null_marker_offset + 1]]),
            0xFFFF
        );
    }

    #[test]
    fn test_bind_exec2_pagination() {
        let msg = BindExec2Message::with_pagination(true, true, 100, 50, vec![]);
        let payload = msg.encode_payload();
        // offset at bytes 4-11
        assert_eq!(
            i64::from_le_bytes([
                payload[4],
                payload[5],
                payload[6],
                payload[7],
                payload[8],
                payload[9],
                payload[10],
                payload[11]
            ]),
            100
        );
        // max_rows at bytes 20-27
        assert_eq!(
            i64::from_le_bytes([
                payload[20],
                payload[21],
                payload[22],
                payload[23],
                payload[24],
                payload[25],
                payload[26],
                payload[27]
            ]),
            50
        );
    }

    #[test]
    fn test_bind_exec2_output_param() {
        let params = vec![BindParam {
            type_name: "INT".to_string(),
            type_code: 4,
            precision: 0,
            scale: 0,
            direction: ParameterDirection::Output,
            value: None,
        }];
        let msg = BindExec2Message::new(true, false, params);
        let payload = msg.encode_payload();
        // ioType at offset 42 (after 42-byte header)
        assert_eq!(payload[42], 2); // Output = 2
    }

    // --- StatementAllocateMessage tests ---

    #[test]
    fn test_statement_allocate_new() {
        let msg = StatementAllocateMessage::new();
        assert!(msg.read_base_col_name);
    }

    #[test]
    fn test_statement_allocate_encode() {
        let msg = StatementAllocateMessage::new();
        let payload = msg.encode_payload();
        assert_eq!(payload.len(), 1);
        assert_eq!(payload[0], 1);
    }

    #[test]
    fn test_statement_allocate_encode_no_base_col() {
        let msg = StatementAllocateMessage {
            read_base_col_name: false,
        };
        let payload = msg.encode_payload();
        assert_eq!(payload[0], 0);
    }

    #[test]
    fn test_statement_allocate_parse_response() {
        let mut data = vec![0u8; 4];
        let stmt_id: u32 = 0x12345678;
        data.copy_from_slice(&stmt_id.to_le_bytes());
        assert_eq!(
            StatementAllocateMessage::parse_response(&data).unwrap(),
            stmt_id
        );
    }

    #[test]
    fn test_statement_allocate_parse_response_incomplete() {
        let data = vec![0u8; 3];
        let result = StatementAllocateMessage::parse_response(&data);
        assert!(matches!(result, Err(crate::error::Error::Incomplete)));
    }

    #[test]
    fn test_statement_allocate_parse_zero_id() {
        let data = vec![0u8; 32];
        assert_eq!(StatementAllocateMessage::parse_response(&data).unwrap(), 0);
    }

    // --- StatementFreeMessage tests ---

    #[test]
    fn test_statement_free_new() {
        let msg = StatementFreeMessage::new(42);
        assert_eq!(msg.stmt_id, 42);
    }

    #[test]
    fn test_statement_free_encode() {
        let msg = StatementFreeMessage::new(0xDEADBEEF);
        let payload = msg.encode_payload();
        assert_eq!(payload.len(), 4);
        assert_eq!(
            u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]),
            0xDEADBEEF
        );
    }

    #[test]
    fn test_statement_free_zero_id() {
        let msg = StatementFreeMessage::new(0);
        let payload = msg.encode_payload();
        assert_eq!(payload, vec![0u8; 4]);
    }

    // --- ParameterDirection tests ---

    #[test]
    fn test_parameter_direction_values() {
        assert_eq!(ParameterDirection::Input as u8, 1);
        assert_eq!(ParameterDirection::Output as u8, 2);
        assert_eq!(ParameterDirection::InputOutput as u8, 3);
    }
}
