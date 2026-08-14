//! Row representation for query results.
//!
//! Provides SQLx-style `row.get::<T>(idx)` API and iterator support.

use std::ops::Deref;
use std::str::FromStr;

use dameng_protocol::Row;

pub use dameng_protocol::Column;

/// A query result set containing columns and rows.
#[derive(Debug, Clone)]
pub struct ResultSet {
    /// Column metadata shared across all rows.
    pub columns: Vec<Column>,
    /// Row data.
    pub rows: Vec<Row>,
    /// Result set cursor ID (from the initial query).
    pub cursor_id: i16,
    /// Total row count in the result set (from server).
    pub total_row_count: u64,
}

/// A single row with column metadata, produced by iterating a `ResultSet`.
///
/// Supports SQLx-style `row.get::<T>(idx)` for type-safe column access,
/// and `row.get_str_ref(idx)` / `row.get_opt_str_ref(idx)` for borrowed string access.
#[derive(Debug, Clone)]
pub struct QueryRow {
    /// The underlying raw row data.
    pub row: Row,
    /// Column metadata for decoding values.
    pub columns: Vec<Column>,
}

/// A row with referenced column metadata (borrowed iteration).
#[derive(Debug, Clone)]
pub struct QueryRowRef<'a> {
    /// The underlying raw row data.
    pub row: &'a Row,
    /// Column metadata reference.
    pub columns: &'a [Column],
}

impl<'a> Deref for QueryRowRef<'a> {
    type Target = Row;
    fn deref(&self) -> &Self::Target {
        self.row
    }
}

// ─── IntoIterator for ResultSet (consuming) ─────────────────────────────────

impl IntoIterator for ResultSet {
    type Item = QueryRow;
    type IntoIter = std::vec::IntoIter<QueryRow>;

    fn into_iter(self) -> Self::IntoIter {
        let columns = self.columns;
        let qrows: Vec<QueryRow> = self
            .rows
            .into_iter()
            .map(|row| QueryRow {
                row,
                columns: columns.clone(),
            })
            .collect();
        qrows.into_iter()
    }
}

// ─── IntoIterator for &ResultSet (borrowing) ────────────────────────────────

impl<'a> IntoIterator for &'a ResultSet {
    type Item = QueryRowRef<'a>;
    type IntoIter = ResultSetIter<'a>;

    fn into_iter(self) -> Self::IntoIter {
        ResultSetIter {
            result_set: self,
            current: 0,
        }
    }
}

/// Borrowing iterator over rows in a ResultSet.
pub struct ResultSetIter<'a> {
    result_set: &'a ResultSet,
    current: usize,
}

impl<'a> Iterator for ResultSetIter<'a> {
    type Item = QueryRowRef<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.current >= self.result_set.rows.len() {
            return None;
        }
        let row = &self.result_set.rows[self.current];
        self.current += 1;
        Some(QueryRowRef {
            row,
            columns: &self.result_set.columns,
        })
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let remaining = self.result_set.rows.len() - self.current;
        (remaining, Some(remaining))
    }
}

impl ExactSizeIterator for ResultSetIter<'_> {}

// ─── DmDecode trait ─────────────────────────────────────────────────────────

/// Decode a column value from its raw bytes into a Rust type.
///
/// The lifetime `'de` allows borrowing the raw bytes (e.g., for `&str`).
pub trait DmDecode<'de>: Sized {
    /// Decode from an optional byte slice.
    /// `None` means NULL, `Some(&[])` means an empty (non-NULL) value.
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self>;
}

impl<'de> DmDecode<'de> for bool {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column value is empty".to_string(),
            ));
        }
        Ok(bytes[0] != 0)
    }
}

impl<'de> DmDecode<'de> for i32 {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column value is empty".to_string(),
            ));
        }
        if bytes.len() < 4 {
            if bytes.len() == 1 {
                return Ok(bytes[0] as i32);
            }
            if bytes.len() == 2 {
                return Ok(i32::from(i16::from_le_bytes([bytes[0], bytes[1]])));
            }
            return Err(crate::error::Error::DecodeError(format!(
                "too short for i32: {} bytes",
                bytes.len()
            )));
        }
        let arr: [u8; 4] = bytes[..4].try_into().unwrap();
        Ok(i32::from_le_bytes(arr))
    }
}

impl<'de> DmDecode<'de> for i64 {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column value is empty".to_string(),
            ));
        }
        if bytes.len() < 8 {
            if bytes.len() >= 4 {
                let arr: [u8; 4] = bytes[..4].try_into().unwrap();
                return Ok(i64::from(i32::from_le_bytes(arr)));
            }
            return Err(crate::error::Error::DecodeError(format!(
                "too short for i64: {} bytes",
                bytes.len()
            )));
        }
        let arr: [u8; 8] = bytes[..8].try_into().unwrap();
        Ok(i64::from_le_bytes(arr))
    }
}

impl<'de> DmDecode<'de> for i16 {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column value is empty".to_string(),
            ));
        }
        if bytes.len() < 2 {
            if bytes.len() == 1 {
                return Ok(bytes[0] as i16);
            }
            return Err(crate::error::Error::DecodeError(format!(
                "too short for i16: {} bytes",
                bytes.len()
            )));
        }
        Ok(i16::from_le_bytes([bytes[0], bytes[1]]))
    }
}

impl<'de> DmDecode<'de> for i8 {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column is NULL".to_string(),
            ));
        }
        Ok(bytes[0] as i8)
    }
}

impl<'de> DmDecode<'de> for u32 {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column value is empty".to_string(),
            ));
        }
        if bytes.len() < 4 {
            if bytes.len() == 1 {
                return Ok(bytes[0] as u32);
            }
            if bytes.len() == 2 {
                return Ok(u16::from_le_bytes([bytes[0], bytes[1]]) as u32);
            }
            return Err(crate::error::Error::DecodeError(format!(
                "too short for u32: {} bytes",
                bytes.len()
            )));
        }
        let arr: [u8; 4] = bytes[..4].try_into().unwrap();
        Ok(u32::from_le_bytes(arr))
    }
}

impl<'de> DmDecode<'de> for u64 {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column value is empty".to_string(),
            ));
        }
        if bytes.len() < 8 {
            if bytes.len() >= 4 {
                let arr: [u8; 4] = bytes[..4].try_into().unwrap();
                return Ok(u32::from_le_bytes(arr) as u64);
            }
            return Err(crate::error::Error::DecodeError(format!(
                "too short for u64: {} bytes",
                bytes.len()
            )));
        }
        let arr: [u8; 8] = bytes[..8].try_into().unwrap();
        Ok(u64::from_le_bytes(arr))
    }
}

impl<'de> DmDecode<'de> for u16 {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column value is empty".to_string(),
            ));
        }
        if bytes.len() < 2 {
            if bytes.len() == 1 {
                return Ok(bytes[0] as u16);
            }
            return Err(crate::error::Error::DecodeError(format!(
                "too short for u16: {} bytes",
                bytes.len()
            )));
        }
        Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
    }
}

impl<'de> DmDecode<'de> for u8 {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column is NULL".to_string(),
            ));
        }
        Ok(bytes[0])
    }
}

impl<'de> DmDecode<'de> for f64 {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.len() < 8 {
            return Err(crate::error::Error::DecodeError(format!(
                "too short for f64: {} bytes",
                bytes.len()
            )));
        }
        let arr: [u8; 8] = bytes[..8].try_into().unwrap();
        Ok(f64::from_le_bytes(arr))
    }
}

impl<'de> DmDecode<'de> for f32 {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.len() < 4 {
            return Err(crate::error::Error::DecodeError(format!(
                "too short for f32: {} bytes",
                bytes.len()
            )));
        }
        let arr: [u8; 4] = bytes[..4].try_into().unwrap();
        Ok(f32::from_le_bytes(arr))
    }
}

/// Returns a borrowed string from the row's raw value bytes.
impl<'de> DmDecode<'de> for &'de str {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Ok("");
        }
        std::str::from_utf8(bytes)
            .map_err(|e| crate::error::Error::DecodeError(format!("invalid UTF-8: {}", e)))
    }
}

/// Returns an owned String.
impl<'de> DmDecode<'de> for String {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        Ok(String::from_utf8_lossy(bytes).into_owned())
    }
}

/// Returns a Decimal from DECIMAL type (text, already decoded in response parser).
impl<'de> DmDecode<'de> for rust_decimal::Decimal {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        let s = std::str::from_utf8(bytes).map_err(|_| {
            crate::error::Error::DecodeError("DECIMAL is not valid UTF-8".to_string())
        })?;
        let trimmed = s.trim();
        if trimmed.is_empty() || trimmed == "0" {
            return Ok(rust_decimal::Decimal::ZERO);
        }
        rust_decimal::Decimal::from_str(trimmed).map_err(|e| {
            crate::error::Error::DecodeError(format!("invalid DECIMAL '{}' : {}", trimmed, e))
        })
    }
}

/// Returns a NaiveDate from DATE type.
impl<'de> DmDecode<'de> for chrono::NaiveDate {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column value is empty".to_string(),
            ));
        }
        // Try text format first
        if let Ok(s) = std::str::from_utf8(bytes) {
            if let Ok(d) = chrono::NaiveDate::parse_from_str(s.trim(), "%Y-%m-%d") {
                return Ok(d);
            }
        }
        // Try binary format (7 bytes: year:2BE, month:1, day:1, hour:1, min:1, sec:1)
        // Try 3-byte DM row format (DATE_PREC = 3, year+month+day compressed)
        if bytes.len() >= 3 && bytes.len() < 7 {
            let year = i32::from(i16::from_le_bytes([bytes[0], bytes[1]])) & 0x7FFF;
            let month = ((bytes[1] as u32 >> 7) & 0x1) + ((bytes[2] as u32 & 0x07) << 1);
            let day = ((bytes[2] as u32 & 0xF8) >> 3) & 0x1F;
            if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day) {
                return Ok(d);
            }
        }
        // Try 7-byte OPE format
        if bytes.len() >= 7 {
            let year = u16::from_be_bytes([bytes[0], bytes[1]]) as i32;
            let month = bytes[2] as u32;
            let day = bytes[3] as u32;
            if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day) {
                return Ok(d);
            }
        }
        // Try 8-byte DM row format (DATE_PREC = 7 but stored in 8 bytes)
        if bytes.len() >= 8 {
            let year = i32::from(i16::from_le_bytes([bytes[0], bytes[1]])) & 0x7FFF;
            let month = ((bytes[1] as u32 >> 7) & 0x1) + ((bytes[2] as u32 & 0x07) << 1);
            let day = ((bytes[2] as u32 & 0xF8) >> 3) & 0x1F;
            if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day) {
                return Ok(d);
            }
        }
        Err(crate::error::Error::DecodeError(
            "too short for DATE".to_string(),
        ))
    }
}

/// Returns a NaiveDateTime from TIMESTAMP type.
impl<'de> DmDecode<'de> for chrono::NaiveDateTime {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        let bytes =
            value.ok_or_else(|| crate::error::Error::DecodeError("column is NULL".to_string()))?;
        if bytes.is_empty() {
            return Err(crate::error::Error::DecodeError(
                "column value is empty".to_string(),
            ));
        }
        // Try text format first
        if let Ok(s) = std::str::from_utf8(bytes) {
            let s = s.trim();
            if let Ok(ts) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S") {
                return Ok(ts);
            }
            if let Ok(ts) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S%.f") {
                return Ok(ts);
            }
        }
        // Try 11-byte OPE format (year:2BE, month:1, day:1, hour:1, min:1, sec:1, nano:4BE)
        if bytes.len() >= 11 {
            let year = u16::from_be_bytes([bytes[0], bytes[1]]) as i32;
            let month = bytes[2] as u32;
            let day = bytes[3] as u32;
            let hour = bytes[4] as u32;
            let minute = bytes[5] as u32;
            let second = bytes[6] as u32;
            let nano = u32::from_be_bytes([bytes[7], bytes[8], bytes[9], bytes[10]]);
            if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day)
                .and_then(|d| d.and_hms_nano_opt(hour, minute, second, nano))
            {
                return Ok(d);
            }
        }
        // Try 8-byte DM row format (DATETIME_PREC)
        if bytes.len() >= 8 {
            let year = i32::from(i16::from_le_bytes([bytes[0], bytes[1]])) & 0x7FFF;
            let month = ((bytes[1] as u32 >> 7) & 0x1) + ((bytes[2] as u32 & 0x07) << 1);
            let day = ((bytes[2] as u32 & 0xF8) >> 3) & 0x1F;
            let hour = bytes[3] as u32 & 0x1F;
            let minute = ((bytes[3] as u32 >> 5) & 0x07) + ((bytes[4] as u32 & 0x07) << 3);
            let second = ((bytes[4] as u32 >> 3) & 0x1F) + ((bytes[5] as u32 & 0x01) << 5);
            let nano = (((bytes[5] as u32 >> 1) & 0x7F)
                + ((bytes[6] as u32 & 0xFF) << 7)
                + ((bytes[7] as u32 & 0x1F) << 15))
                * 1000;
            if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day)
                .and_then(|d| d.and_hms_nano_opt(hour, minute, second, nano))
            {
                return Ok(d);
            }
        }
        Err(crate::error::Error::DecodeError(
            "too short for TIMESTAMP".to_string(),
        ))
    }
}

impl<'de> DmDecode<'de> for Vec<u8> {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        match value {
            Some(bytes) => Ok(bytes.to_vec()),
            None => Ok(vec![]),
        }
    }
}

// ─── Option<T> support ──────────────────────────────────────────────────────

macro_rules! impl_dm_decode_option {
    ($inner:ty) => {
        impl<'de> DmDecode<'de> for Option<$inner> {
            fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
                match value {
                    Some(bytes) if !bytes.is_empty() => {
                        <$inner as DmDecode>::decode(Some(bytes)).map(Some)
                    }
                    _ => Ok(None),
                }
            }
        }
    };
}

impl_dm_decode_option!(bool);
impl_dm_decode_option!(i32);
impl_dm_decode_option!(i64);
impl_dm_decode_option!(i16);
impl_dm_decode_option!(i8);
impl_dm_decode_option!(u32);
impl_dm_decode_option!(u64);
impl_dm_decode_option!(u16);
impl_dm_decode_option!(u8);
impl_dm_decode_option!(f64);
impl_dm_decode_option!(f32);

impl<'de> DmDecode<'de> for Option<&'de str> {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        match value {
            Some(bytes) if !bytes.is_empty() => <&str as DmDecode>::decode(Some(bytes)).map(Some),
            _ => Ok(None),
        }
    }
}

impl<'de> DmDecode<'de> for Option<String> {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        match value {
            Some(bytes) if !bytes.is_empty() => <String as DmDecode>::decode(Some(bytes)).map(Some),
            _ => Ok(None),
        }
    }
}

impl<'de> DmDecode<'de> for Option<Vec<u8>> {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        match value {
            Some(bytes) if !bytes.is_empty() => Ok(Some(bytes.to_vec())),
            _ => Ok(None),
        }
    }
}

impl<'de> DmDecode<'de> for Option<rust_decimal::Decimal> {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        match value {
            Some(bytes) if !bytes.is_empty() => {
                <rust_decimal::Decimal as DmDecode>::decode(Some(bytes)).map(Some)
            }
            _ => Ok(None),
        }
    }
}

impl<'de> DmDecode<'de> for Option<chrono::NaiveDate> {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        match value {
            Some(bytes) if !bytes.is_empty() => {
                <chrono::NaiveDate as DmDecode>::decode(Some(bytes)).map(Some)
            }
            _ => Ok(None),
        }
    }
}

impl<'de> DmDecode<'de> for Option<chrono::NaiveDateTime> {
    fn decode(value: Option<&'de [u8]>) -> crate::error::Result<Self> {
        match value {
            Some(bytes) if !bytes.is_empty() => {
                <chrono::NaiveDateTime as DmDecode>::decode(Some(bytes)).map(Some)
            }
            _ => Ok(None),
        }
    }
}

// ─── QueryRow methods ───────────────────────────────────────────────────────

impl QueryRow {
    /// Get a decoded value at the given column index.
    ///
    /// Supports SQLx-style type inference:
    /// ```ignore
    /// let id: i32 = row.get(0)?;
    /// let name: &str = row.get(1)?;
    /// let addr: Option<&str> = row.get(2)?;
    /// ```
    pub fn get<'de, T: DmDecode<'de>>(&'de self, idx: usize) -> crate::error::Result<T> {
        let value = self.row.values.get(idx).and_then(|v| v.as_deref());
        T::decode(value)
    }
}

impl<'a> QueryRowRef<'a> {
    /// Get a decoded value at the given column index.
    pub fn get<'de, T: DmDecode<'de>>(&'de self, idx: usize) -> crate::error::Result<T>
    where
        'a: 'de,
    {
        let value = self.row.values.get(idx).and_then(|v| v.as_deref());
        T::decode(value)
    }
}

// ─── ResultSet methods ──────────────────────────────────────────────────────

impl ResultSet {
    /// Create a new empty result set.
    pub fn new() -> Self {
        Self {
            columns: vec![],
            rows: vec![],
            cursor_id: 0,
            total_row_count: 0,
        }
    }

    /// Create a result set with the given data.
    pub fn with_data(
        columns: Vec<Column>,
        rows: Vec<Row>,
        cursor_id: i16,
        total_row_count: u64,
    ) -> Self {
        Self {
            columns,
            rows,
            cursor_id,
            total_row_count,
        }
    }

    /// Check if the result set is empty.
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    /// Get the number of rows.
    pub fn len(&self) -> usize {
        self.rows.len()
    }

    /// Get the first row, if any (returns a QueryRowRef with column metadata).
    pub fn first(&self) -> Option<QueryRowRef<'_>> {
        self.rows.first().map(|row| QueryRowRef {
            row,
            columns: &self.columns,
        })
    }

    /// Iterate over rows with column metadata (borrowing).
    ///
    /// Supports SQLx-style type inference:
    /// ```ignore
    /// for row in rs.iter() {
    ///     let id: i32 = row.get(0)?;
    ///     let name: &str = row.get(1)?;
    /// }
    /// ```
    ///
    /// Also supports protocol-level methods via `Deref`:
    /// ```ignore
    /// for row in rs.iter() {
    ///     let id = row.get_i32(0)?;
    ///     let name = row.get_str(1)?;
    /// }
    /// ```
    pub fn iter(&self) -> ResultSetIter<'_> {
        ResultSetIter {
            result_set: self,
            current: 0,
        }
    }

    /// Iterate over rows with access to column metadata (borrowing).
    /// Alias for `iter()`.
    pub fn iter_rows(&self) -> ResultSetIter<'_> {
        self.iter()
    }

    /// Get column metadata by name.
    pub fn column_by_name(&self, name: &str) -> Option<&Column> {
        self.columns.iter().find(|c| c.name == name)
    }

    /// Check if there are more rows to fetch.
    pub fn has_more(&self) -> bool {
        self.rows.len() < self.total_row_count as usize
    }

    /// Get the next fetch start position.
    pub fn next_fetch_start(&self) -> usize {
        self.rows.len()
    }
}

impl Default for ResultSet {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_row_empty() {
        let row = Row {
            row_id: 0,
            values: vec![],
        };
        assert!(row.is_empty());
        assert_eq!(row.len(), 0);
    }

    #[test]
    fn test_result_set_empty() {
        let rs = ResultSet::new();
        assert!(rs.is_empty());
        assert_eq!(rs.len(), 0);
    }

    #[test]
    fn test_query_row_get_i32() {
        let qrow = QueryRow {
            row: Row {
                row_id: 0,
                values: vec![Some(vec![100, 0, 0, 0])],
            },
            columns: vec![],
        };
        assert_eq!(qrow.get::<i32>(0).unwrap(), 100);
    }

    #[test]
    fn test_query_row_get_str() {
        let qrow = QueryRow {
            row: Row {
                row_id: 0,
                values: vec![Some(b"Alice".to_vec())],
            },
            columns: vec![],
        };
        assert_eq!(qrow.get::<&str>(0).unwrap(), "Alice");
    }

    #[test]
    fn test_query_row_get_option() {
        let qrow = QueryRow {
            row: Row {
                row_id: 0,
                values: vec![None, Some(vec![1, 0, 0, 0])],
            },
            columns: vec![],
        };
        assert_eq!(qrow.get::<Option<i32>>(0).unwrap(), None);
        assert_eq!(qrow.get::<Option<i32>>(1).unwrap(), Some(1));
    }

    #[test]
    fn test_query_row_get_opt_str() {
        let qrow = QueryRow {
            row: Row {
                row_id: 0,
                values: vec![None, Some(b"Alice".to_vec())],
            },
            columns: vec![],
        };
        assert_eq!(qrow.get::<Option<&str>>(0).unwrap(), None);
        assert_eq!(qrow.get::<Option<&str>>(1).unwrap(), Some("Alice"));
    }

    #[test]
    fn test_result_set_into_iter() {
        let rs = ResultSet::with_data(
            vec![],
            vec![
                Row {
                    row_id: 0,
                    values: vec![Some(vec![1, 0, 0, 0])],
                },
                Row {
                    row_id: 1,
                    values: vec![Some(vec![2, 0, 0, 0])],
                },
            ],
            0,
            2,
        );
        let ids: Vec<i32> = rs.into_iter().map(|r| r.get::<i32>(0).unwrap()).collect();
        assert_eq!(ids, vec![1, 2]);
    }

    #[test]
    fn test_query_row_get_u32() {
        let qrow = QueryRow {
            row: Row {
                row_id: 0,
                values: vec![Some(vec![100, 0, 0, 0])],
            },
            columns: vec![],
        };
        assert_eq!(qrow.get::<u32>(0).unwrap(), 100u32);
    }

    #[test]
    fn test_query_row_get_u64() {
        let qrow = QueryRow {
            row: Row {
                row_id: 0,
                values: vec![Some(vec![0xe8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])],
            },
            columns: vec![],
        };
        assert_eq!(qrow.get::<u64>(0).unwrap(), 1000u64);
    }

    #[test]
    fn test_query_row_get_bool() {
        let qrow = QueryRow {
            row: Row {
                row_id: 0,
                values: vec![Some(vec![1]), Some(vec![0])],
            },
            columns: vec![],
        };
        assert_eq!(qrow.get::<bool>(0).unwrap(), true);
        assert_eq!(qrow.get::<bool>(1).unwrap(), false);
    }

    #[test]
    fn test_query_row_deref_get_str() {
        // Test that Deref<Target=Row> works for protocol-level methods
        let qrow = QueryRow {
            row: Row {
                row_id: 0,
                values: vec![Some(b"Hello".to_vec())],
            },
            columns: vec![],
        };
        // get_str is on Row, accessible via row.field
        assert_eq!(qrow.row.get_str(0).unwrap(), "Hello");
    }

    #[test]
    fn test_result_set_iter_deref() {
        // Test that rs.iter() returning QueryRowRef still supports
        // protocol-level methods via Deref
        let rs = ResultSet::with_data(
            vec![],
            vec![Row {
                row_id: 0,
                values: vec![Some(vec![1, 0, 0, 0]), Some(b"Alice".to_vec())],
            }],
            0,
            1,
        );
        for row in rs.iter() {
            let id = row.get_i32(0).unwrap();
            let name = row.get_str(1).unwrap();
            assert_eq!(id, 1);
            assert_eq!(name, "Alice");
        }
    }
}
