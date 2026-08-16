//! Dameng database type definitions and conversions.
//!
//! This crate provides type mappings between Dameng database types
//! and Rust native types, along with encoding/decoding utilities.


pub mod encoding;
pub use encoding::{decode_from_server, encode_to_server, ServerEncoding};

/// Dameng SQL value type enum.
///
/// Maps DM type codes to Rust types for encoding and decoding.
#[allow(non_camel_case_types)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DmValueType {
    BIT,          // 1
    TINYINT,      // 2
    VARCHAR,      // 3
    INT,          // 4
    BIGINT,       // 5
    SMALLINT,     // 6
    FLOAT,        // 7
    DOUBLE,       // 8
    DECIMAL,      // 9
    DATE,         // 10
    TIME,         // 11
    TIMESTAMP,    // 12
    BLOB,         // 13
    CLOB,         // 14
    INTERVAL,     // 15
    CHAR,         // 16
    BINARY,       // 17
    VARBINARY,    // 18
    NUMERIC,      // 20 - alias for DECIMAL
    BOOLEAN,      // 21 - alias for BIT
    DATETIME,     // 22 - alias for TIMESTAMP
    VARCHAR2,     // 23 - alias for VARCHAR
    DATETIME2,    // 24 - alias for TIMESTAMP
    TIME_TZ,      // 25 - time with time zone
    DATETIME_TZ,  // 26 - timestamp with time zone
    INTERVAL_YM,  // 27 - interval year to month
    INTERVAL_DT,  // 28 - interval day to second
    RAW,          // 29 - alias for BINARY
    DATETIME2_TZ, // 30 - timestamp2 with time zone
    REAL,         // 31 - alias for FLOAT
}

impl DmValueType {
    /// Create a DmValueType from a DM type code.
    pub fn from_type_code(code: i32) -> Option<Self> {
        match code {
            1 => Some(DmValueType::BIT),
            2 => Some(DmValueType::TINYINT),
            3 => Some(DmValueType::VARCHAR),
            4 => Some(DmValueType::INT),
            5 => Some(DmValueType::BIGINT),
            6 => Some(DmValueType::SMALLINT),
            7 => Some(DmValueType::FLOAT),
            8 => Some(DmValueType::DOUBLE),
            9 => Some(DmValueType::DECIMAL),
            10 => Some(DmValueType::DATE),
            11 => Some(DmValueType::TIME),
            12 => Some(DmValueType::TIMESTAMP),
            13 => Some(DmValueType::BLOB),
            14 => Some(DmValueType::CLOB),
            15 => Some(DmValueType::INTERVAL),
            16 => Some(DmValueType::CHAR),
            17 => Some(DmValueType::BINARY),
            18 => Some(DmValueType::VARBINARY),
            20 => Some(DmValueType::NUMERIC),
            21 => Some(DmValueType::BOOLEAN),
            22 => Some(DmValueType::DATETIME),
            23 => Some(DmValueType::VARCHAR2),
            24 => Some(DmValueType::DATETIME2),
            25 => Some(DmValueType::TIME_TZ),
            26 => Some(DmValueType::DATETIME_TZ),
            27 => Some(DmValueType::INTERVAL_YM),
            28 => Some(DmValueType::INTERVAL_DT),
            29 => Some(DmValueType::RAW),
            30 => Some(DmValueType::DATETIME2_TZ),
            31 => Some(DmValueType::REAL),
            _ => None,
        }
    }

    /// Get the DM type code for this value type.
    pub fn type_code(self) -> i32 {
        match self {
            DmValueType::BIT => 1,
            DmValueType::TINYINT => 2,
            DmValueType::VARCHAR => 3,
            DmValueType::INT => 4,
            DmValueType::BIGINT => 5,
            DmValueType::SMALLINT => 6,
            DmValueType::FLOAT => 7,
            DmValueType::DOUBLE => 8,
            DmValueType::DECIMAL => 9,
            DmValueType::DATE => 10,
            DmValueType::TIME => 11,
            DmValueType::TIMESTAMP => 12,
            DmValueType::BLOB => 13,
            DmValueType::CLOB => 14,
            DmValueType::INTERVAL => 15,
            DmValueType::CHAR => 16,
            DmValueType::BINARY => 17,
            DmValueType::VARBINARY => 18,
            DmValueType::NUMERIC => 20,
            DmValueType::BOOLEAN => 21,
            DmValueType::DATETIME => 22,
            DmValueType::VARCHAR2 => 23,
            DmValueType::DATETIME2 => 24,
            DmValueType::TIME_TZ => 25,
            DmValueType::DATETIME_TZ => 26,
            DmValueType::INTERVAL_YM => 27,
            DmValueType::INTERVAL_DT => 28,
            DmValueType::RAW => 29,
            DmValueType::DATETIME2_TZ => 30,
            DmValueType::REAL => 31,
        }
    }

    /// Get the type name string for protocol messages.
    pub fn type_name(self) -> &'static str {
        match self {
            DmValueType::BIT => "BIT",
            DmValueType::TINYINT => "TINYINT",
            DmValueType::VARCHAR => "VARCHAR",
            DmValueType::INT => "INT",
            DmValueType::BIGINT => "BIGINT",
            DmValueType::SMALLINT => "SMALLINT",
            DmValueType::FLOAT => "FLOAT",
            DmValueType::DOUBLE => "DOUBLE",
            DmValueType::DECIMAL => "DECIMAL",
            DmValueType::DATE => "DATE",
            DmValueType::TIME => "TIME",
            DmValueType::TIMESTAMP => "TIMESTAMP",
            DmValueType::BLOB => "BLOB",
            DmValueType::CLOB => "CLOB",
            DmValueType::INTERVAL => "INTERVAL",
            DmValueType::CHAR => "CHAR",
            DmValueType::BINARY => "BINARY",
            DmValueType::VARBINARY => "VARBINARY",
            DmValueType::NUMERIC => "NUMERIC",
            DmValueType::BOOLEAN => "BOOLEAN",
            DmValueType::DATETIME => "DATETIME",
            DmValueType::VARCHAR2 => "VARCHAR2",
            DmValueType::DATETIME2 => "DATETIME2",
            DmValueType::TIME_TZ => "TIME_TZ",
            DmValueType::DATETIME_TZ => "DATETIME_TZ",
            DmValueType::INTERVAL_YM => "INTERVAL_YM",
            DmValueType::INTERVAL_DT => "INTERVAL_DT",
            DmValueType::RAW => "RAW",
            DmValueType::DATETIME2_TZ => "DATETIME2_TZ",
            DmValueType::REAL => "REAL",
        }
    }
}

/// A decoded DM value.
#[derive(Debug, Clone, PartialEq)]
pub enum DmValue {
    Null,
    Boolean(bool),
    TinyInt(i8),
    SmallInt(i16),
    Int(i32),
    BigInt(i64),
    Float(f32),
    Double(f64),
    Text(String),
    Bytea(Vec<u8>),
    Decimal(rust_decimal::Decimal),
    /// DATE value (chrono::NaiveDate).
    Date(chrono::NaiveDate),
    /// TIME value (chrono::NaiveTime).
    Time(chrono::NaiveTime),
    /// TIMESTAMP / DATETIME value (chrono::NaiveDateTime).
    Timestamp(chrono::NaiveDateTime),
    /// LOB_LOCATOR: DM server returns a 16-byte locator handle when CLOB/BLOB
    /// data exceeds 2048 bytes. The actual content must be fetched via LOBREAD
    /// protocol messages. This variant stores the raw 16-byte locator.
    LobLocator(LobLocator),
}

/// A LOB (Large Object) locator returned by the DM server.
///
/// When CLOB/BLOB data exceeds 2048 bytes, DM returns a 16-byte locator
/// instead of the actual data. The locator contains server-side pointers
/// (table ID, column ID, row ID, group/file/page numbers) that can be
/// used with LOBREAD protocol messages to fetch the actual content.
#[derive(Debug, Clone, PartialEq)]
pub struct LobLocator {
    /// Raw NBLOB_HEAD bytes from DM server (may be >16 for new LOB format).
    pub raw: Vec<u8>,
    /// Whether this is a CLOB (true) or BLOB (false).
    pub is_clob: bool,
    /// Table ID from column metadata or NBLOB_HEAD extended section.
    /// Used by LOBREAD protocol to locate the LOB data on the server.
    pub tab_id: i32,
    /// Column ID from column metadata.
    /// Used by LOBREAD protocol to locate the LOB data on the server.
    pub col_id: i16,
    /// Current file ID for LOBREAD cursor tracking. Updated after each read.
    pub cur_file_id: i16,
    /// Current page number for LOBREAD cursor tracking. Updated after each read.
    pub cur_page_no: i32,
    /// Accumulated offset for LOBREAD cursor tracking. Updated after each read.
    pub total_offset: i32,
}

#[allow(unused)]
impl LobLocator {
    /// NBLOB_HEAD offsets (matching dm_go constants).
    /// NBLOB_HEAD_IN_ROW_FLAG = 0 (1 byte)
    /// NBLOB_HEAD_BLOBID = 1 (8 bytes)
    /// NBLOB_HEAD_BLOB_LEN = 9 (4 bytes)
    /// NBLOB_HEAD_OUTROW_GROUPID = 13 (2 bytes - USINT)
    /// NBLOB_HEAD_OUTROW_FILEID = 15 (2 bytes - USINT)
    /// NBLOB_HEAD_OUTROW_PAGENO = 17 (4 bytes - ULINT)
    /// NBLOB_EX_HEAD_TABLE_ID = 21 (4 bytes - ULINT)
    /// NBLOB_EX_HEAD_COL_ID = 25 (2 bytes - USINT)
    /// NBLOB_EX_HEAD_ROW_ID = 27 (8 bytes - DDWORD)
    /// NBLOB_EX_HEAD_FPA_GRPID = 35 (2 bytes - USINT)
    /// NBLOB_EX_HEAD_FPA_FILEID = 37 (2 bytes - USINT)
    /// NBLOB_EX_HEAD_FPA_PAGENO = 39 (4 bytes - ULINT)
    const IN_ROW_FLAG: usize = 0;
    const BLOBID: usize = 1;
    const BLOB_LEN: usize = 9;
    const GROUPID: usize = 13;
    const FILEID: usize = 15;
    const PAGENO: usize = 17;
    const EX_TABLE_ID: usize = 21;
    const EX_COL_ID: usize = 25;
    const EX_ROW_ID: usize = 27;
    const EX_FPA_GRPID: usize = 35;
    const EX_FPA_FILEID: usize = 37;
    const EX_FPA_PAGENO: usize = 39;

    /// Create a LOB locator from NBLOB_HEAD raw bytes returned by DM server.
    ///
    /// NBLOB_HEAD layout (out-of-row):
    /// - Off 0:  in_row_flag (1 byte, 0x02 = out-of-row)
    /// - Off 1:  blob_id (8 bytes LE i64)
    /// - Off 9:  group_id (2 bytes LE i16)
    /// - Off 11: file_id (2 bytes LE i16)
    /// - Off 13: page_no (4 bytes LE i32)
    /// - Off 17: (extended section if present)
    /// - Off 21: tab_id (4 bytes LE i32)
    /// - Off 25: col_id (2 bytes LE i16)
    /// - Off 27: row_id (8 bytes LE i64)
    ///
    /// tab_id and col_id can also come from the column metadata in the
    /// EXEC_RESPONSE header (parsed separately), in which case use
    /// `with_tab_col_id()` to set them.
    pub fn from_nblob_head(data: Vec<u8>, is_clob: bool) -> Self {
        let mut tab_id = 0;
        let mut col_id = 0;

        // Try to extract tab_id/col_id from extended NBLOB_HEAD section
        if data.len() >= 29 {
            tab_id = i32::from_le_bytes([
                data[Self::EX_TABLE_ID],
                data[Self::EX_TABLE_ID + 1],
                data[Self::EX_TABLE_ID + 2],
                data[Self::EX_TABLE_ID + 3],
            ]);
            col_id = i16::from_le_bytes([data[Self::EX_COL_ID], data[Self::EX_COL_ID + 1]]);
        }

        Self {
            raw: data,
            is_clob,
            tab_id,
            col_id,
            cur_file_id: 0,
            cur_page_no: 0,
            total_offset: 0,
        }
    }

    /// Set tab_id/col_id from column metadata (overrides NBLOB_HEAD values).
    /// This is called by the response parser after reading the column header.
    pub fn with_tab_col_id(mut self, tab_id: i32, col_id: i16) -> Self {
        self.tab_id = tab_id;
        self.col_id = col_id;
        self
    }

    /// Get the lob_flag value: 0 = BLOB (byte), 1 = CLOB (char).
    pub fn lob_flag(&self) -> u8 {
        if self.is_clob {
            1
        } else {
            0
        }
    }

    /// Get the blob_id from the NBLOB_HEAD format (offset 1, 8 bytes LE).
    pub fn blob_id(&self) -> i64 {
        if self.raw.len() >= Self::BLOBID + 8 {
            let bytes: [u8; 8] = self.raw[Self::BLOBID..Self::BLOBID + 8].try_into().unwrap();
            i64::from_le_bytes(bytes)
        } else {
            0
        }
    }

    /// Get the group ID for out-of-row locators (offset 13, 2 bytes LE i16).
    pub fn group_id(&self) -> i16 {
        if self.raw.len() >= Self::GROUPID + 2 {
            i16::from_le_bytes([self.raw[Self::GROUPID], self.raw[Self::GROUPID + 1]])
        } else {
            -1
        }
    }

    /// Get the file ID for out-of-row locators (offset 15, 2 bytes LE i16).
    pub fn file_id(&self) -> i16 {
        if self.raw.len() >= Self::FILEID + 2 {
            i16::from_le_bytes([self.raw[Self::FILEID], self.raw[Self::FILEID + 1]])
        } else {
            -1
        }
    }

    /// Get the page number for out-of-row locators (offset 17, 4 bytes LE i32).
    pub fn page_no(&self) -> i32 {
        if self.raw.len() >= Self::PAGENO + 4 {
            let bytes: [u8; 4] = self.raw[Self::PAGENO..Self::PAGENO + 4].try_into().unwrap();
            i32::from_le_bytes(bytes)
        } else {
            -1
        }
    }

    /// Get the row_id from extended section (offset 27, 8 bytes LE i64).
    pub fn row_id(&self) -> i64 {
        if self.raw.len() >= Self::EX_ROW_ID + 8 {
            let bytes: [u8; 8] = self.raw[Self::EX_ROW_ID..Self::EX_ROW_ID + 8]
                .try_into()
                .unwrap();
            i64::from_le_bytes(bytes)
        } else {
            0
        }
    }

    /// Get the extended group ID (offset 35, 2 bytes LE i16).
    pub fn ex_group_id(&self) -> i16 {
        if self.raw.len() >= Self::EX_FPA_GRPID + 2 {
            i16::from_le_bytes([
                self.raw[Self::EX_FPA_GRPID],
                self.raw[Self::EX_FPA_GRPID + 1],
            ])
        } else {
            0
        }
    }

    /// Get the extended file ID (offset 37, 2 bytes LE i16).
    pub fn ex_file_id(&self) -> i16 {
        if self.raw.len() >= Self::EX_FPA_FILEID + 2 {
            i16::from_le_bytes([
                self.raw[Self::EX_FPA_FILEID],
                self.raw[Self::EX_FPA_FILEID + 1],
            ])
        } else {
            0
        }
    }

    /// Get the extended page number (offset 39, 4 bytes LE i32).
    pub fn ex_page_no(&self) -> i32 {
        if self.raw.len() >= Self::EX_FPA_PAGENO + 4 {
            let bytes: [u8; 4] = self.raw[Self::EX_FPA_PAGENO..Self::EX_FPA_PAGENO + 4]
                .try_into()
                .unwrap();
            i32::from_le_bytes(bytes)
        } else {
            0
        }
    }

    /// Check if extended section is present (NewLobFlag).
    pub fn has_extended(&self) -> bool {
        self.raw.len() >= Self::EX_TABLE_ID + 4
    }

    /// Update the cursor state from a LOBREAD response.
    ///
    /// After each LOBREAD, the server returns updated `curFileId`, `curPageNo`,
    /// and `totalOffset` values. This method updates the locator so subsequent
    /// reads continue from the correct position.
    ///
    /// This is a mutable reference — clone the locator before calling this
    /// if you need to preserve the original.
    pub fn update_cursor(&mut self, cur_file_id: i16, cur_page_no: i32, total_offset: i32) {
        self.cur_file_id = cur_file_id;
        self.cur_page_no = cur_page_no;
        self.total_offset = total_offset;
    }

    /// Initialize cursor from the initial LOB locator values.
    ///
    /// On the first read, `curFileId` = `fileId` and `curPageNo` = `pageNo`.
    pub fn init_cursor(&mut self) {
        self.cur_file_id = self.file_id();
        self.cur_page_no = self.page_no();
        self.total_offset = 0;
    }
}

impl From<i32> for DmValue {
    fn from(v: i32) -> Self {
        DmValue::Int(v)
    }
}

impl From<i64> for DmValue {
    fn from(v: i64) -> Self {
        DmValue::BigInt(v)
    }
}

impl From<String> for DmValue {
    fn from(v: String) -> Self {
        DmValue::Text(v)
    }
}

impl From<&str> for DmValue {
    fn from(v: &str) -> Self {
        DmValue::Text(v.to_string())
    }
}

impl From<bool> for DmValue {
    fn from(v: bool) -> Self {
        DmValue::Boolean(v)
    }
}

impl From<f64> for DmValue {
    fn from(v: f64) -> Self {
        DmValue::Double(v)
    }
}

impl From<Vec<u8>> for DmValue {
    fn from(v: Vec<u8>) -> Self {
        DmValue::Bytea(v)
    }
}

// --- Option<T> From impls ---

impl From<Option<i8>> for DmValue {
    fn from(v: Option<i8>) -> Self {
        v.map(DmValue::TinyInt).unwrap_or(DmValue::Null)
    }
}

impl From<Option<i16>> for DmValue {
    fn from(v: Option<i16>) -> Self {
        v.map(DmValue::SmallInt).unwrap_or(DmValue::Null)
    }
}

impl From<Option<i32>> for DmValue {
    fn from(v: Option<i32>) -> Self {
        v.map(DmValue::Int).unwrap_or(DmValue::Null)
    }
}

impl From<Option<i64>> for DmValue {
    fn from(v: Option<i64>) -> Self {
        v.map(DmValue::BigInt).unwrap_or(DmValue::Null)
    }
}

impl From<Option<f32>> for DmValue {
    fn from(v: Option<f32>) -> Self {
        v.map(DmValue::Float).unwrap_or(DmValue::Null)
    }
}

impl From<Option<f64>> for DmValue {
    fn from(v: Option<f64>) -> Self {
        v.map(DmValue::Double).unwrap_or(DmValue::Null)
    }
}

impl From<Option<String>> for DmValue {
    fn from(v: Option<String>) -> Self {
        v.map(DmValue::Text).unwrap_or(DmValue::Null)
    }
}

impl From<Option<&str>> for DmValue {
    fn from(v: Option<&str>) -> Self {
        v.map(|s| s.to_string())
            .map(DmValue::Text)
            .unwrap_or(DmValue::Null)
    }
}

impl From<Option<bool>> for DmValue {
    fn from(v: Option<bool>) -> Self {
        v.map(DmValue::Boolean).unwrap_or(DmValue::Null)
    }
}

impl From<Option<Vec<u8>>> for DmValue {
    fn from(v: Option<Vec<u8>>) -> Self {
        v.map(DmValue::Bytea).unwrap_or(DmValue::Null)
    }
}

/// Trait for dynamic parameter binding — SQLx-style `&[&dyn ToDmValue]` support.
///
/// # Example
///
/// ```ignore
/// let name = "Alice";
/// let age: i32 = 30;
/// let rows = client.query_with_params(
///     "SELECT * FROM person WHERE name = ? AND age > ?",
///     &[&name, &age],
/// )?;
/// ```
pub trait ToDmValue {
    /// Convert this value into a `DmValue`.
    fn to_dm_value(&self) -> DmValue;
}

// --- ToDmValue implementations for concrete types ---

macro_rules! impl_to_dm_value {
    ($($ty:ty => $variant:ident),* $(,)?) => {
        $(
            impl ToDmValue for $ty {
                fn to_dm_value(&self) -> DmValue {
                    DmValue::$variant(*self)
                }
            }
        )*
    };
}

impl_to_dm_value!(
    bool => Boolean,
    i8 => TinyInt,
    i16 => SmallInt,
    i32 => Int,
    i64 => BigInt,
    f32 => Float,
    f64 => Double,
);

impl ToDmValue for u8 {
    fn to_dm_value(&self) -> DmValue {
        DmValue::TinyInt(*self as i8)
    }
}

impl ToDmValue for u16 {
    fn to_dm_value(&self) -> DmValue {
        DmValue::SmallInt(*self as i16)
    }
}

impl ToDmValue for u32 {
    fn to_dm_value(&self) -> DmValue {
        if *self <= i32::MAX as u32 {
            DmValue::Int(*self as i32)
        } else {
            DmValue::BigInt(*self as i64)
        }
    }
}

impl ToDmValue for u64 {
    fn to_dm_value(&self) -> DmValue {
        if *self <= i64::MAX as u64 {
            DmValue::BigInt(*self as i64)
        } else {
            DmValue::Text(self.to_string())
        }
    }
}

// Blanket impl: `&T` where `T: ToDmValue` delegates to T.
// This lets `&[&id, &name]` work when `name: &str` (producing `&&str`).
impl<T: ToDmValue + ?Sized> ToDmValue for &T {
    fn to_dm_value(&self) -> DmValue {
        T::to_dm_value(*self)
    }
}

impl ToDmValue for str {
    fn to_dm_value(&self) -> DmValue {
        DmValue::Text(self.to_string())
    }
}

impl ToDmValue for String {
    fn to_dm_value(&self) -> DmValue {
        DmValue::Text(self.clone())
    }
}

impl ToDmValue for [u8] {
    fn to_dm_value(&self) -> DmValue {
        DmValue::Bytea(self.to_vec())
    }
}

impl ToDmValue for Vec<u8> {
    fn to_dm_value(&self) -> DmValue {
        DmValue::Bytea(self.clone())
    }
}

// --- Option<T> implementations ---

macro_rules! impl_option_to_dm_value {
    ($($ty:ty),* $(,)?) => {
        $(
            impl ToDmValue for Option<$ty> {
                fn to_dm_value(&self) -> DmValue {
                    match self {
                        Some(v) => v.to_dm_value(),
                        None => DmValue::Null,
                    }
                }
            }
        )*
    };
}

impl_option_to_dm_value!(bool, i8, i16, i32, i64, f32, f64, String);
impl_option_to_dm_value!(rust_decimal::Decimal);
impl_option_to_dm_value!(chrono::NaiveDate);
impl_option_to_dm_value!(chrono::NaiveDateTime);

impl ToDmValue for Option<&str> {
    fn to_dm_value(&self) -> DmValue {
        self.map(|s| s.to_string())
            .map(DmValue::Text)
            .unwrap_or(DmValue::Null)
    }
}

impl ToDmValue for Option<Vec<u8>> {
    fn to_dm_value(&self) -> DmValue {
        self.clone().map(DmValue::Bytea).unwrap_or(DmValue::Null)
    }
}

// --- ToDmValue for chrono / rust_decimal types ---

impl ToDmValue for rust_decimal::Decimal {
    fn to_dm_value(&self) -> DmValue {
        DmValue::Decimal(*self)
    }
}

impl ToDmValue for chrono::NaiveDate {
    fn to_dm_value(&self) -> DmValue {
        DmValue::Date(*self)
    }
}

impl ToDmValue for chrono::NaiveTime {
    fn to_dm_value(&self) -> DmValue {
        DmValue::Time(*self)
    }
}

impl ToDmValue for chrono::NaiveDateTime {
    fn to_dm_value(&self) -> DmValue {
        DmValue::Timestamp(*self)
    }
}

/// Encode a Rust value to DM protocol bytes.
pub fn encode_value(ty: DmValueType, value: &DmValue) -> Vec<u8> {
    match ty {
        DmValueType::INT => {
            if let DmValue::Int(v) = value {
                v.to_le_bytes().to_vec()
            } else {
                vec![0; 4]
            }
        }
        DmValueType::BIGINT => {
            if let DmValue::BigInt(v) = value {
                v.to_le_bytes().to_vec()
            } else {
                vec![0; 8]
            }
        }
        DmValueType::SMALLINT => {
            if let DmValue::SmallInt(v) = value {
                v.to_le_bytes().to_vec()
            } else {
                vec![0; 2]
            }
        }
        DmValueType::FLOAT | DmValueType::REAL => {
            // Always 4 bytes
            if let DmValue::Float(v) = value {
                v.to_le_bytes().to_vec()
            } else if let DmValue::Double(v) = value {
                (*v as f32).to_le_bytes().to_vec()
            } else {
                vec![0u8; 4]
            }
        }
        DmValueType::DOUBLE => {
            // Always 8 bytes
            if let DmValue::Double(v) = value {
                v.to_le_bytes().to_vec()
            } else if let DmValue::Float(v) = value {
                (*v as f64).to_le_bytes().to_vec()
            } else {
                vec![0u8; 8]
            }
        }
        DmValueType::BIT | DmValueType::BOOLEAN => {
            if let DmValue::Boolean(v) = value {
                vec![if *v { 1 } else { 0 }]
            } else {
                vec![0]
            }
        }
        DmValueType::VARCHAR | DmValueType::CHAR | DmValueType::CLOB | DmValueType::VARCHAR2 => {
            if let DmValue::Text(v) = value {
                v.as_bytes().to_vec()
            } else {
                vec![]
            }
        }
        DmValueType::BLOB | DmValueType::BINARY | DmValueType::VARBINARY | DmValueType::RAW => {
            if let DmValue::Bytea(v) = value {
                v.clone()
            } else {
                vec![]
            }
        }
        DmValueType::DECIMAL | DmValueType::NUMERIC => {
            if let DmValue::Decimal(v) = value {
                v.to_string().as_bytes().to_vec()
            } else {
                vec![]
            }
        }
        DmValueType::TINYINT => {
            if let DmValue::TinyInt(v) = value {
                v.to_le_bytes().to_vec()
            } else {
                vec![0]
            }
        }
        DmValueType::DATE
        | DmValueType::TIME
        | DmValueType::TIMESTAMP
        | DmValueType::DATETIME
        | DmValueType::DATETIME2
        | DmValueType::TIME_TZ
        | DmValueType::DATETIME_TZ
        | DmValueType::DATETIME2_TZ => {
            if let DmValue::Date(d) = value {
                d.format("%Y-%m-%d").to_string().as_bytes().to_vec()
            } else if let DmValue::Time(t) = value {
                t.format("%H:%M:%S").to_string().as_bytes().to_vec()
            } else if let DmValue::Timestamp(ts) = value {
                ts.format("%Y-%m-%d %H:%M:%S")
                    .to_string()
                    .as_bytes()
                    .to_vec()
            } else if let DmValue::Text(v) = value {
                v.as_bytes().to_vec()
            } else {
                vec![]
            }
        }
        // Generic INTERVAL (type_code=15) — send as text, server parses it.
        DmValueType::INTERVAL => {
            if let DmValue::Text(v) = value {
                v.as_bytes().to_vec()
            } else {
                vec![]
            }
        }
        // INTERVAL_YM (type_code=27): year-month interval, 12 bytes.
        // Binary layout: year(LE i32, 4) + month(LE i32, 4) + padding(4).
        // Text input: "Y-M" (e.g., "1-2" = 1 year 2 months) or just "Y".
        DmValueType::INTERVAL_YM => {
            if let DmValue::Text(v) = value {
                encode_interval_ym(v)
            } else {
                vec![0; 12]
            }
        }
        // INTERVAL_DT (type_code=28): day-time interval, 24 bytes.
        // Binary layout: day(LE i32, 4) + hour(LE i32, 4) + minute(LE i32, 4)
        //                  + second(LE i32, 4) + nanoseconds(LE i64, 8).
        // Text input: "D HH:MI:SS.FF" (e.g., "1 2:3:4.5" = 1 day, 2h 3m 4.5s)
        //            or "HH:MI:SS.FF" (day defaults to 0).
        DmValueType::INTERVAL_DT => {
            if let DmValue::Text(v) = value {
                encode_interval_dt(v)
            } else {
                vec![0; 24]
            }
        }
    }
}

/// Encode an INTERVAL YEAR TO MONTH text string to DM binary format (12 bytes).
///
/// Binary layout: year(LE i32, 4) + month(LE i32, 4) + padding(4 zero bytes).
///
/// Accepted text formats:
/// - "Y-M"  (e.g., "1-2" = 1 year 2 months)
/// - "+Y-M" or "-Y-M" for signed intervals
/// - "Y"     (months default to 0)
fn encode_interval_ym(s: &str) -> Vec<u8> {
    let mut year: i32 = 0;
    let mut month: i32 = 0;

    let trimmed = s.trim();
    let (sign, rest) = if let Some(stripped) = trimmed.strip_prefix('+') {
        (1i32, stripped.trim())
    } else if let Some(stripped) = trimmed.strip_prefix('-') {
        (-1, stripped.trim())
    } else {
        (1, trimmed)
    };

    if let Some((y_str, m_str)) = rest.split_once('-') {
        if let Ok(y) = y_str.trim().parse::<i32>() {
            year = y;
        }
        if let Ok(m) = m_str.trim().parse::<i32>() {
            month = m;
        }
    } else if let Ok(y) = rest.trim().parse::<i32>() {
        year = y;
    }

    let mut buf = Vec::with_capacity(12);
    buf.extend_from_slice(&(year * sign).to_le_bytes());
    buf.extend_from_slice(&(month * sign).to_le_bytes());
    buf.extend_from_slice(&[0, 0, 0, 0]);
    buf
}

/// Encode an INTERVAL DAY TO SECOND text string to DM binary format (24 bytes).
///
/// Binary layout: day(LE i32, 4) + hour(LE i32, 4) + minute(LE i32, 4)
///                  + second(LE i32, 4) + nanoseconds(LE i64, 8).
///
/// Accepted text formats:
/// - "D HH:MI:SS.FF"   (e.g., "1 2:3:4.5" = 1 day, 2h 3m 4.5s)
/// - "HH:MI:SS.FF"     (day defaults to 0)
/// - "+D HH:MI:SS.FF" or "-D HH:MI:SS.FF" for signed intervals
fn encode_interval_dt(s: &str) -> Vec<u8> {
    let mut day: i32 = 0;
    let mut hour: i32 = 0;
    let mut minute: i32 = 0;
    let mut second: i32 = 0;
    let mut nanosecond: i64 = 0;

    let trimmed = s.trim();
    let (sign, rest) = if let Some(stripped) = trimmed.strip_prefix('+') {
        (1i32, stripped.trim())
    } else if let Some(stripped) = trimmed.strip_prefix('-') {
        (-1, stripped.trim())
    } else {
        (1, trimmed)
    };

    // Try "D HH:MI:SS.FF" format first
    let rest_for_parse = if rest.contains(' ') {
        // "D HH:MI:SS.FF" — extract day
        if let Some((d_part, time_part)) = rest.split_once(' ') {
            if let Ok(d) = d_part.trim().parse::<i32>() {
                day = d;
            }
            time_part.trim()
        } else {
            rest
        }
    } else {
        rest
    };

    // Parse HH:MI:SS.FF
    if let Some((time, frac_str)) = rest_for_parse.split_once('.') {
        let parts: Vec<&str> = time.split(':').collect();
        if parts.len() >= 3 {
            if let Ok(h) = parts[0].parse::<i32>() {
                hour = h;
            }
            if let Ok(m) = parts[1].parse::<i32>() {
                minute = m;
            }
            if let Ok(s_val) = parts[2].parse::<i32>() {
                second = s_val;
            }
        } else if parts.len() == 2 {
            if let Ok(h) = parts[0].parse::<i32>() {
                hour = h;
            }
            if let Ok(m) = parts[1].parse::<i32>() {
                minute = m;
            }
        }
        // Nanoseconds from fractional seconds (scale the fractional digits)
        if let Ok(f) = frac_str.parse::<f64>() {
            nanosecond = (f * 1_000_000_000.0) as i64;
        }
    } else {
        let parts: Vec<&str> = rest_for_parse.split(':').collect();
        if parts.len() >= 3 {
            if let Ok(h) = parts[0].parse::<i32>() {
                hour = h;
            }
            if let Ok(m) = parts[1].parse::<i32>() {
                minute = m;
            }
            if let Ok(s_val) = parts[2].parse::<i32>() {
                second = s_val;
            }
        } else if parts.len() == 2 {
            if let Ok(h) = parts[0].parse::<i32>() {
                hour = h;
            }
            if let Ok(m) = parts[1].parse::<i32>() {
                minute = m;
            }
        }
    }

    let mut buf = Vec::with_capacity(24);
    buf.extend_from_slice(&(day * sign).to_le_bytes());
    buf.extend_from_slice(&(hour * sign).to_le_bytes());
    buf.extend_from_slice(&(minute * sign).to_le_bytes());
    buf.extend_from_slice(&(second * sign).to_le_bytes());
    buf.extend_from_slice(&(nanosecond * sign as i64).to_le_bytes());
    buf
}

/// Parse a raw output parameter value from the EXEC_RESPONSE frame.
///
/// After executing a stored procedure with OUTPUT or INPUT_OUTPUT parameters,
/// this helper decodes the raw bytes returned by the server into a `DmValue`
/// based on the parameter's type code.
///
/// # Arguments
/// * `bytes` - The raw bytes of the parameter value.
/// * `type_code` - The DM type code (e.g., 4 for INT, 3 for VARCHAR).
///
/// # Returns
/// * `Some(DmValue)` if the value could be decoded.
/// * `None` if the type is unknown or the data is empty/invalid.
pub fn parse_output_param_value(bytes: &[u8], type_code: i32) -> Option<DmValue> {
    if bytes.is_empty() {
        return Some(DmValue::Null);
    }
    let ty = DmValueType::from_type_code(type_code)?;
    decode_value(ty, bytes, None)
}

/// Decode DM binary DECIMAL format (matches Go driver dm_go/o.go decodeDecimal).
fn decode_dm_binary_decimal(data: &[u8]) -> Option<rust_decimal::Decimal> {
    const FLAG_ZERO: u8 = 0x80;
    const FLAG_POSITIVE: i32 = 0xC1;
    const FLAG_NEGTIVE: i32 = 0x3E;
    const NUM_POSITIVE: i32 = 1;
    const NUM_NEGTIVE: i32 = 101;

    if data.is_empty() || data.len() > 21 {
        return None;
    }
    if data[0] == FLAG_ZERO || data.len() == 1 {
        return Some(rust_decimal::Decimal::ZERO);
    }
    let sign: i32 = if data[0] & FLAG_ZERO != 0 { 1 } else { -1 };
    let flag = data[0] as i32;
    let _exp = if sign > 0 {
        flag - FLAG_POSITIVE
    } else {
        FLAG_NEGTIVE - flag
    };
    let mut sf = String::new();
    for &b in &data[1..] {
        let digit = if sign > 0 {
            b as i32 - NUM_POSITIVE
        } else {
            NUM_NEGTIVE - b as i32
        };
        if digit < 0 || digit > 99 {
            break;
        }
        sf.push_str(&format!("{:02}", digit));
    }
    if sf.is_empty() {
        return None;
    }
    let int_val: i64 = sf.parse().ok()?;
    Some(rust_decimal::Decimal::from_i128_with_scale(
        int_val as i128,
        0,
    ))
}

fn is_decimal_text(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.is_empty() {
        return false;
    }

    let mut index = usize::from(matches!(bytes[0], b'+' | b'-'));
    let mut integer_digits = 0;
    while index < bytes.len() && bytes[index].is_ascii_digit() {
        integer_digits += 1;
        index += 1;
    }

    let mut fractional_digits = 0;
    if index < bytes.len() && bytes[index] == b'.' {
        index += 1;
        while index < bytes.len() && bytes[index].is_ascii_digit() {
            fractional_digits += 1;
            index += 1;
        }
    }
    if integer_digits + fractional_digits == 0 {
        return false;
    }

    if index < bytes.len() && matches!(bytes[index], b'e' | b'E') {
        index += 1;
        if index < bytes.len() && matches!(bytes[index], b'+' | b'-') {
            index += 1;
        }
        let exponent_start = index;
        while index < bytes.len() && bytes[index].is_ascii_digit() {
            index += 1;
        }
        if exponent_start == index {
            return false;
        }
    }

    index == bytes.len()
}

/// Decode DM protocol bytes to a Rust value.
///
/// # Arguments
/// * `ty` - The DM value type
/// * `data` - The raw bytes to decode
/// * `lob_meta` - Optional LOB column metadata (tab_id, col_id). Used to populate
///   the LobLocator when decoding out-of-row BLOB/CLOB values.
pub fn decode_value(ty: DmValueType, data: &[u8], lob_meta: Option<(i32, i16)>) -> Option<DmValue> {
    if data.is_empty() {
        return Some(DmValue::Null);
    }

    match ty {
        DmValueType::INT => {
            if data.len() >= 4 {
                let v = i32::from_le_bytes([data[0], data[1], data[2], data[3]]);
                Some(DmValue::Int(v))
            } else {
                None
            }
        }
        DmValueType::BIGINT => {
            if data.len() >= 8 {
                let v = i64::from_le_bytes([
                    data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
                ]);
                Some(DmValue::BigInt(v))
            } else {
                None
            }
        }
        DmValueType::SMALLINT => {
            if data.len() >= 2 {
                let v = i16::from_le_bytes([data[0], data[1]]);
                Some(DmValue::SmallInt(v))
            } else {
                None
            }
        }
        DmValueType::DOUBLE => {
            if data.len() >= 8 {
                let bytes: [u8; 8] = data[..8].try_into().ok()?;
                let v = f64::from_le_bytes(bytes);
                Some(DmValue::Double(v))
            } else {
                None
            }
        }
        DmValueType::FLOAT | DmValueType::REAL => {
            if data.len() >= 4 {
                let v = f32::from_le_bytes([data[0], data[1], data[2], data[3]]);
                Some(DmValue::Float(v))
            } else {
                None
            }
        }
        DmValueType::BIT | DmValueType::BOOLEAN => Some(DmValue::Boolean(data[0] != 0)),
        DmValueType::VARCHAR | DmValueType::CHAR | DmValueType::VARCHAR2 => {
            String::from_utf8(data.to_vec()).ok().map(DmValue::Text)
        }
        DmValueType::CLOB => {
            // DM returns NBLOB_HEAD format for CLOB values:
            // - in_row=0x01: inline data follows (13-byte header: flag(1) + blob_id(8) + blob_len(4) + data)
            // - in_row=0x02: out-of-row LOB locator (needs LOBREAD protocol)
            // - legacy: exactly 16 bytes (old LOB_LOCATOR format)
            if data.len() >= 13 && data[0] == 0x01 {
                // Inline LOB data - extract actual content
                let blob_len = if data.len() >= 13 {
                    u32::from_le_bytes([data[9], data[10], data[11], data[12]]) as usize
                } else {
                    0
                };
                if 13 + blob_len <= data.len() {
                    let inline_data = &data[13..13 + blob_len];
                    String::from_utf8(inline_data.to_vec())
                        .ok()
                        .map(DmValue::Text)
                } else {
                    None
                }
            } else if data.len() >= 13 && data[0] == 0x02 {
                // Out-of-row CLOB locator
                let mut loc = LobLocator::from_nblob_head(data.to_vec(), true);
                if let Some((tab_id, col_id)) = lob_meta {
                    loc = loc.with_tab_col_id(tab_id, col_id);
                }
                Some(DmValue::LobLocator(loc))
            } else if data.len() == 16 {
                // Legacy 16-byte LOB_LOCATOR format
                let mut loc = LobLocator::from_nblob_head(data.to_vec(), true);
                if let Some((tab_id, col_id)) = lob_meta {
                    loc = loc.with_tab_col_id(tab_id, col_id);
                }
                Some(DmValue::LobLocator(loc))
            } else {
                String::from_utf8(data.to_vec()).ok().map(DmValue::Text)
            }
        }
        DmValueType::BINARY | DmValueType::VARBINARY | DmValueType::RAW => {
            Some(DmValue::Bytea(data.to_vec()))
        }
        DmValueType::BLOB => {
            // DM returns NBLOB_HEAD format for BLOB values (same as CLOB):
            // - in_row=0x01: inline data follows
            // - in_row=0x02: out-of-row LOB locator
            if data.len() >= 13 && data[0] == 0x01 {
                // Inline BLOB data
                let blob_len = if data.len() >= 13 {
                    u32::from_le_bytes([data[9], data[10], data[11], data[12]]) as usize
                } else {
                    0
                };
                if 13 + blob_len <= data.len() {
                    Some(DmValue::Bytea(data[13..13 + blob_len].to_vec()))
                } else {
                    None
                }
            } else if data.len() >= 13 && data[0] == 0x02 {
                // Out-of-row BLOB locator
                let mut loc = LobLocator::from_nblob_head(data.to_vec(), false);
                if let Some((tab_id, col_id)) = lob_meta {
                    loc = loc.with_tab_col_id(tab_id, col_id);
                }
                Some(DmValue::LobLocator(loc))
            } else if data.len() == 16 {
                // Legacy 16-byte LOB_LOCATOR format
                let mut loc = LobLocator::from_nblob_head(data.to_vec(), false);
                if let Some((tab_id, col_id)) = lob_meta {
                    loc = loc.with_tab_col_id(tab_id, col_id);
                }
                Some(DmValue::LobLocator(loc))
            } else {
                Some(DmValue::Bytea(data.to_vec()))
            }
        }
        DmValueType::DECIMAL | DmValueType::NUMERIC => {
            // DM commonly returns decimal text. Keep values that exceed rust_decimal's
            // 96-bit representation as text so callers do not mistake them for SQL NULL.
            if let Ok(s) = std::str::from_utf8(data) {
                let trimmed = s.trim();
                if let Ok(d) = rust_decimal::Decimal::from_str_exact(trimmed) {
                    return Some(DmValue::Decimal(d));
                }
                if is_decimal_text(trimmed) {
                    return Some(DmValue::Text(trimmed.to_string()));
                }
                if s.is_ascii() {
                    return None;
                }
            }
            // Try DM binary DECIMAL format (matches Go driver o.go)
            decode_dm_binary_decimal(data).map(DmValue::Decimal)
        }
        DmValueType::TINYINT => Some(DmValue::TinyInt(data[0] as i8)),
        DmValueType::DATE
        | DmValueType::TIME
        | DmValueType::TIMESTAMP
        | DmValueType::INTERVAL
        | DmValueType::DATETIME
        | DmValueType::DATETIME2
        | DmValueType::TIME_TZ
        | DmValueType::DATETIME_TZ
        | DmValueType::DATETIME2_TZ
        | DmValueType::INTERVAL_YM
        | DmValueType::INTERVAL_DT => {
            // DM stores DATE/TIME/TIMESTAMP/INTERVAL as binary:
            // DATE: 7 bytes (year:2BE, month:1, day:1, hour:1, min:1, sec:1)
            // TIME: 6+ bytes (hour:1, min:1, sec:1, nanosec:4BE)
            // TIMESTAMP: 11 bytes (year:2BE, month:1, day:1, hour:1, min:1, sec:1, nanosec:4BE)
            // If data is valid UTF-8 text, pass through as Text.
            // Otherwise decode binary to typed chrono variants.
            if let Ok(s) = String::from_utf8(data.to_vec()) {
                return Some(DmValue::Text(s));
            }
            // Binary decode for TIMESTAMP / DATETIME
            if ty == DmValueType::TIMESTAMP
                || ty == DmValueType::DATETIME
                || ty == DmValueType::DATETIME2
            {
                // Try 11-byte OPE format
                if data.len() >= 11 {
                    let year = u16::from_be_bytes([data[0], data[1]]) as i32;
                    let month = data[2] as u32;
                    let day = data[3] as u32;
                    let hour = data[4] as u32;
                    let min = data[5] as u32;
                    let sec = data[6] as u32;
                    let nano = u32::from_be_bytes([data[7], data[8], data[9], data[10]]);
                    if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day)
                        .and_then(|d| d.and_hms_nano_opt(hour, min, sec, nano))
                    {
                        return Some(DmValue::Timestamp(d));
                    }
                }
                // Try 8-byte DM row format
                if data.len() >= 8 {
                    let year = i32::from(i16::from_le_bytes([data[0], data[1]])) & 0x7FFF;
                    let month = ((data[1] as u32 >> 7) & 0x1) + ((data[2] as u32 & 0x07) << 1);
                    let day = ((data[2] as u32 & 0xF8) >> 3) & 0x1F;
                    let hour = data[3] as u32 & 0x1F;
                    let min = ((data[3] as u32 >> 5) & 0x07) + ((data[4] as u32 & 0x07) << 3);
                    let sec = ((data[4] as u32 >> 3) & 0x1F) + ((data[5] as u32 & 0x01) << 5);
                    let nano = (((data[5] as u32 >> 1) & 0x7F)
                        + ((data[6] as u32 & 0xFF) << 7)
                        + ((data[7] as u32 & 0x1F) << 15))
                        * 1000;
                    if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day)
                        .and_then(|d| d.and_hms_nano_opt(hour, min, sec, nano))
                    {
                        return Some(DmValue::Timestamp(d));
                    }
                }
                None
            } else if ty == DmValueType::DATE {
                // Try 3-byte DM row format first (DATE_PREC = 3)
                if data.len() >= 3 && data.len() < 7 {
                    let year = i32::from(i16::from_le_bytes([data[0], data[1]])) & 0x7FFF;
                    let month = ((data[1] as u32 >> 7) & 0x1) + ((data[2] as u32 & 0x07) << 1);
                    let day = ((data[2] as u32 & 0xF8) >> 3) & 0x1F;
                    if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day) {
                        return Some(DmValue::Date(d));
                    }
                }
                if data.len() >= 7 {
                    let year = u16::from_be_bytes([data[0], data[1]]) as i32;
                    let month = data[2] as u32;
                    let day = data[3] as u32;
                    if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day) {
                        return Some(DmValue::Date(d));
                    }
                }
                if data.len() >= 8 {
                    let year = i32::from(i16::from_le_bytes([data[0], data[1]])) & 0x7FFF;
                    let month = ((data[1] as u32 >> 7) & 0x1) + ((data[2] as u32 & 0x07) << 1);
                    let day = ((data[2] as u32 & 0xF8) >> 3) & 0x1F;
                    if let Some(d) = chrono::NaiveDate::from_ymd_opt(year, month, day) {
                        return Some(DmValue::Date(d));
                    }
                }
                None.map(DmValue::Date)
            } else if ty == DmValueType::TIME && data.len() >= 6 {
                let hour = data[0] as u32;
                let minute = data[1] as u32;
                let second = data[2] as u32;
                let nano = if data.len() >= 10 {
                    u32::from_be_bytes([data[3], data[4], data[5], data[6]])
                } else {
                    0
                };
                chrono::NaiveTime::from_hms_nano_opt(hour, minute, second, nano).map(DmValue::Time)
            } else if ty == DmValueType::INTERVAL
                || ty == DmValueType::INTERVAL_YM
                || ty == DmValueType::INTERVAL_DT
            {
                Some(DmValue::Text(String::from_utf8_lossy(data).to_string()))
            } else {
                // Fallback for TIME_TZ, DATETIME_TZ, DATETIME2_TZ: text
                Some(DmValue::Text(String::from_utf8_lossy(data).to_string()))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dmvtype_from_type_code() {
        assert_eq!(DmValueType::from_type_code(4), Some(DmValueType::INT));
        assert_eq!(DmValueType::from_type_code(3), Some(DmValueType::VARCHAR));
        assert_eq!(DmValueType::from_type_code(99), None);
    }

    #[test]
    fn test_dmvtype_type_code() {
        assert_eq!(DmValueType::INT.type_code(), 4);
        assert_eq!(DmValueType::BIGINT.type_code(), 5);
        assert_eq!(DmValueType::BIT.type_code(), 1);
    }

    #[test]
    fn test_dmvtype_type_name() {
        assert_eq!(DmValueType::INT.type_name(), "INT");
        assert_eq!(DmValueType::VARCHAR.type_name(), "VARCHAR");
        assert_eq!(DmValueType::TIMESTAMP.type_name(), "TIMESTAMP");
    }

    #[test]
    fn test_encode_decode_int() {
        let val = DmValue::Int(42);
        let encoded = encode_value(DmValueType::INT, &val);
        assert_eq!(encoded, vec![42, 0, 0, 0]);
        let decoded = decode_value(DmValueType::INT, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }

    #[test]
    fn test_encode_decode_bigint() {
        let val = DmValue::BigInt(1000);
        let encoded = encode_value(DmValueType::BIGINT, &val);
        assert_eq!(encoded, vec![0xE8, 0x03, 0, 0, 0, 0, 0, 0]);
        let decoded = decode_value(DmValueType::BIGINT, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }

    #[test]
    fn test_encode_decode_text() {
        let val = DmValue::Text("hello".to_string());
        let encoded = encode_value(DmValueType::VARCHAR, &val);
        assert_eq!(encoded, b"hello");
        let decoded = decode_value(DmValueType::VARCHAR, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }

    #[test]
    fn test_encode_decode_bool() {
        let val = DmValue::Boolean(true);
        let encoded = encode_value(DmValueType::BIT, &val);
        assert_eq!(encoded, vec![1]);
        let decoded = decode_value(DmValueType::BIT, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }

    #[test]
    fn test_decode_empty() {
        let result = decode_value(DmValueType::INT, &[], None);
        assert_eq!(result, Some(DmValue::Null));
    }

    #[test]
    fn test_encode_decode_bytea() {
        let val = DmValue::Bytea(vec![0xDE, 0xAD, 0xBE, 0xEF]);
        let encoded = encode_value(DmValueType::BLOB, &val);
        assert_eq!(encoded, vec![0xDE, 0xAD, 0xBE, 0xEF]);
        let decoded = decode_value(DmValueType::BLOB, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }

    #[test]
    fn test_new_type_codes() {
        assert_eq!(DmValueType::NUMERIC.type_code(), 20);
        assert_eq!(DmValueType::BOOLEAN.type_code(), 21);
        assert_eq!(DmValueType::DATETIME.type_code(), 22);
        assert_eq!(DmValueType::VARCHAR2.type_code(), 23);
        assert_eq!(DmValueType::DATETIME2.type_code(), 24);
        assert_eq!(DmValueType::TIME_TZ.type_code(), 25);
        assert_eq!(DmValueType::DATETIME_TZ.type_code(), 26);
        assert_eq!(DmValueType::INTERVAL_YM.type_code(), 27);
        assert_eq!(DmValueType::INTERVAL_DT.type_code(), 28);
        assert_eq!(DmValueType::RAW.type_code(), 29);
        assert_eq!(DmValueType::DATETIME2_TZ.type_code(), 30);
        assert_eq!(DmValueType::REAL.type_code(), 31);
    }

    #[test]
    fn test_new_from_type_code() {
        assert_eq!(DmValueType::from_type_code(20), Some(DmValueType::NUMERIC));
        assert_eq!(DmValueType::from_type_code(21), Some(DmValueType::BOOLEAN));
        assert_eq!(DmValueType::from_type_code(22), Some(DmValueType::DATETIME));
        assert_eq!(DmValueType::from_type_code(23), Some(DmValueType::VARCHAR2));
        assert_eq!(
            DmValueType::from_type_code(24),
            Some(DmValueType::DATETIME2)
        );
        assert_eq!(DmValueType::from_type_code(25), Some(DmValueType::TIME_TZ));
        assert_eq!(
            DmValueType::from_type_code(26),
            Some(DmValueType::DATETIME_TZ)
        );
        assert_eq!(
            DmValueType::from_type_code(27),
            Some(DmValueType::INTERVAL_YM)
        );
        assert_eq!(
            DmValueType::from_type_code(28),
            Some(DmValueType::INTERVAL_DT)
        );
        assert_eq!(DmValueType::from_type_code(29), Some(DmValueType::RAW));
        assert_eq!(
            DmValueType::from_type_code(30),
            Some(DmValueType::DATETIME2_TZ)
        );
        assert_eq!(DmValueType::from_type_code(31), Some(DmValueType::REAL));
    }

    #[test]
    fn test_new_type_names() {
        assert_eq!(DmValueType::NUMERIC.type_name(), "NUMERIC");
        assert_eq!(DmValueType::BOOLEAN.type_name(), "BOOLEAN");
        assert_eq!(DmValueType::DATETIME.type_name(), "DATETIME");
        assert_eq!(DmValueType::VARCHAR2.type_name(), "VARCHAR2");
        assert_eq!(DmValueType::DATETIME2.type_name(), "DATETIME2");
        assert_eq!(DmValueType::TIME_TZ.type_name(), "TIME_TZ");
        assert_eq!(DmValueType::DATETIME_TZ.type_name(), "DATETIME_TZ");
        assert_eq!(DmValueType::INTERVAL_YM.type_name(), "INTERVAL_YM");
        assert_eq!(DmValueType::INTERVAL_DT.type_name(), "INTERVAL_DT");
        assert_eq!(DmValueType::RAW.type_name(), "RAW");
        assert_eq!(DmValueType::DATETIME2_TZ.type_name(), "DATETIME2_TZ");
        assert_eq!(DmValueType::REAL.type_name(), "REAL");
    }

    #[test]
    fn test_encode_decode_boolean() {
        let val = DmValue::Boolean(false);
        let encoded = encode_value(DmValueType::BOOLEAN, &val);
        assert_eq!(encoded, vec![0]);
        let decoded = decode_value(DmValueType::BOOLEAN, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }

    #[test]
    fn test_encode_decode_raw() {
        let val = DmValue::Bytea(vec![0xAA, 0xBB]);
        let encoded = encode_value(DmValueType::RAW, &val);
        assert_eq!(encoded, vec![0xAA, 0xBB]);
        let decoded = decode_value(DmValueType::RAW, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }

    #[test]
    fn test_encode_decode_real() {
        let val = DmValue::Float(3.14f32);
        let encoded = encode_value(DmValueType::REAL, &val);
        assert_eq!(encoded, 3.14f32.to_le_bytes().to_vec());
        let decoded = decode_value(DmValueType::REAL, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }

    #[test]
    fn test_encode_decode_numeric() {
        use rust_decimal::Decimal;
        let val = DmValue::Decimal(Decimal::from(42));
        let encoded = encode_value(DmValueType::NUMERIC, &val);
        assert_eq!(encoded, b"42");
        let decoded = decode_value(DmValueType::NUMERIC, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }

    #[test]
    fn test_decode_high_precision_numeric_as_text() {
        let value = "1234567890123456789012345678.1234567890";
        let decoded = decode_value(DmValueType::NUMERIC, value.as_bytes(), None).unwrap();
        assert_eq!(decoded, DmValue::Text(value.to_string()));
    }

    #[test]
    fn test_reject_invalid_numeric_text() {
        assert_eq!(decode_value(DmValueType::NUMERIC, b"12.3.4", None), None);
        assert_eq!(decode_value(DmValueType::NUMERIC, b"1e+", None), None);
    }

    #[test]
    fn test_encode_decode_varchar2() {
        let val = DmValue::Text("test".to_string());
        let encoded = encode_value(DmValueType::VARCHAR2, &val);
        assert_eq!(encoded, b"test");
        let decoded = decode_value(DmValueType::VARCHAR2, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }

    #[test]
    fn test_encode_decode_datetime() {
        let val = DmValue::Text("2024-01-01 12:00:00".to_string());
        let encoded = encode_value(DmValueType::DATETIME, &val);
        assert_eq!(encoded, b"2024-01-01 12:00:00");
        let decoded = decode_value(DmValueType::DATETIME, &encoded, None).unwrap();
        assert_eq!(decoded, val);
    }
}
