//! LOBREAD protocol messages (msg_type=32).
//!
//! Reverse-engineered from the Go driver (dm_go/zq.go: dm_build_676 / dm_build_680).
//! Used to read out-of-row CLOB/BLOB data in chunks.
//!
//! ## Request format (LOBREAD, msg_type=32):
//!
//! | Field       | Type   | Size | Description                           |
//! |-------------|--------|------|---------------------------------------|
//! | lobFlag     | byte   | 1    | 0 = BLOB, 1 = CLOB                    |
//! | tabId       | i32 LE | 4    | Table ID from column metadata         |
//! | colId       | i16 LE | 2    | Column ID from column metadata        |
//! | blobId      | i64 LE | 8    | LOB identifier from NBLOB_HEAD        |
//! | groupId     | i16 LE | 2    | LOB storage group ID                  |
//! | fileId      | i16 LE | 2    | LOB storage file ID                   |
//! | pageNo      | i32 LE | 4    | LOB starting page number              |
//! | curFileId   | i16 LE | 2    | Current file ID (tracking cursor)     |
//! | curPageNo   | i32 LE | 4    | Current page number (tracking cursor) |
//! | totalOffset | i32 LE | 4    | Accumulated offset so far             |
//! | position    | i32 LE | 4    | Read start position (0-based)         |
//! | length      | i32 LE | 4    | Number of bytes/chars to read         |
//!
//! Extended section (if NewLobFlag is set on server):
//! | Field     | Type   | Size | Description               |
//! |-----------|--------|------|---------------------------|
//! | rowId     | i64 LE | 8    | Row ID from NBLOB_HEAD    |
//! | exGroupId | i16 LE | 2    | Extended group ID         |
//! | exFileId  | i16 LE | 2    | Extended file ID          |
//! | exPageNo  | i32 LE | 4    | Extended page number      |
//!
//! Total base payload: 41 bytes
//! Extended payload: 57 bytes

use bytes::{BufMut, BytesMut};
use dameng_types::LobLocator;

/// LOBREAD request message.
///
/// Encodes a request to read a chunk of LOB data from the server.
/// The server responds with the data chunk and updated cursor position.
#[derive(Debug, Clone)]
pub struct LobReadMessage {
    /// LOB locator containing all necessary metadata.
    locator: LobLocator,
    /// Read start position (0-based byte/character offset).
    position: i32,
    /// Number of bytes (BLOB) or characters (CLOB) to read.
    length: i32,
    /// Whether the server supports the extended LOB format (NewLobFlag).
    new_lob_flag: bool,
}

impl LobReadMessage {
    /// Create a new LOBREAD message.
    ///
    /// # Arguments
    /// * `locator` - The LOB locator from the query result
    /// * `position` - 0-based read offset
    /// * `length` - Number of bytes/chars to read
    /// * `new_lob_flag` - Whether server supports extended LOB format
    pub fn new(locator: LobLocator, position: i32, length: i32, new_lob_flag: bool) -> Self {
        Self {
            locator,
            position,
            length,
            new_lob_flag,
        }
    }

    /// Encode this message into a payload suitable for msg_type=32.
    pub fn encode_payload(&self) -> BytesMut {
        let mut buf = BytesMut::with_capacity(64);

        // lobFlag: 0 = BLOB, 1 = CLOB
        buf.put_u8(self.locator.lob_flag());

        // tabId (i32 LE)
        buf.put_i32_le(self.locator.tab_id);

        // colId (i16 LE)
        buf.put_i16_le(self.locator.col_id);

        // blobId (i64 LE)
        buf.put_i64_le(self.locator.blob_id());

        // groupId (i16 LE)
        buf.put_i16_le(self.locator.group_id());

        // fileId (i16 LE)
        buf.put_i16_le(self.locator.file_id());

        // pageNo (i32 LE)
        buf.put_i32_le(self.locator.page_no());

        // curFileId (i16 LE) — use cursor state for subsequent reads
        buf.put_i16_le(self.locator.cur_file_id);

        // curPageNo (i32 LE) — use cursor state for subsequent reads
        buf.put_i32_le(self.locator.cur_page_no);

        // totalOffset (i32 LE) — accumulated offset from cursor
        buf.put_i32_le(self.locator.total_offset);

        // position (i32 LE) — read start position
        buf.put_i32_le(self.position);

        // length (i32 LE) — bytes/chars to read
        buf.put_i32_le(self.length);

        // Extended section (if NewLobFlag)
        if self.new_lob_flag {
            // rowId (i64 LE)
            buf.put_i64_le(self.locator.row_id());

            // exGroupId (i16 LE)
            buf.put_i16_le(self.locator.ex_group_id());

            // exFileId (i16 LE)
            buf.put_i16_le(self.locator.ex_file_id());

            // exPageNo (i32 LE)
            buf.put_i32_le(self.locator.ex_page_no());
        }

        buf
    }
}

/// Response from a LOBREAD request.
///
/// Contains the data chunk and updated cursor state for subsequent reads.
#[derive(Debug, Clone)]
pub struct LobReadResponse {
    /// The LOB data chunk returned by the server.
    pub data: Vec<u8>,
    /// Character length for CLOB (actual UTF-8 char count). -1 if unknown.
    pub char_len: i64,
    /// True if there are no more bytes to read (EOF).
    pub read_over: bool,
    /// Updated current file ID (for subsequent reads).
    pub cur_file_id: i16,
    /// Updated current page number (for subsequent reads).
    pub cur_page_no: i32,
    /// Updated total offset (for subsequent reads).
    pub total_offset: i32,
}

impl LobReadResponse {
    /// Parse a LOBREAD response from raw payload bytes.
    ///
    /// Response format:
    /// - readOver (1 byte)
    /// - dataLen (i32 LE)
    /// - curFileId (i16 LE)
    /// - curPageNo (i32 LE)
    /// - totalOffset (i32 LE)
    /// - data (dataLen bytes)
    /// - [optional] charLen (i32 LE) if remaining bytes > 0
    pub fn from_bytes(data: &[u8]) -> crate::error::Result<Self> {
        if data.len() < 1 {
            return Err(crate::error::Error::Incomplete);
        }

        let mut offset = 0;

        // readOver (1 byte)
        let read_over = data[offset] == 1;
        offset += 1;

        // dataLen (i32 LE)
        if offset + 4 > data.len() {
            return Err(crate::error::Error::Incomplete);
        }
        let data_len = i32::from_le_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]);
        offset += 4;

        if data_len <= 0 {
            return Ok(Self {
                data: vec![],
                char_len: -1,
                read_over,
                cur_file_id: 0,
                cur_page_no: 0,
                total_offset: 0,
            });
        }

        // curFileId (i16 LE)
        if offset + 2 > data.len() {
            return Err(crate::error::Error::Incomplete);
        }
        let cur_file_id = i16::from_le_bytes([data[offset], data[offset + 1]]);
        offset += 2;

        // curPageNo (i32 LE)
        if offset + 4 > data.len() {
            return Err(crate::error::Error::Incomplete);
        }
        let cur_page_no = i32::from_le_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]);
        offset += 4;

        // totalOffset (i32 LE)
        if offset + 4 > data.len() {
            return Err(crate::error::Error::Incomplete);
        }
        let total_offset = i32::from_le_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]);
        offset += 4;

        // data (dataLen bytes)
        let data_len = data_len as usize;
        if offset + data_len > data.len() {
            return Err(crate::error::Error::Incomplete);
        }
        let response_data = data[offset..offset + data_len].to_vec();
        offset += data_len;

        // Optional: charLen (i32 LE) if there are remaining bytes
        let mut char_len: i64 = -1;
        if offset + 4 <= data.len() {
            // Check if there are extra bytes after data
            let remaining = data.len() - offset;
            if remaining >= 4 {
                char_len = i64::from(i32::from_le_bytes([
                    data[offset],
                    data[offset + 1],
                    data[offset + 2],
                    data[offset + 3],
                ]));
            }
        }

        Ok(Self {
            data: response_data,
            char_len,
            read_over,
            cur_file_id,
            cur_page_no,
            total_offset,
        })
    }
}

/// LOBFREE request message (msg_type=29).
///
/// Used to release a LOB locator on the server.
#[derive(Debug, Clone)]
pub struct LobFreeMessage {
    /// LOB locator to free.
    locator: LobLocator,
}

impl LobFreeMessage {
    /// Create a new LOBFREE message.
    pub fn new(locator: LobLocator) -> Self {
        Self { locator }
    }

    /// Encode this message into a payload.
    ///
    /// Format:
    /// - lobFlag (1 byte)
    /// - blobId (i64 LE)
    /// - groupId (i16 LE)
    /// - fileId (i16 LE)
    /// - pageNo (i32 LE)
    /// - [if NewLobFlag] tabId (i32 LE), colId (i16 LE), rowId (i64 LE),
    ///   exGroupId (i16 LE), exFileId (i16 LE), exPageNo (i32 LE)
    pub fn encode_payload(&self, new_lob_flag: bool) -> BytesMut {
        let mut buf = BytesMut::with_capacity(48);

        buf.put_u8(self.locator.lob_flag());
        buf.put_i64_le(self.locator.blob_id());
        buf.put_i16_le(self.locator.group_id());
        buf.put_i16_le(self.locator.file_id());
        buf.put_i32_le(self.locator.page_no());

        if new_lob_flag {
            buf.put_i32_le(self.locator.tab_id);
            buf.put_i16_le(self.locator.col_id);
            buf.put_i64_le(self.locator.row_id());
            buf.put_i16_le(self.locator.ex_group_id());
            buf.put_i16_le(self.locator.ex_file_id());
            buf.put_i32_le(self.locator.ex_page_no());
        }

        buf
    }
}

/// LOBGETLEN request message (msg_type=31).
///
/// Used to get the length of a LOB.
#[derive(Debug, Clone)]
pub struct LobGetLenMessage {
    /// LOB locator.
    locator: LobLocator,
}

impl LobGetLenMessage {
    /// Create a new LOBGETLEN message.
    pub fn new(locator: LobLocator) -> Self {
        Self { locator }
    }

    /// Encode this message.
    ///
    /// Format:
    /// - lobFlag (1 byte)
    /// - blobId (i64 LE)
    /// - groupId (i16 LE)
    /// - fileId (i16 LE)
    /// - pageNo (i32 LE)
    /// - tabId (i32 LE)
    /// - colId (i16 LE)
    /// - rowId (i64 LE)
    /// - [if NewLobFlag] exGroupId (i16 LE), exFileId (i16 LE), exPageNo (i32 LE)
    pub fn encode_payload(&self, new_lob_flag: bool) -> BytesMut {
        let mut buf = BytesMut::with_capacity(48);

        buf.put_u8(self.locator.lob_flag());
        buf.put_i64_le(self.locator.blob_id());
        buf.put_i16_le(self.locator.group_id());
        buf.put_i16_le(self.locator.file_id());
        buf.put_i32_le(self.locator.page_no());
        buf.put_i32_le(self.locator.tab_id);
        buf.put_i16_le(self.locator.col_id);
        buf.put_i64_le(self.locator.row_id());

        if new_lob_flag {
            buf.put_i16_le(self.locator.ex_group_id());
            buf.put_i16_le(self.locator.ex_file_id());
            buf.put_i32_le(self.locator.ex_page_no());
        }

        buf
    }
}

/// Response from a LOBGETLEN request.
#[derive(Debug, Clone)]
pub struct LobGetLenResponse {
    /// Length in bytes (BLOB) or characters (CLOB).
    pub length: i64,
    /// New blob ID from server (if server updated it).
    /// Used to refresh the locator for subsequent reads.
    pub new_blob_id: Option<i64>,
}

impl LobGetLenResponse {
    /// Parse LOBGETLEN response from raw payload.
    ///
    /// Response format (matching Go driver dm_build_714.dm_build_425):
    /// - length (i32 LE) — LOB length
    /// - newBlobId (i64 LE) — updated blob ID from server (DDWORD)
    pub fn from_bytes(data: &[u8]) -> crate::error::Result<Self> {
        if data.len() < 4 {
            return Err(crate::error::Error::Incomplete);
        }
        let length = i64::from(i32::from_le_bytes([data[0], data[1], data[2], data[3]]));

        // Parse newBlobId (DDWORD = i64 LE) if available
        let new_blob_id = if data.len() >= 12 {
            let blob_id = i64::from_le_bytes([
                data[4], data[5], data[6], data[7], data[8], data[9], data[10], data[11],
            ]);
            Some(blob_id)
        } else {
            None
        };

        Ok(Self {
            length,
            new_blob_id,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_locator() -> LobLocator {
        // Build a minimal NBLOB_HEAD with in_row=0x02
        let mut raw = vec![0u8; 43];
        raw[0] = 0x02; // in_row = out-of-row
                       // blob_id at offset 1
        raw[1..9].copy_from_slice(&42i64.to_le_bytes());
        // group_id at offset 13
        raw[13..15].copy_from_slice(&1i16.to_le_bytes());
        // file_id at offset 15
        raw[15..17].copy_from_slice(&2i16.to_le_bytes());
        // page_no at offset 17
        raw[17..21].copy_from_slice(&100i32.to_le_bytes());
        // tab_id at offset 21
        raw[21..25].copy_from_slice(&1000i32.to_le_bytes());
        // col_id at offset 25
        raw[25..27].copy_from_slice(&3i16.to_le_bytes());
        // row_id at offset 27
        raw[27..35].copy_from_slice(&999i64.to_le_bytes());
        // exGroupId at offset 35
        raw[35..37].copy_from_slice(&5i16.to_le_bytes());
        // exFileId at offset 37
        raw[37..39].copy_from_slice(&6i16.to_le_bytes());
        // exPageNo at offset 39
        raw[39..43].copy_from_slice(&200i32.to_le_bytes());

        LobLocator::from_nblob_head(raw, true)
    }

    #[test]
    fn test_lob_locator_parsing() {
        let mut loc = make_test_locator();
        assert_eq!(loc.blob_id(), 42);
        assert_eq!(loc.group_id(), 1);
        assert_eq!(loc.file_id(), 2);
        assert_eq!(loc.page_no(), 100);
        assert_eq!(loc.tab_id, 1000);
        assert_eq!(loc.col_id, 3);
        assert_eq!(loc.row_id(), 999);
        assert_eq!(loc.ex_group_id(), 5);
        assert_eq!(loc.ex_file_id(), 6);
        assert_eq!(loc.ex_page_no(), 200);
        assert!(loc.has_extended());
        assert!(loc.is_clob);
        assert_eq!(loc.lob_flag(), 1);
        // Cursor starts at 0
        assert_eq!(loc.cur_file_id, 0);
        assert_eq!(loc.cur_page_no, 0);
        assert_eq!(loc.total_offset, 0);
        // After init_cursor(), cursor = file_id/page_no
        loc.init_cursor();
        assert_eq!(loc.cur_file_id, 2);
        assert_eq!(loc.cur_page_no, 100);
        assert_eq!(loc.total_offset, 0);
    }

    #[test]
    fn test_lob_read_encode() {
        let mut loc = make_test_locator();
        loc.init_cursor();
        let msg = LobReadMessage::new(loc, 0, 1024, true);
        let payload = msg.encode_payload();
        // Base (41) + extended (16) = 57 bytes
        assert_eq!(payload.len(), 57);
        // First byte is lobFlag
        assert_eq!(payload[0], 1); // CLOB
    }

    #[test]
    fn test_lob_read_encode_no_extended() {
        let loc = make_test_locator();
        let msg = LobReadMessage::new(loc, 100, 512, false);
        let payload = msg.encode_payload();
        assert_eq!(payload.len(), 41);
    }

    #[test]
    fn test_lob_read_response_parse() {
        // Build a minimal LOBREAD response:
        // readOver=0, dataLen=5, curFileId=2, curPageNo=101, totalOffset=5, data="HELLO"
        let mut resp_data = vec![0u8; 25];
        resp_data[0] = 0; // readOver = false
        resp_data[1..5].copy_from_slice(&5i32.to_le_bytes()); // dataLen
        resp_data[5..7].copy_from_slice(&2i16.to_le_bytes()); // curFileId
        resp_data[7..11].copy_from_slice(&101i32.to_le_bytes()); // curPageNo
        resp_data[11..15].copy_from_slice(&5i32.to_le_bytes()); // totalOffset
        resp_data[15..20].copy_from_slice(b"HELLO");
        let resp = LobReadResponse::from_bytes(&resp_data).unwrap();
        assert!(!resp.read_over);
        assert_eq!(resp.data, b"HELLO");
        assert_eq!(resp.cur_file_id, 2);
        assert_eq!(resp.cur_page_no, 101);
        assert_eq!(resp.total_offset, 5);
    }

    #[test]
    fn test_lob_read_response_eof() {
        // readOver=1, dataLen=0
        let resp_data = vec![1u8, 0, 0, 0, 0];
        let resp = LobReadResponse::from_bytes(&resp_data).unwrap();
        assert!(resp.read_over);
        assert!(resp.data.is_empty());
    }

    #[test]
    fn test_lob_cursor_update() {
        let mut loc = make_test_locator();
        loc.init_cursor();
        assert_eq!(loc.cur_file_id, 2);
        assert_eq!(loc.cur_page_no, 100);

        // Simulate response from first LOBREAD
        loc.update_cursor(2, 101, 1024);
        assert_eq!(loc.cur_file_id, 2);
        assert_eq!(loc.cur_page_no, 101);
        assert_eq!(loc.total_offset, 1024);

        // Simulate response from second LOBREAD
        loc.update_cursor(3, 200, 2048);
        assert_eq!(loc.cur_file_id, 3);
        assert_eq!(loc.cur_page_no, 200);
        assert_eq!(loc.total_offset, 2048);
    }

    #[test]
    fn test_lob_free_encode() {
        let loc = make_test_locator();
        let free_msg = LobFreeMessage::new(loc);
        let payload = free_msg.encode_payload(true);
        // lobFlag(1) + blobId(8) + groupId(2) + fileId(2) + pageNo(4) = 17
        // + tabId(4) + colId(2) + rowId(8) + exGroupId(2) + exFileId(2) + exPageNo(4) = 22
        // Total = 39
        assert_eq!(payload.len(), 39);
        assert_eq!(payload[0], 1); // CLOB
    }

    #[test]
    fn test_lob_free_encode_no_extended() {
        let loc = make_test_locator();
        let free_msg = LobFreeMessage::new(loc);
        let payload = free_msg.encode_payload(false);
        // lobFlag(1) + blobId(8) + groupId(2) + fileId(2) + pageNo(4) = 17
        assert_eq!(payload.len(), 17);
    }

    #[test]
    fn test_lob_getlen_encode() {
        let loc = make_test_locator();
        let getlen_msg = LobGetLenMessage::new(loc);
        let payload = getlen_msg.encode_payload(true);
        // lobFlag(1) + blobId(8) + groupId(2) + fileId(2) + pageNo(4) + tabId(4) + colId(2) + rowId(8) = 31
        // + exGroupId(2) + exFileId(2) + exPageNo(4) = 8
        // Total = 39
        assert_eq!(payload.len(), 39);
    }

    #[test]
    fn test_lob_getlen_response_parse() {
        let resp_data = 2048i32.to_le_bytes();
        let resp = LobGetLenResponse::from_bytes(&resp_data).unwrap();
        assert_eq!(resp.length, 2048);
    }

    #[test]
    fn test_lob_read_response_with_char_len() {
        // readOver=0, dataLen=5, curFileId=2, curPageNo=101, totalOffset=5, data="HELLO", charLen=5
        let mut resp_data = vec![0u8; 29];
        resp_data[0] = 0; // readOver = false
        resp_data[1..5].copy_from_slice(&5i32.to_le_bytes()); // dataLen
        resp_data[5..7].copy_from_slice(&2i16.to_le_bytes()); // curFileId
        resp_data[7..11].copy_from_slice(&101i32.to_le_bytes()); // curPageNo
        resp_data[11..15].copy_from_slice(&5i32.to_le_bytes()); // totalOffset
        resp_data[15..20].copy_from_slice(b"HELLO");
        resp_data[20..24].copy_from_slice(&5i32.to_le_bytes()); // charLen
        let resp = LobReadResponse::from_bytes(&resp_data).unwrap();
        assert!(!resp.read_over);
        assert_eq!(resp.data, b"HELLO");
        assert_eq!(resp.char_len, 5);
    }
}
