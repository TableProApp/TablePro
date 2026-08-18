//! EXEC_RESPONSE (type 0 / 187) - Statement execution results.
//!
//! Format verified against DM 8.1.3.62 live traffic.
//! Used for both EXEC (type 5) and OPTIMIZED_PREPARE_EXEC (type 91) responses.
//!
//! === FIXED HEADER (16 bytes) ===
//!   0  u32  sub_type (2 for V$VERSION, 7 for SELECT, etc.)
//!   4  u32  flags (usually 4)
//!   8  u32  reserved (0)
//!  12  u32  row_count_in_response
//!
//! === FIRST COLUMN HEADER (16 bytes, offset 16) ===
//!  16  u32  col_type (type code for first column)
//!  20  u16  nullable
//!  22  u16  col_count (total number of columns)
//!  24  u16  col_name_len (length of first column name)
//!  26  u16  type_name_len
//!  28  u16  table_name_len
//!  30  u16  schema_name_len
//!
//! === COLUMN VARIABLE DATA ===
//! First column strings (explicit lengths from header fields):
//!   col_name (col_name_len bytes)
//!   type_name (type_name_len bytes)
//!   table_name (table_name_len bytes, if > 0)
//!   schema_name (schema_name_len bytes, if > 0)
//!   null_terminator (1 byte, 0x00)
//!
//! For each subsequent column N (N > 1):
//!   Between-columns metadata (12 bytes): nullable_flags(u32) + precision(u32) + reserved(u32)
//!   Column N header (19 bytes):
//!     col_type(u32) + nullable(u16) + display(u16) + reserved(u8) + col_index(u8)
//!     + col_name_len(u16) + type_name_len(u16) + table_name_len(u16) + schema_name_len(u16) + padding(u8)
//!   Column N strings:
//!     padding(u8) + col_name + type_name + table_name + schema_name + terminator(u8)
//!
//! === OPE INLINE ROW DATA (for OPTIMIZED_PREPARE_EXEC type 91) ===
//! After all column metadata, rows are embedded inline:
//!   u8  row_size_marker (total bytes for this row including marker)
//!   u8  flags
//!   u32 rec_id
//!   u32 padding (0)
//!   For each column: u16 col_offset_from_marker
//!   For each column: u16 value_size + value_size bytes of data

use crate::error::Result;
use dameng_types::encoding::{decode_from_server, ServerEncoding};

/// LOB_LOCATOR size: DM returns a 16-byte locator for large CLOB/BLOB values.
/// When the value size exceeds 2048 bytes, DM returns a locator instead of inline data.
/// The client must use LOBREAD/FETCH operations to retrieve the actual content.
pub const LOB_LOCATOR_SIZE: usize = 16;

/// Maximum inline data size before DM uses LOB_LOCATOR.
pub const LOB_LOCATOR_THRESHOLD: usize = 2048;

/// Check if the given raw data is a LOB_LOCATOR (16 bytes) for the specified column type.
/// DM uses LOB_LOCATOR for CLOB/BLOB values larger than 2048 bytes.
pub fn is_lob_locator(data: &[u8], col_type_code: i32) -> bool {
    let is_lob_type = matches!(col_type_code, 13 | 14); // BLOB=13, CLOB=14
    is_lob_type && data.len() == LOB_LOCATOR_SIZE
}

/// Check if the given raw data is an NBLOB_HEAD structure for the specified column type.
/// DM returns NBLOB_HEAD for ALL CLOB/BLOB values (both inline and out-of-row).
/// - in_row=0x01: inline data follows the header (13 bytes header + data)
/// - in_row=0x02: out-of-row LOB (25+ bytes header, needs LOBREAD protocol)
pub fn is_lob_head(data: &[u8], col_type_code: i32) -> bool {
    let is_lob_type = matches!(col_type_code, 13 | 14);
    is_lob_type && data.len() >= 13
}

use dameng_types::{DmValue, DmValueType};

/// Derive type_code from type_name string.
/// The column header type_code field (offset 16) is unreliable on DM 8.1 — it
/// often returns 4 (INT) for all types. type_name is the authoritative source.
fn type_name_to_code(name: &str) -> i32 {
    let upper = name.to_uppercase();
    // Check timezone variants first (longer match before shorter)
    if upper.contains("TIMESTAMP WITH TIME ZONE")
        || upper.contains("DATETIME WITH TIME ZONE")
        || upper.contains("DATETIME2_TZ")
    {
        12 // TIMESTAMP_TZ maps to TIMESTAMP (12)
    } else if upper.contains("TIME WITH TIME ZONE") {
        11 // TIME_TZ maps to TIME (11)
    } else if upper.contains("INTERVAL DAY")
        || upper.contains("INTERVAL_DS")
        || upper.contains("NUMTODSINTERVAL")
    {
        15 // INTERVAL_DT
    } else if upper.contains("INTERVAL YEAR")
        || upper.contains("INTERVAL_YM")
        || upper.contains("NUMTOYMINTERVAL")
    {
        15 // INTERVAL_YM
    } else {
        match upper.as_str() {
            "BIT" | "BOOLEAN" => 1,
            "TINYINT" => 2,
            "VARCHAR" | "CHAR" | "BANNECHAR" | "VARCHAR2" | "NVARCHAR" | "NVARCHAR2" => 3,
            "INT" | "INTEGER" | "NUMBER" => 4,
            "BIGINT" | "LONG" => 5,
            "SMALLINT" => 6,
            "FLOAT" => 7,
            "DOUBLE" | "DOUBLE PRECISION" => 8,
            "DEC" | "DECIMAL" | "NUMERIC" => 9,
            "DATE" => 10,
            "TIME" => 11,
            "TIMESTAMP" | "DATETIME" | "DATETIME2" => 12,
            "BLOB" | "RAW" | "LONG RAW" => 13,
            "CLOB" | "NCLOB" | "TEXT" => 14,
            "INTERVAL" => 15,
            "BINARY" | "VARBINARY" => 17,
            "ROWID" => 18,
            "XMLTYPE" => 14, // XML stored as CLOB-like
            _ => 0,
        }
    }
}

/// Column metadata from a query result.
#[derive(Debug, Clone)]
pub struct Column {
    /// Column name.
    pub name: String,
    /// DM type code.
    pub type_code: i32,
    /// Type name string (e.g., "INT", "VARCHAR").
    pub type_name: String,
    /// Precision for numeric types.
    pub precision: u32,
    /// Scale for decimal types.
    pub scale: i16,
    /// Whether the column can be NULL.
    pub nullable: bool,
    /// Display size.
    pub display_size: u32,
    /// Table name.
    pub table_name: String,
    /// Schema name.
    pub schema_name: String,
    /// LOB tab_id (only set for BLOB/CLOB columns).
    pub lob_tab_id: i32,
    /// LOB col_id (only set for BLOB/CLOB columns).
    pub lob_col_id: i16,
}

/// A single row of data from a query result.
#[derive(Debug, Clone)]
pub struct Row {
    /// Row ID from the database.
    pub row_id: u16,
    /// Column values as raw bytes.
    pub values: Vec<Option<Vec<u8>>>,
}

impl Row {
    /// Get an i32 value at the given column index.
    pub fn get_i32(&self, idx: usize) -> Result<i32> {
        let val = self.values.get(idx).and_then(|v| v.as_ref()).ok_or(
            crate::error::Error::DecodeError(format!("column {} is NULL or out of range", idx)),
        )?;
        if val.len() < 4 {
            if val.len() == 1 {
                return Ok(val[0] as i32);
            }
            if val.len() == 2 {
                return Ok(i32::from(i16::from_le_bytes([val[0], val[1]])));
            }
            return Err(crate::error::Error::DecodeError(format!(
                "column {} too short for i32 ({} bytes)",
                idx,
                val.len()
            )));
        }
        Ok(i32::from_le_bytes([val[0], val[1], val[2], val[3]]))
    }

    /// Get an i64 value at the given column index.
    pub fn get_i64(&self, idx: usize) -> Result<i64> {
        let val = self.values.get(idx).and_then(|v| v.as_ref()).ok_or(
            crate::error::Error::DecodeError(format!("column {} is NULL or out of range", idx)),
        )?;
        if val.len() < 8 {
            if val.len() >= 4 {
                return Ok(i64::from(i32::from_le_bytes([
                    val[0], val[1], val[2], val[3],
                ])));
            }
            return Err(crate::error::Error::DecodeError(format!(
                "column {} too short for i64",
                idx
            )));
        }
        Ok(i64::from_le_bytes([
            val[0], val[1], val[2], val[3], val[4], val[5], val[6], val[7],
        ]))
    }

    /// Get a &str value at the given column index.
    ///
    /// For text types (VARCHAR, CHAR, CLOB) this reads UTF-8 directly.
    pub fn get_str(&self, idx: usize) -> Result<&str> {
        let val = self.values.get(idx).and_then(|v| v.as_ref()).ok_or(
            crate::error::Error::DecodeError(format!("column {} is NULL or out of range", idx)),
        )?;
        std::str::from_utf8(val)
            .map_err(|e| crate::error::Error::DecodeError(format!("invalid UTF-8: {}", e)))
    }

    /// Get a f64 value at the given column index.
    pub fn get_f64(&self, idx: usize) -> Result<f64> {
        let val = self.values.get(idx).and_then(|v| v.as_ref()).ok_or(
            crate::error::Error::DecodeError(format!("column {} is NULL or out of range", idx)),
        )?;
        if val.len() < 8 {
            return Err(crate::error::Error::DecodeError(format!(
                "column {} too short for f64",
                idx
            )));
        }
        let bytes: [u8; 8] = val[..8].try_into().unwrap();
        Ok(f64::from_le_bytes(bytes))
    }

    /// Check if the value at the given column index is NULL.
    pub fn is_null(&self, idx: usize) -> bool {
        match self.values.get(idx) {
            None | Some(None) => true,
            Some(Some(v)) => v.is_empty(),
        }
    }

    /// Get a TIMESTAMP value at the given column index as a human-readable string.
    ///
    /// DM encodes TIMESTAMP as 11 bytes: year(2 BE) + month(1) + day(1) + hour(1) + minute(1) + second(1) + nanosecond(4 BE).
    /// Falls back to UTF-8/lossy if the data doesn't match binary format.
    pub fn get_timestamp(&self, idx: usize) -> Result<String> {
        let val = self.values.get(idx).and_then(|v| v.as_ref()).ok_or(
            crate::error::Error::DecodeError(format!("column {} is NULL or out of range", idx)),
        )?;

        if val.len() == 11 {
            let year = u16::from_be_bytes([val[0], val[1]]) as i32;
            let month = val[2];
            let day = val[3];
            let hour = val[4];
            let minute = val[5];
            let second = val[6];
            let nano = u32::from_be_bytes([val[7], val[8], val[9], val[10]]);
            if nano > 0 {
                Ok(format!(
                    "{}-{:02}-{:02} {:02}:{:02}:{:02}.{:09}",
                    year, month, day, hour, minute, second, nano
                ))
            } else {
                Ok(format!(
                    "{}-{:02}-{:02} {:02}:{:02}:{:02}",
                    year, month, day, hour, minute, second
                ))
            }
        } else if val.len() == 7 {
            // DATE format: year(2 BE) + month(1) + day(1) + hour(1) + minute(1) + second(1)
            let year = u16::from_be_bytes([val[0], val[1]]) as i32;
            let month = val[2];
            let day = val[3];
            let hour = val[4];
            let minute = val[5];
            let second = val[6];
            Ok(format!(
                "{}-{:02}-{:02} {:02}:{:02}:{:02}",
                year, month, day, hour, minute, second
            ))
        } else {
            // Fallback: UTF-8 or lossy via get_string
            self.get_string(idx)
        }
    }

    /// Get a DATE value at the given column index as a human-readable string.
    pub fn get_date(&self, idx: usize) -> Result<String> {
        let val = self.values.get(idx).and_then(|v| v.as_ref()).ok_or(
            crate::error::Error::DecodeError(format!("column {} is NULL or out of range", idx)),
        )?;

        if val.len() == 7 {
            let year = u16::from_be_bytes([val[0], val[1]]) as i32;
            let month = val[2];
            let day = val[3];
            let hour = val[4];
            let minute = val[5];
            let second = val[6];
            Ok(format!(
                "{}-{:02}-{:02} {:02}:{:02}:{:02}",
                year, month, day, hour, minute, second
            ))
        } else {
            self.get_string(idx)
        }
    }

    /// Get the number of columns in this row.
    pub fn len(&self) -> usize {
        self.values.len()
    }

    /// Check if the row has no columns.
    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }

    /// Get a decoded DmValue at the given column index.
    /// Uses the column type_code to decode the raw bytes.
    pub fn get(&self, idx: usize, columns: &[Column]) -> Option<DmValue> {
        let data = self.values.get(idx)?.as_ref()?;
        if data.is_empty() {
            return Some(DmValue::Null);
        }
        let col = columns.get(idx)?;
        let dm_ty = DmValueType::from_type_code(col.type_code)?;
        dameng_types::decode_value(
            dm_ty,
            data,
            matches!(dm_ty, DmValueType::BLOB | DmValueType::CLOB)
                .then_some((col.lob_tab_id, col.lob_col_id)),
        )
    }

    /// Get an i16 value at the given column index.
    pub fn get_i16(&self, idx: usize) -> Result<i16> {
        let val = self.values.get(idx).and_then(|v| v.as_ref()).ok_or(
            crate::error::Error::DecodeError(format!("column {} is NULL or out of range", idx)),
        )?;
        if val.len() < 2 {
            if val.len() == 1 {
                return Ok(val[0] as i16);
            }
            return Err(crate::error::Error::DecodeError(format!(
                "column {} too short for i16",
                idx
            )));
        }
        Ok(i16::from_le_bytes([val[0], val[1]]))
    }

    /// Get an i8 value at the given column index.
    pub fn get_i8(&self, idx: usize) -> Result<i8> {
        let val = self.values.get(idx).and_then(|v| v.as_ref()).ok_or(
            crate::error::Error::DecodeError(format!("column {} is NULL or out of range", idx)),
        )?;
        if val.is_empty() {
            return Err(crate::error::Error::DecodeError(format!(
                "column {} is NULL",
                idx
            )));
        }
        Ok(val[0] as i8)
    }

    /// Get a f32 value at the given column index.
    pub fn get_f32(&self, idx: usize) -> Result<f32> {
        let val = self.values.get(idx).and_then(|v| v.as_ref()).ok_or(
            crate::error::Error::DecodeError(format!("column {} is NULL or out of range", idx)),
        )?;
        if val.len() < 4 {
            return Err(crate::error::Error::DecodeError(format!(
                "column {} too short for f32",
                idx
            )));
        }
        Ok(f32::from_le_bytes([val[0], val[1], val[2], val[3]]))
    }

    /// Get raw bytes at the given column index.
    pub fn get_bytes(&self, idx: usize) -> Result<Vec<u8>> {
        match self.values.get(idx) {
            Some(Some(v)) => Ok(v.clone()),
            Some(None) => Ok(vec![]),
            None => Err(crate::error::Error::DecodeError(format!(
                "column {} out of range",
                idx
            ))),
        }
    }

    /// Get an Option<i32> at the given column index (NULL-safe).
    pub fn get_opt_i32(&self, idx: usize) -> Result<Option<i32>> {
        match self.values.get(idx) {
            Some(Some(v)) if !v.is_empty() => Ok(Some(self.get_i32(idx)?)),
            _ => Ok(None),
        }
    }

    /// Get an Option<i64> at the given column index (NULL-safe).
    pub fn get_opt_i64(&self, idx: usize) -> Result<Option<i64>> {
        match self.values.get(idx) {
            Some(Some(v)) if !v.is_empty() => Ok(Some(self.get_i64(idx)?)),
            _ => Ok(None),
        }
    }

    /// Get an Option<&str> at the given column index (NULL-safe).
    pub fn get_opt_str(&self, idx: usize) -> Result<Option<&str>> {
        match self.values.get(idx) {
            Some(Some(v)) if !v.is_empty() => {
                Ok(Some(std::str::from_utf8(v).map_err(|e| {
                    crate::error::Error::DecodeError(format!("invalid UTF-8: {}", e))
                })?))
            }
            _ => Ok(None),
        }
    }

    /// Get an Option<f64> at the given column index (NULL-safe).
    pub fn get_opt_f64(&self, idx: usize) -> Result<Option<f64>> {
        match self.values.get(idx) {
            Some(Some(v)) if !v.is_empty() => Ok(Some(self.get_f64(idx)?)),
            _ => Ok(None),
        }
    }

    /// Get an owned String at the given column index (uses lossy UTF-8 fallback).
    ///
    /// Unlike `get_str()` which returns a borrowed `&str` and fails on invalid UTF-8,
    /// this method always succeeds by replacing invalid sequences with U+FFFD.
    /// Useful for binary-ish data or server status strings.
    pub fn get_string(&self, idx: usize) -> Result<String> {
        let val = self.values.get(idx).and_then(|v| v.as_ref()).ok_or(
            crate::error::Error::DecodeError(format!("column {} is NULL or out of range", idx)),
        )?;
        Ok(String::from_utf8_lossy(val).into_owned())
    }

    /// Placeholder: find column index by name (case-insensitive match).
    pub fn column_index(&self, _columns: &[Column]) -> usize {
        0
    }
}

/// Server->Client EXEC_RESPONSE (type 0).
#[derive(Debug, Clone)]
pub struct ExecResponse {
    /// Number of columns in the result.
    pub col_count: u16,
    /// Number of rows returned.
    pub row_count: u32,
    /// Column metadata.
    pub columns: Vec<Column>,
    /// Row data (column-major order).
    pub rows: Vec<Row>,
}

/// Decode DM binary DECIMAL to text representation.
fn decode_dm_decimal_to_text(data: &[u8], _scale: i16) -> Option<String> {
    const FLAG_ZERO: u8 = 0x80;
    const FLAG_POSITIVE: i32 = 0xC1;
    const FLAG_NEGTIVE: i32 = 0x3E;
    const NUM_POSITIVE: i32 = 1;
    const NUM_NEGTIVE: i32 = 101;
    if data.is_empty() || data.len() > 21 {
        return None;
    }
    if data[0] == FLAG_ZERO || data.len() == 1 {
        return Some("0".to_string());
    }
    let is_positive = data[0] & FLAG_ZERO != 0;
    let flag = data[0] as i32;
    let exponent = if is_positive {
        flag - FLAG_POSITIVE
    } else {
        FLAG_NEGTIVE - flag
    };
    let mut digits = Vec::with_capacity(data.len() - 1);
    for &b in &data[1..] {
        let digit = if is_positive {
            b as i32 - NUM_POSITIVE
        } else {
            NUM_NEGTIVE - b as i32
        };
        if digit < 0 || digit > 99 {
            break;
        }
        digits.push(digit);
    }
    if digits.is_empty() {
        return None;
    }

    let decimal_group = exponent + 1;
    let mut value = String::new();
    if !is_positive {
        value.push('-');
    }
    if decimal_group <= 0 {
        value.push_str("0.");
        for _ in 0..-decimal_group {
            value.push_str("00");
        }
        for digit in digits {
            value.push_str(&format!("{digit:02}"));
        }
    } else {
        for index in 0..decimal_group as usize {
            if index < digits.len() {
                if index == 0 {
                    value.push_str(&digits[index].to_string());
                } else {
                    value.push_str(&format!("{:02}", digits[index]));
                }
            } else {
                value.push_str("00");
            }
        }
        if (decimal_group as usize) < digits.len() {
            value.push('.');
            for digit in &digits[decimal_group as usize..] {
                value.push_str(&format!("{digit:02}"));
            }
        }
    }
    if value.contains('.') {
        while value.ends_with('0') {
            value.pop();
        }
        if value.ends_with('.') {
            value.pop();
        }
    }
    Some(value)
}

impl ExecResponse {
    /// Parse from raw payload bytes.
    ///
    /// Supports both EXEC (type 5) metadata-only responses and
    /// OPTIMIZED_PREPARE_EXEC (type 91) responses with inline row data.
    pub fn from_bytes(data: &[u8], server_encoding: ServerEncoding) -> Result<Self> {
        if data.len() < 16 {
            return Err(crate::error::Error::Incomplete);
        }

        // === Fixed Header (16 bytes) ===
        let sub_type = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
        let _flags = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
        let _reserved = u32::from_le_bytes([data[8], data[9], data[10], data[11]]);
        let header_row_count = u32::from_le_bytes([data[12], data[13], data[14], data[15]]);

        // If data is too short for first column header, return what we can.
        // For DML (INSERT/UPDATE/DELETE) the affected row count is in the fixed
        // 16-byte header — so we still extract it even without column metadata.
        if data.len() < 32 {
            return Ok(ExecResponse {
                col_count: 0,
                row_count: header_row_count,
                columns: vec![],
                rows: vec![],
            });
        }

        // === First Column Header (16 bytes, offset 16) ===
        // Note: first_col_type at offset 16 is unreliable on DM 8.1 — always returns 4 (INT).
        // We derive the correct type_code from the type_name string instead.
        let _first_col_type = i32::from_le_bytes([data[16], data[17], data[18], data[19]]);
        let first_nullable = u16::from_le_bytes([data[20], data[21]]);
        let col_count = u16::from_le_bytes([data[22], data[23]]);
        let col_name_len = u16::from_le_bytes([data[24], data[25]]) as usize;
        let type_name_len = u16::from_le_bytes([data[26], data[27]]) as usize;
        let table_name_len = u16::from_le_bytes([data[28], data[29]]) as usize;
        let schema_name_len = u16::from_le_bytes([data[30], data[31]]) as usize;

        let mut columns = Vec::with_capacity(col_count.max(1) as usize);
        let mut offset = 32; // Column variable data starts at 32

        // When col_count > 0, parse first column from the compact 16-byte header.
        // When col_count == 0 (BIND_EXEC2 path), ALL columns use the expanded 32-byte
        // format starting at offset 16 — skip the compact header parsing entirely.
        if col_count > 0 {
            // col_name (explicit length from col_name_len field at offset 24-25)
            let col_name = if col_name_len > 0 && offset + col_name_len <= data.len() {
                decode_from_server(server_encoding, &data[offset..offset + col_name_len])
            } else {
                String::new()
            };
            offset += col_name_len;

            // type_name
            let type_name = if type_name_len > 0 && offset + type_name_len <= data.len() {
                decode_from_server(server_encoding, &data[offset..offset + type_name_len])
            } else {
                String::new()
            };
            offset += type_name_len;

            // table_name
            let table_name = if table_name_len > 0 && offset + table_name_len <= data.len() {
                decode_from_server(server_encoding, &data[offset..offset + table_name_len])
            } else {
                String::new()
            };
            offset += table_name_len;

            // schema_name
            let schema_name = if schema_name_len > 0 && offset + schema_name_len <= data.len() {
                decode_from_server(server_encoding, &data[offset..offset + schema_name_len])
            } else {
                String::new()
            };
            offset += schema_name_len;

            // Skip null terminator after first col strings (if present)
            if offset < data.len() && data[offset] == 0 {
                offset += 1;
            }

            // Always derive type_code from type_name — the header field (offset 16)
            // is unreliable on DM 8.1 (often returns 4/INT for all types).
            let actual_type_code = type_name_to_code(&type_name);

            columns.push(Column {
                name: col_name,
                type_code: actual_type_code,
                type_name,
                precision: 0,
                scale: 0,
                nullable: first_nullable != 0,
                display_size: 0,
                table_name,
                schema_name,
                lob_tab_id: 0,
                lob_col_id: 0,
            });
        }

        // === Subsequent Columns ===
        // OPE(91) may report col_count=1 even for multi-column queries regardless
        // of the response sub-type, so parse columns dynamically until row data.
        //
        // When col_count == 0 (BIND_EXEC2 path for SELECT with params), the server
        // sends NO inline column metadata or row data — the data must be fetched
        // via FETCH protocol. In this case skip dynamic parsing entirely.
        //
        // Verified against DM 8.1.3.62 wire protocol:
        // First column: 16-byte compact header (already parsed above)
        // Subsequent columns: 32-byte expanded header (NO gap between columns):
        //   0   u32  col_type (LE)
        //   4   u32  precision (LE)
        //   8   u32  scale (LE)
        //  12   u32  nullable_flags (LE)
        //  16   u32  reserved (LE)
        //  20   u16  reserved
        //  22   u16  col_index (?)
        //  24   u16  name_len
        //  26   u16  type_name_len
        //  28   u16  table_name_len
        //  30   u16  schema_name_len
        //  32   [col_name][type_name][table_name][schema_name] (no null terminator)
        let use_dynamic = col_count > 0;
        // When col_count == 0 (BIND_EXEC2 SELECT path), all columns use the
        // expanded 32-byte format starting at offset 16 (no compact first-column header).
        // We reuse the dynamic parser logic with col_count as the parsed count.
        let max_cols = if use_dynamic {
            4_096
        } else {
            (col_count as usize).max(columns.len())
        };
        let mut _parsed_cols = columns.len() as usize;
        // For BIND_EXEC2 (col_count == 0), start parsing at offset 16 (right after header),
        // reusing the expanded column parser loop below.
        if col_count == 0 {
            _parsed_cols = 0;
            offset = 16;
        }
        let mut parsed_cols = 1;
        while parsed_cols < max_cols {
            // Save position before attempting to parse next column.
            // If we don't find a valid column header, row data starts here.
            let row_start = offset;

            // Subsequent column header is 32 bytes
            if offset + 32 > data.len() {
                offset = row_start;
                break;
            }

            let header_off = offset;

            // Compact row format marker — row data starts here
            if data[header_off] == 0x0C {
                offset = row_start;
                break;
            }

            // Expanded 32-byte header for subsequent columns
            let _c_type = i32::from_le_bytes([
                data[header_off],
                data[header_off + 1],
                data[header_off + 2],
                data[header_off + 3],
            ]);
            // If c_type is 0 or invalid, we've hit row data — stop parsing columns
            if !(1..=31).contains(&_c_type) {
                offset = row_start;
                break;
            }
            let c_precision = u32::from_le_bytes([
                data[header_off + 4],
                data[header_off + 5],
                data[header_off + 6],
                data[header_off + 7],
            ]);
            let c_scale = i32::from_le_bytes([
                data[header_off + 8],
                data[header_off + 9],
                data[header_off + 10],
                data[header_off + 11],
            ]);
            if c_precision > 1_000_000 || !(-1_000..=1_000).contains(&c_scale) {
                offset = row_start;
                break;
            }
            let c_nullable = u32::from_le_bytes([
                data[header_off + 12],
                data[header_off + 13],
                data[header_off + 14],
                data[header_off + 15],
            ]);
            // reserved at offsets 16-23 (4 bytes + 2 u16)

            // Length fields at offsets 24-31
            let c_name_len =
                u16::from_le_bytes([data[header_off + 24], data[header_off + 25]]) as usize;
            let c_type_name_len =
                u16::from_le_bytes([data[header_off + 26], data[header_off + 27]]) as usize;
            let c_table_len =
                u16::from_le_bytes([data[header_off + 28], data[header_off + 29]]) as usize;
            let c_schema_len =
                u16::from_le_bytes([data[header_off + 30], data[header_off + 31]]) as usize;

            // Validate lengths — if unreasonable, we've hit row data
            if c_name_len == 0
                || c_type_name_len == 0
                || c_name_len > 128
                || c_type_name_len > 128
                || c_table_len > 128
                || c_schema_len > 128
            {
                offset = row_start;
                break;
            }

            // Strings start at header_off + 32
            offset = header_off + 32;
            let c_name = if c_name_len > 0 && offset + c_name_len <= data.len() {
                decode_from_server(server_encoding, &data[offset..offset + c_name_len])
            } else {
                offset = row_start;
                break;
            };
            offset += c_name_len;

            let c_type_name = if c_type_name_len > 0 && offset + c_type_name_len <= data.len() {
                decode_from_server(server_encoding, &data[offset..offset + c_type_name_len])
            } else {
                String::new()
            };
            offset += c_type_name_len;

            let c_table = if c_table_len > 0 && offset + c_table_len <= data.len() {
                decode_from_server(server_encoding, &data[offset..offset + c_table_len])
            } else {
                String::new()
            };
            offset += c_table_len;

            let c_schema = if c_schema_len > 0 && offset + c_schema_len <= data.len() {
                decode_from_server(server_encoding, &data[offset..offset + c_schema_len])
            } else {
                String::new()
            };
            offset += c_schema_len;

            // For sub_type=7, the 32-byte header c_type field is unreliable for
            // subsequent columns (e.g., VARCHAR returns 2 instead of 3).
            // Always derive from type_name string instead.
            let actual_c_type = type_name_to_code(&c_type_name);

            // Read itemFlag (offset 16-17 within the 32-byte header) to detect LOB columns.
            // itemFlag bits: 0x01=identity, 0x02=lob, 0x04=readonly
            let item_flag = u16::from_le_bytes([data[header_off + 16], data[header_off + 17]]);
            let is_lob = (item_flag & 0x02) != 0;

            // For LOB columns, DM appends lobTabId (i32 LE) + lobColId (i16 LE) after the strings.
            let (c_lob_tab_id, c_lob_col_id) = if is_lob && offset + 6 <= data.len() {
                let tab_id = i32::from_le_bytes([
                    data[offset],
                    data[offset + 1],
                    data[offset + 2],
                    data[offset + 3],
                ]);
                offset += 4;
                let col_id = i16::from_le_bytes([data[offset], data[offset + 1]]);
                offset += 2;
                (tab_id, col_id)
            } else {
                (0, 0)
            };

            columns.push(Column {
                name: c_name,
                type_code: actual_c_type,
                type_name: c_type_name,
                precision: 0,
                scale: 0,
                nullable: c_nullable != 0,
                display_size: 0,
                table_name: c_table,
                schema_name: c_schema,
                lob_tab_id: c_lob_tab_id,
                lob_col_id: c_lob_col_id,
            });
            parsed_cols += 1;
        }

        // === Inline Row Data (OPE responses only) ===
        // Two row formats depending on sub_type:
        //   sub_type=2: compact format (V$VERSION style) - marker(1)+flags(1)+val_size(2)+value(N)
        //   sub_type=7: full format (SELECT style) - row_hdr+col_offsets+values
        let mut rows = Vec::new();
        if columns.is_empty() {
            return Ok(Self {
                col_count,
                row_count: header_row_count,
                columns,
                rows,
            });
        } else if sub_type == 2 && columns.len() == 1 {
            // Compact row format (V$VERSION style):
            // Each row: marker(0x0C) + flags(1) + val_size(2) + value(N) + padding
            while offset + 4 <= data.len() && data[offset] != 0x0C {
                offset += 1;
            }
            while offset + 4 <= data.len() && data[offset] == 0x0C {
                let row_start = offset;
                let _flags = data[offset + 1];
                let val_size = u16::from_le_bytes([data[offset + 2], data[offset + 3]]) as usize;
                if val_size == 0 || offset + 4 + val_size > data.len() {
                    break;
                }
                let value_bytes = data[offset + 4..offset + 4 + val_size].to_vec();
                let next_scan = offset + 4 + val_size;
                let mut found = false;
                for scan in next_scan..data.len() {
                    if data[scan] == 0x0C {
                        offset = scan;
                        found = true;
                        break;
                    }
                }
                if !found {
                    offset = data.len();
                }
                let mut values = Vec::with_capacity(columns.len());
                values.push(Some(value_bytes));
                for _ in 1..columns.len() {
                    values.push(None);
                }
                // Decode string columns from server encoding, DECIMAL to text
                for ci in 0..columns.len().min(values.len()) {
                    if matches!(columns[ci].type_code, 3 | 14 | 16 | 23) {
                        if let Some(ref val_bytes) = values[ci] {
                            let decoded = decode_from_server(server_encoding, val_bytes);
                            values[ci] = Some(decoded.into_bytes());
                        }
                    } else if matches!(columns[ci].type_code, 9 | 20) {
                        if let Some(ref val_bytes) = values[ci] {
                            if let Some(text) =
                                decode_dm_decimal_to_text(val_bytes, columns[ci].scale)
                            {
                                values[ci] = Some(text.into_bytes());
                            }
                        }
                    }
                }
                rows.push(Row {
                    row_id: row_start as u16,
                    values,
                });
            }
        } else {
            // Full row format (sub_type=7 and others)
            // CRITICAL: The first byte (row_size) does NOT represent actual row length.
            // DM 8.1.3.62: row_size=0x23=35 but actual row data spans ~50 bytes.
            // Instead, calculate true row end from the column value offsets + sizes.
            while offset + 10 <= data.len() {
                let row_start = offset;
                let _row_size = data[offset]; // Present but unreliable for advancement
                let _flags = data[offset + 1];
                let rec_id = u32::from_le_bytes([
                    data[offset + 2],
                    data[offset + 3],
                    data[offset + 4],
                    data[offset + 5],
                ]);

                // Column offset table: col_count x 2 bytes, starting at row_start + 10
                let offsets_start = row_start + 10;
                let col_offsets: Vec<u16> = (0..columns.len())
                    .map(|c| {
                        let o = offsets_start + c * 2;
                        if o + 2 <= data.len() {
                            u16::from_le_bytes([data[o], data[o + 1]])
                        } else {
                            0
                        }
                    })
                    .collect();

                // Parse values and track the furthest byte consumed
                let mut values = Vec::with_capacity(columns.len());
                let mut row_end = offsets_start + columns.len() * 2;
                for (_ci, col_off) in col_offsets.iter().enumerate() {
                    let val_abs = row_start + *col_off as usize;
                    if val_abs + 2 > data.len() {
                        values.push(None);
                        continue;
                    }
                    let val_size = u16::from_le_bytes([data[val_abs], data[val_abs + 1]]) as usize;
                    if val_size == 0 {
                        values.push(None);
                    } else if val_abs + 2 + val_size <= data.len() {
                        values.push(Some(data[val_abs + 2..val_abs + 2 + val_size].to_vec()));
                        let val_end = val_abs + 2 + val_size;
                        if val_end > row_end {
                            row_end = val_end;
                        }
                    } else {
                        values.push(None);
                    }
                }

                offset = row_end;
                let reported = _row_size as usize;
                if reported > 0 && row_start + reported > offset {
                    offset = row_start + reported;
                }
                // Decode string columns from server encoding, DECIMAL to text
                for ci in 0..columns.len().min(values.len()) {
                    if matches!(columns[ci].type_code, 3 | 14 | 16 | 23) {
                        if let Some(ref val_bytes) = values[ci] {
                            let decoded = decode_from_server(server_encoding, val_bytes);
                            values[ci] = Some(decoded.into_bytes());
                        }
                    } else if matches!(columns[ci].type_code, 9 | 20) {
                        if let Some(ref val_bytes) = values[ci] {
                            if let Some(text) =
                                decode_dm_decimal_to_text(val_bytes, columns[ci].scale)
                            {
                                values[ci] = Some(text.into_bytes());
                            }
                        }
                    }
                }
                rows.push(Row {
                    row_id: rec_id as u16,
                    values,
                });
            }
        }

        Ok(Self {
            col_count,
            row_count: header_row_count,
            columns,
            rows,
        })
    }

    /// Helper to safely read u32 LE.
    #[allow(dead_code)]
    fn safe_u32(data: &[u8], offset: usize) -> u32 {
        if offset + 4 <= data.len() {
            u32::from_le_bytes([
                data[offset],
                data[offset + 1],
                data[offset + 2],
                data[offset + 3],
            ])
        } else {
            0
        }
    }

    /// Check if this response contains result rows.
    pub fn has_rows(&self) -> bool {
        !self.rows.is_empty()
    }

    /// Get the number of columns.
    pub fn num_columns(&self) -> usize {
        self.columns.len()
    }

    /// Get the number of rows.
    pub fn num_rows(&self) -> usize {
        self.rows.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_row_get_i32() {
        let row = Row {
            row_id: 0,
            values: vec![Some(vec![1, 0, 0, 0])],
        };
        assert_eq!(row.get_i32(0).unwrap(), 1);
    }

    #[test]
    fn test_row_get_i32_single_byte() {
        let row = Row {
            row_id: 0,
            values: vec![Some(vec![42])],
        };
        assert_eq!(row.get_i32(0).unwrap(), 42);
    }

    #[test]
    fn test_row_get_str() {
        let row = Row {
            row_id: 0,
            values: vec![Some(b"hello".to_vec())],
        };
        assert_eq!(row.get_str(0).unwrap(), "hello");
    }

    #[test]
    fn test_row_is_null() {
        let row = Row {
            row_id: 0,
            values: vec![None, Some(vec![1, 2, 3])],
        };
        assert!(row.is_null(0));
        assert!(!row.is_null(1));
    }

    #[test]
    fn test_row_len() {
        let row = Row {
            row_id: 0,
            values: vec![Some(vec![1]), Some(vec![2]), Some(vec![3])],
        };
        assert_eq!(row.len(), 3);
        assert!(!row.is_empty());
    }

    #[test]
    fn test_row_get_i64() {
        let row = Row {
            row_id: 0,
            values: vec![Some(vec![42, 0, 0, 0, 0, 0, 0, 0])],
        };
        assert_eq!(row.get_i64(0).unwrap(), 42);
    }

    #[test]
    fn test_exec_response_has_rows() {
        let resp = ExecResponse {
            col_count: 0,
            row_count: 0,
            columns: vec![],
            rows: vec![],
        };
        assert!(!resp.has_rows());
    }

    #[test]
    fn test_exec_response_minimal_empty() {
        // Valid empty response: header(16) + col_header(16) + null_terminator(1)
        let data = [
            0x07, 0x00, 0x00, 0x00, // sub_type
            0x04, 0x00, 0x00, 0x00, // flags
            0x00, 0x00, 0x00, 0x00, // reserved
            0x00, 0x00, 0x00, 0x00, // row_count = 0
            0x00, 0x00, 0x00, 0x00, // col_type = 0
            0x00, 0x00, // nullable
            0x00, 0x00, // display
            0x00, 0x00, // col_count = 0
            0x00, 0x00, // type_name_len
            0x00, 0x00, // table_name_len
            0x00, 0x00, // schema_name_len
        ];
        let resp = ExecResponse::from_bytes(&data, ServerEncoding::Utf8).unwrap();
        assert_eq!(resp.col_count, 0);
        assert_eq!(resp.num_columns(), 0);
        assert_eq!(resp.num_rows(), 0);
    }

    #[test]
    fn test_exec_response_select1_ope() {
        // OPE response for "SELECT 1 FROM DUAL" (58 bytes)
        let data: Vec<u8> = vec![
            0x07, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
            0x00, 0x00, // header (row_count=1)
            0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x07, 0x00, 0x00, 0x00,
            0x00,
            0x00, // col1 header (type=4, nullable=0, col_count=1, col_name_len=1, type_name_len=7)
            0x31, 0x49, 0x4e, 0x54, 0x45, 0x47, 0x45, 0x52,
            0x00, // col1 strings: "1" + "INTEGER" + \0
            // Row data (18 bytes): marker=18, flags=0, rec_id=0, padding=0, col_off=12, val_size=4, val=1
            0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x04, 0x00,
            0x01, 0x00, 0x00, 0x00,
        ];
        let resp = ExecResponse::from_bytes(&data, ServerEncoding::Utf8).unwrap();
        assert_eq!(resp.col_count, 1);
        assert_eq!(resp.num_columns(), 1);
        assert_eq!(resp.num_rows(), 1);
        assert_eq!(resp.columns[0].name, "1");
        assert_eq!(resp.columns[0].type_name, "INTEGER");
        assert_eq!(resp.columns[0].type_code, 4);
        assert_eq!(resp.rows[0].get_i32(0).unwrap(), 1);
    }

    #[test]
    fn test_exec_response_select1_ope_no_null_term() {
        // Actual OPE response from DM 8.1.3.62 - no \0 terminator (58 bytes)
        let data: Vec<u8> = vec![
            0x07, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
            0x00, 0x00, // header (row_count=1)
            0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x07, 0x00, 0x00, 0x00,
            0x00, 0x00, // col1 header (type=4, nullable=0, col_count=1, col_name_len=1)
            // Strings: "1" + "INTEGER" (no \0 terminator!)
            0x31, 0x49, 0x4e, 0x54, 0x45, 0x47, 0x45, 0x52,
            // Row data: marker=18, flags=0, rec_id=0, padding=0, col_off=12, val_size=4, val=1
            0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x04, 0x00,
            0x01, 0x00, 0x00, 0x00,
        ];
        let resp = ExecResponse::from_bytes(&data, ServerEncoding::Utf8).unwrap();
        assert_eq!(resp.col_count, 1);
        assert_eq!(resp.num_columns(), 1);
        assert_eq!(resp.num_rows(), 1);
        assert_eq!(resp.columns[0].name, "1");
        assert_eq!(resp.columns[0].type_name, "INTEGER");
        assert_eq!(resp.columns[0].type_code, 4);
        assert_eq!(resp.rows[0].get_i32(0).unwrap(), 1);
    }

    #[test]
    fn test_exec_response_subtype2_with_multiple_columns() {
        // Captured from DM8 for SELECT NAME, NAME FROM a one-row table. DM reports
        // col_count=1 even though a second expanded column header follows.
        let data: Vec<u8> = vec![
            0x02, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x04, 0x00, 0x07, 0x00,
            0x11, 0x00, 0x06, 0x00, 0x4e, 0x41, 0x4d, 0x45, 0x56, 0x41, 0x52, 0x43, 0x48, 0x41,
            0x52, 0x54, 0x41, 0x42, 0x4c, 0x45, 0x50, 0x52, 0x4f, 0x5f, 0x4c, 0x4f, 0x42, 0x5f,
            0x54, 0x45, 0x53, 0x54, 0x53, 0x59, 0x53, 0x44, 0x42, 0x41, 0x02, 0x00, 0x00, 0x00,
            0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x04, 0x00, 0x07, 0x00, 0x11, 0x00, 0x06, 0x00,
            0x4e, 0x41, 0x4d, 0x45, 0x56, 0x41, 0x52, 0x43, 0x48, 0x41, 0x52, 0x54, 0x41, 0x42,
            0x4c, 0x45, 0x50, 0x52, 0x4f, 0x5f, 0x4c, 0x4f, 0x42, 0x5f, 0x54, 0x45, 0x53, 0x54,
            0x53, 0x59, 0x53, 0x44, 0x42, 0x41, 0x1c, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x0e, 0x00, 0x15, 0x00, 0x05, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x05,
            0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
        ];

        let resp = ExecResponse::from_bytes(&data, ServerEncoding::Utf8).unwrap();

        assert_eq!(resp.col_count, 1);
        assert_eq!(resp.num_columns(), 2);
        assert_eq!(resp.num_rows(), 1);
        assert_eq!(resp.rows[0].get_str(0).unwrap(), "hello");
        assert_eq!(resp.rows[0].get_str(1).unwrap(), "hello");
    }

    #[test]
    fn test_decode_dm_decimal_to_text_honors_exponent() {
        assert_eq!(
            decode_dm_decimal_to_text(&[0xc2, 0x02], 0).as_deref(),
            Some("100")
        );
        assert_eq!(
            decode_dm_decimal_to_text(&[0xc2, 0x52, 0x59], 0).as_deref(),
            Some("8188")
        );
        assert_eq!(
            decode_dm_decimal_to_text(&[0xc1, 0x02, 0x18], 0).as_deref(),
            Some("1.23")
        );
        assert_eq!(
            decode_dm_decimal_to_text(&[0x3e, 0x64, 0x4e, 0x66], 0).as_deref(),
            Some("-1.23")
        );
    }

    #[test]
    fn test_exec_response_incomplete() {
        let data = [0x00, 0x00, 0x00];
        let result = ExecResponse::from_bytes(&data, ServerEncoding::Utf8);
        assert!(matches!(result, Err(crate::error::Error::Incomplete)));
    }

    #[test]
    fn test_exec_response_short_payload_dml() {
        // INSERT/UPDATE/DELETE response with only 16-byte header (no column metadata).
        // The affected row count must still be extracted from the header.
        let data = [
            0x07, 0x00, 0x00, 0x00, // sub_type
            0x04, 0x00, 0x00, 0x00, // flags
            0x00, 0x00, 0x00, 0x00, // reserved
            0x01, 0x00, 0x00, 0x00, // row_count = 1 (affected rows)
        ];
        let resp = ExecResponse::from_bytes(&data, ServerEncoding::Utf8).unwrap();
        assert_eq!(resp.row_count, 1);
        assert_eq!(resp.col_count, 0);
        assert_eq!(resp.num_columns(), 0);
        assert_eq!(resp.num_rows(), 0);
    }

    #[test]
    fn test_row_get_i32_null() {
        let row = Row {
            row_id: 0,
            values: vec![None],
        };
        assert!(row.get_i32(0).is_err());
        assert!(row.is_null(0));
    }

    #[test]
    fn test_row_get_str_empty() {
        let row = Row {
            row_id: 0,
            values: vec![Some(vec![])],
        };
        let result = row.get_str(0).unwrap();
        assert_eq!(result, "");
    }
}
