//! FETCH message (type 7) for retrieving more rows from a result set.
//!
//! Based on Go driver wire format. The FETCH request uses absolute row positions
//! — the client specifies which row to start from, and the server returns a batch
//! of rows up to a byte budget.
//!
//! Request wire format (after 64-byte Frame header):
//! ```text
//! Offset  Size  Field
//! 0       20    Reserved (zeros)
//! 20      8     startRow (i64 LE) — starting row index (absolute, 0-based)
//! 28      8     endRow   (i64 LE) — ending row index (use i64::MAX for all remaining)
//! 36      2     cursorId (i16 LE) — result set cursor ID
//! 38      4     prefetchBytes (i32 LE) — max bytes to fetch, clamped [32, 65536]
//! ```
//!
//! Response wire format:
//! ```text
//! Offset  Size  Field
//! 0       20    Reserved
//! 20      8     updateCount (i64 LE) — total row count in result set
//! 28      4     rsSizeof    (i32 LE) — byte size of row data
//! 32      N     row data (same format as EXEC_RESPONSE inline rows)
//! ```

use bytes::{BufMut, BytesMut};

use crate::error::Result;
use dameng_types::encoding::ServerEncoding;

use super::response::{Column, ExecResponse, Row};

/// Default prefetch byte budget for FETCH requests.
pub const DEFAULT_PREFETCH_BYTES: i32 = 8192;

/// Minimum prefetch byte budget.
pub const MIN_PREFETCH_BYTES: i32 = 32;

/// Maximum prefetch byte budget.
pub const MAX_PREFETCH_BYTES: i32 = 65536;

/// Client->Server FETCH message (type 7).
///
/// Requests the next batch of rows from a previously executed query.
/// Uses absolute row positioning — `start_row` specifies which row to begin
/// fetching from, and the server returns up to `prefetch_bytes` of row data.
#[derive(Debug, Clone)]
pub struct FetchMessage {
    /// Starting row index (absolute, 0-based).
    pub start_row: i64,
    /// Ending row index (use i64::MAX to fetch all remaining).
    pub end_row: i64,
    /// Result set cursor ID.
    pub cursor_id: i16,
    /// Maximum bytes to fetch (clamped to [32, 65536]).
    pub prefetch_bytes: i32,
}

impl FetchMessage {
    /// Create a new fetch message.
    ///
    /// # Arguments
    /// * `start_row` — The row index to start fetching from (0-based, absolute).
    /// * `cursor_id` — The result set cursor ID from the initial query.
    /// * `prefetch_bytes` — The maximum bytes to fetch (clamped to [32, 65536]).
    pub fn new(start_row: i64, cursor_id: i16, prefetch_bytes: i32) -> Self {
        let clamped = prefetch_bytes.clamp(MIN_PREFETCH_BYTES, MAX_PREFETCH_BYTES);
        Self {
            start_row,
            end_row: i64::MAX, // Fetch all remaining rows
            cursor_id,
            prefetch_bytes: clamped,
        }
    }

    /// Create a new fetch message requesting from the given row, fetching all remaining.
    ///
    /// This is the most common case — fetch from a specific row position to the end.
    pub fn fetch_from(start_row: i64, cursor_id: i16) -> Self {
        Self::new(start_row, cursor_id, DEFAULT_PREFETCH_BYTES)
    }

    /// Encode to payload bytes.
    ///
    /// Wire format:
    /// - 20 bytes reserved (zeros)
    /// - startRow (i64 LE)
    /// - endRow (i64 LE)
    /// - cursorId (i16 LE)
    /// - prefetchBytes (i32 LE)
    pub fn encode_payload(&self) -> BytesMut {
        let mut buf = BytesMut::with_capacity(42);
        // 20 bytes reserved
        buf.put_bytes(0, 20);
        // startRow (i64 LE)
        buf.put_i64_le(self.start_row);
        // endRow (i64 LE)
        buf.put_i64_le(self.end_row);
        // cursorId (i16 LE)
        buf.put_i16_le(self.cursor_id);
        // prefetchBytes (i32 LE)
        buf.put_i32_le(self.prefetch_bytes);
        buf
    }
}

/// Response from a FETCH request (msg_type=7).
#[derive(Debug, Clone)]
pub struct FetchResponse {
    /// Total number of rows in the entire result set.
    pub total_row_count: i64,
    /// Column metadata (may be empty if already known from initial query).
    pub columns: Vec<Column>,
    /// Row data fetched in this batch.
    pub rows: Vec<Row>,
}

impl FetchResponse {
    /// Parse a FETCH response from raw payload bytes.
    ///
    /// Response format:
    /// - Offset 0-19: reserved
    /// - Offset 20-27: updateCount (i64 LE) — total row count
    /// - Offset 28-31: rsSizeof (i32 LE) — byte size of row data
    /// - Offset 32+: row data (same format as EXEC_RESPONSE inline rows)
    pub fn from_bytes(data: &[u8], server_encoding: ServerEncoding) -> Result<Self> {
        if data.len() < 32 {
            return Err(crate::error::Error::Incomplete);
        }

        // updateCount at offset 20
        let total_row_count = i64::from_le_bytes([
            data[20], data[21], data[22], data[23], data[24], data[25], data[26], data[27],
        ]);

        // rsSizeof at offset 28
        let rs_sizeof = if data.len() >= 32 {
            i32::from_le_bytes([data[28], data[29], data[30], data[31]]) as usize
        } else {
            0
        };

        // Row data starts at offset 32
        let row_data_start = 32;
        let row_data_end = (row_data_start + rs_sizeof).min(data.len());

        if row_data_start >= data.len() || rs_sizeof == 0 {
            return Ok(FetchResponse {
                total_row_count,
                columns: vec![],
                rows: vec![],
            });
        }

        let row_data = &data[row_data_start..row_data_end];

        // The row data follows the same inline format as EXEC_RESPONSE.
        // Parse it using the ExecResponse parser.
        // Guard against parsing garbage: if row_data is all zeros or too short,
        // the server returned metadata only (no inline data).
        let has_real_data =
            row_data.len() > 16 && !row_data.iter().all(|&b| b == 0) && row_data[0] != 0;

        if !has_real_data {
            // Server returned a cursor/total count but no inline row data.
            // This happens when the cursor_id is invalid or the result is empty.
            return Ok(FetchResponse {
                total_row_count,
                columns: vec![],
                rows: vec![],
            });
        }

        match ExecResponse::from_bytes(row_data, server_encoding) {
            Ok(resp) => Ok(FetchResponse {
                total_row_count,
                columns: resp.columns,
                rows: resp.rows,
            }),
            Err(_) => {
                // If we can't parse the row data as EXEC_RESPONSE format,
                // return what we have with empty rows.
                Ok(FetchResponse {
                    total_row_count,
                    columns: vec![],
                    rows: vec![],
                })
            }
        }
    }

    /// Check if there are more rows to fetch.
    pub fn has_more(&self, current_pos: usize) -> bool {
        current_pos < self.total_row_count as usize
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fetch_new() {
        let fetch = FetchMessage::new(0, 0, DEFAULT_PREFETCH_BYTES);
        assert_eq!(fetch.start_row, 0);
        assert_eq!(fetch.end_row, i64::MAX);
        assert_eq!(fetch.cursor_id, 0);
        assert_eq!(fetch.prefetch_bytes, DEFAULT_PREFETCH_BYTES);
    }

    #[test]
    fn test_fetch_payload_size() {
        let fetch = FetchMessage::new(100, 1, 4096);
        let payload = fetch.encode_payload();
        assert_eq!(payload.len(), 42); // 20 + 8 + 8 + 2 + 4
    }

    #[test]
    fn test_fetch_encode_decode() {
        let fetch = FetchMessage::new(42, 5, 8192);
        let payload = fetch.encode_payload();

        // Verify reserved bytes
        assert!(payload[..20].iter().all(|&b| b == 0));

        // Verify startRow at offset 20
        let start_row = i64::from_le_bytes([
            payload[20],
            payload[21],
            payload[22],
            payload[23],
            payload[24],
            payload[25],
            payload[26],
            payload[27],
        ]);
        assert_eq!(start_row, 42);

        // Verify endRow at offset 28
        let end_row = i64::from_le_bytes([
            payload[28],
            payload[29],
            payload[30],
            payload[31],
            payload[32],
            payload[33],
            payload[34],
            payload[35],
        ]);
        assert_eq!(end_row, i64::MAX);

        // Verify cursorId at offset 36
        let cursor_id = i16::from_le_bytes([payload[36], payload[37]]);
        assert_eq!(cursor_id, 5);

        // Verify prefetchBytes at offset 38
        let prefetch_bytes =
            i32::from_le_bytes([payload[38], payload[39], payload[40], payload[41]]);
        assert_eq!(prefetch_bytes, 8192);
    }

    #[test]
    fn test_fetch_prefetch_clamp_min() {
        let fetch = FetchMessage::new(0, 0, 1);
        assert_eq!(fetch.prefetch_bytes, MIN_PREFETCH_BYTES);
    }

    #[test]
    fn test_fetch_prefetch_clamp_max() {
        let fetch = FetchMessage::new(0, 0, i32::MAX);
        assert_eq!(fetch.prefetch_bytes, MAX_PREFETCH_BYTES);
    }

    #[test]
    fn test_fetch_prefetch_normal() {
        let fetch = FetchMessage::new(0, 0, 4096);
        assert_eq!(fetch.prefetch_bytes, 4096);
    }

    #[test]
    fn test_fetch_from() {
        let fetch = FetchMessage::fetch_from(50, 3);
        assert_eq!(fetch.start_row, 50);
        assert_eq!(fetch.cursor_id, 3);
        assert_eq!(fetch.prefetch_bytes, DEFAULT_PREFETCH_BYTES);
    }

    #[test]
    fn test_fetch_response_incomplete() {
        let data = [0u8; 10];
        let result = FetchResponse::from_bytes(&data, ServerEncoding::Utf8);
        assert!(result.is_err());
    }

    #[test]
    fn test_fetch_response_empty_data() {
        let data = vec![0u8; 42];
        let resp = FetchResponse::from_bytes(&data, ServerEncoding::Utf8).unwrap();
        assert_eq!(resp.total_row_count, 0);
        assert!(resp.rows.is_empty());
    }

    #[test]
    fn test_fetch_clone() {
        let fetch = FetchMessage::new(100, 2, 4096);
        let cloned = fetch.clone();
        assert_eq!(cloned.start_row, 100);
        assert_eq!(cloned.cursor_id, 2);
        assert_eq!(cloned.prefetch_bytes, 4096);
    }

    #[test]
    fn test_has_more() {
        let resp = FetchResponse {
            total_row_count: 1000,
            columns: vec![],
            rows: vec![],
        };
        assert!(resp.has_more(0));
        assert!(resp.has_more(999));
        assert!(!resp.has_more(1000));
    }
}
