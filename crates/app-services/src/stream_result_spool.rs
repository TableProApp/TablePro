use std::fmt;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use aes_gcm::aead::{Aead, KeyInit, Payload, consts::U12};
use aes_gcm::{Aes256Gcm, Nonce};
use secrecy::{ExposeSecret, SecretBox};
use serde::ser::{SerializeSeq, SerializeStruct, Serializer};
use serde::{Deserialize, Serialize};
use tablepro_core::{ColumnInfo, QueryResult, Value};
use thiserror::Error;

const FRAME_VERSION: u8 = 1;
const FRAME_HEADER_BYTES: u64 = 25;
const AUTH_TAG_BYTES: u64 = 16;
const ENCRYPTION_CHUNK_BYTES: usize = 64 * 1024;
pub const MAX_STREAM_RESULT_SPOOL_PAGES: usize = 4096;
pub const MAX_STREAM_RESULT_SPOOL_BYTES: u64 = 1024 * 1024 * 1024;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum StreamResultSpoolError {
    #[error("result page arrived out of order")]
    OutOfOrder,
    #[error("result spool page limit reached")]
    PageLimit,
    #[error("result spool quota reached")]
    QuotaExceeded,
    #[error("result page is not available in the spool")]
    MissingPage,
    #[error("result spool could not create temporary storage")]
    Create,
    #[error("result spool could not read or write temporary storage")]
    Io,
    #[error("result spool encryption failed")]
    Encryption,
    #[error("result spool data failed typed decoding")]
    Decode,
    #[error("result spool data has an invalid frame")]
    InvalidFrame,
    #[error("result spool random key generation failed")]
    Randomness,
    #[error("result spool worker did not complete")]
    Worker,
}

#[derive(Clone)]
pub struct StreamResultSpoolManager {
    budget: Arc<SpoolBudget>,
}

struct SpoolBudget {
    limit: u64,
    reserved: AtomicU64,
}

#[derive(Clone)]
pub struct StreamResultSpool {
    inner: Arc<SpoolInner>,
}

impl fmt::Debug for StreamResultSpool {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("StreamResultSpool")
    }
}

struct SpoolInner {
    file: Mutex<SpoolFile>,
    key: SecretBox<[u8; 32]>,
    budget: Arc<SpoolBudget>,
    reserved: AtomicU64,
}

struct SpoolFile {
    file: File,
    pages: Vec<PageLocation>,
    next_nonce: u64,
}

#[derive(Clone, Copy)]
struct PageLocation {
    offset: u64,
    chunks: u32,
    first_nonce: u64,
}

struct EncryptedPageWriter<'a> {
    inner: &'a SpoolInner,
    spool: &'a mut SpoolFile,
    page_index: u64,
    buffer: Vec<u8>,
    chunks: u32,
    reserved: u64,
    failure: Option<StreamResultSpoolError>,
}

struct StoredPageRef<'a> {
    rows: &'a [Vec<Value>],
    truncated: bool,
}

#[derive(Deserialize)]
struct StoredPage {
    rows: Vec<Vec<StoredValue>>,
    truncated: bool,
}

#[derive(Deserialize)]
enum StoredValue {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Text(String),
    Bytes(Vec<u8>),
    Date(chrono::NaiveDate),
    Time(chrono::NaiveTime),
    DateTime(chrono::NaiveDateTime),
    TimestampTz(chrono::DateTime<chrono::Utc>),
    Decimal(rust_decimal::Decimal),
    Uuid(uuid::Uuid),
    Json(String),
    JsonText(String),
    Undecodable(String),
}

struct StoredRowsRef<'a>(&'a [Vec<Value>]);

struct StoredRowRef<'a>(&'a [Value]);

struct StoredValueRef<'a>(&'a Value);

impl Serialize for StoredPageRef<'_> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut page = serializer.serialize_struct("StoredPage", 2)?;
        page.serialize_field("rows", &StoredRowsRef(self.rows))?;
        page.serialize_field("truncated", &self.truncated)?;
        page.end()
    }
}

impl Serialize for StoredRowsRef<'_> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut rows = serializer.serialize_seq(Some(self.0.len()))?;
        for row in self.0 {
            rows.serialize_element(&StoredRowRef(row))?;
        }
        rows.end()
    }
}

impl Serialize for StoredRowRef<'_> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut row = serializer.serialize_seq(Some(self.0.len()))?;
        for value in self.0 {
            row.serialize_element(&StoredValueRef(value))?;
        }
        row.end()
    }
}

impl Serialize for StoredValueRef<'_> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self.0 {
            Value::Null => serializer.serialize_unit_variant("StoredValue", 0, "Null"),
            Value::Bool(value) => serializer.serialize_newtype_variant("StoredValue", 1, "Bool", value),
            Value::Int(value) => serializer.serialize_newtype_variant("StoredValue", 2, "Int", value),
            Value::Float(value) => serializer.serialize_newtype_variant("StoredValue", 3, "Float", value),
            Value::Text(value) => serializer.serialize_newtype_variant("StoredValue", 4, "Text", value),
            Value::Bytes(value) => serializer.serialize_newtype_variant("StoredValue", 5, "Bytes", value),
            Value::Date(value) => serializer.serialize_newtype_variant("StoredValue", 6, "Date", value),
            Value::Time(value) => serializer.serialize_newtype_variant("StoredValue", 7, "Time", value),
            Value::DateTime(value) => serializer.serialize_newtype_variant("StoredValue", 8, "DateTime", value),
            Value::TimestampTz(value) => serializer.serialize_newtype_variant("StoredValue", 9, "TimestampTz", value),
            Value::Decimal(value) => serializer.serialize_newtype_variant("StoredValue", 10, "Decimal", value),
            Value::Uuid(value) => serializer.serialize_newtype_variant("StoredValue", 11, "Uuid", value),
            Value::Json(value) => {
                let json = serde_json::to_string(value).map_err(serde::ser::Error::custom)?;
                serializer.serialize_newtype_variant("StoredValue", 12, "Json", &json)
            }
            Value::JsonText(value) => serializer.serialize_newtype_variant("StoredValue", 13, "JsonText", value),
            Value::Undecodable(value) => serializer.serialize_newtype_variant("StoredValue", 14, "Undecodable", value),
        }
    }
}

impl StoredPage {
    fn into_query_result(self, columns: Vec<ColumnInfo>) -> Result<QueryResult, StreamResultSpoolError> {
        let rows = self
            .rows
            .into_iter()
            .map(|row| row.into_iter().map(StoredValue::into_value).collect())
            .collect::<Result<Vec<Vec<Value>>, _>>()?;
        Ok(QueryResult {
            columns,
            rows,
            truncated: self.truncated,
        })
    }
}

impl StoredValue {
    fn into_value(self) -> Result<Value, StreamResultSpoolError> {
        match self {
            Self::Null => Ok(Value::Null),
            Self::Bool(value) => Ok(Value::Bool(value)),
            Self::Int(value) => Ok(Value::Int(value)),
            Self::Float(value) => Ok(Value::Float(value)),
            Self::Text(value) => Ok(Value::Text(value)),
            Self::Bytes(value) => Ok(Value::Bytes(value)),
            Self::Date(value) => Ok(Value::Date(value)),
            Self::Time(value) => Ok(Value::Time(value)),
            Self::DateTime(value) => Ok(Value::DateTime(value)),
            Self::TimestampTz(value) => Ok(Value::TimestampTz(value)),
            Self::Decimal(value) => Ok(Value::Decimal(value)),
            Self::Uuid(value) => Ok(Value::Uuid(value)),
            Self::Json(value) => serde_json::from_str(&value)
                .map(|value| Value::Json(Box::new(value)))
                .map_err(|_| StreamResultSpoolError::Decode),
            Self::JsonText(value) => Ok(Value::JsonText(value)),
            Self::Undecodable(value) => Ok(Value::Undecodable(value)),
        }
    }
}

impl Default for StreamResultSpoolManager {
    fn default() -> Self {
        Self::with_limit(MAX_STREAM_RESULT_SPOOL_BYTES)
    }
}

impl StreamResultSpoolManager {
    pub fn with_limit(limit: u64) -> Self {
        Self {
            budget: Arc::new(SpoolBudget {
                limit,
                reserved: AtomicU64::new(0),
            }),
        }
    }

    pub fn create(&self) -> Result<StreamResultSpool, StreamResultSpoolError> {
        let file = tempfile::tempfile().map_err(|_| StreamResultSpoolError::Create)?;
        let mut key = [0_u8; 32];
        getrandom::fill(&mut key).map_err(|_| StreamResultSpoolError::Randomness)?;
        Ok(StreamResultSpool {
            inner: Arc::new(SpoolInner {
                file: Mutex::new(SpoolFile {
                    file,
                    pages: Vec::new(),
                    next_nonce: 0,
                }),
                key: SecretBox::new(Box::new(key)),
                budget: self.budget.clone(),
                reserved: AtomicU64::new(0),
            }),
        })
    }

    pub fn reserved_bytes(&self) -> u64 {
        self.budget.reserved.load(Ordering::Acquire)
    }
}

impl StreamResultSpool {
    pub async fn append_page(&self, index: u64, page: Arc<QueryResult>) -> Result<(), StreamResultSpoolError> {
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || append_page_blocking(&inner, index, &page))
            .await
            .map_err(|_| StreamResultSpoolError::Worker)?
    }

    pub async fn load_page(
        &self,
        index: u64,
        columns: Vec<ColumnInfo>,
    ) -> Result<Arc<QueryResult>, StreamResultSpoolError> {
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || load_page_blocking(&inner, index, columns))
            .await
            .map_err(|_| StreamResultSpoolError::Worker)?
    }

    pub fn page_count(&self) -> usize {
        self.inner.file.lock().map(|file| file.pages.len()).unwrap_or_default()
    }
}

impl Drop for SpoolInner {
    fn drop(&mut self) {
        let reserved = self.reserved.load(Ordering::Acquire);
        self.budget.reserved.fetch_sub(reserved, Ordering::AcqRel);
    }
}

fn append_page_blocking(inner: &Arc<SpoolInner>, index: u64, page: &QueryResult) -> Result<(), StreamResultSpoolError> {
    let mut spool = inner.file.lock().map_err(|_| StreamResultSpoolError::Io)?;
    let page_index = usize::try_from(index).map_err(|_| StreamResultSpoolError::PageLimit)?;
    if page_index >= MAX_STREAM_RESULT_SPOOL_PAGES {
        return Err(StreamResultSpoolError::PageLimit);
    }
    if index != spool.pages.len() as u64 {
        return Err(StreamResultSpoolError::OutOfOrder);
    }
    append_serialized_page(
        inner,
        &mut spool,
        index,
        &StoredPageRef {
            rows: &page.rows,
            truncated: page.truncated,
        },
    )
}

fn append_serialized_page<T: Serialize>(
    inner: &SpoolInner,
    spool: &mut SpoolFile,
    page_index: u64,
    page: &T,
) -> Result<(), StreamResultSpoolError> {
    let offset = spool
        .file
        .seek(SeekFrom::End(0))
        .map_err(|_| StreamResultSpoolError::Io)?;
    let (error, reserved, chunks) = {
        let mut writer = EncryptedPageWriter::new(inner, spool, page_index);
        let serialized = rmp_serde::encode::write(&mut writer, page);
        if serialized.is_ok() {
            writer.finish();
        }
        let error = writer
            .failure
            .take()
            .or_else(|| serialized.err().map(|_| StreamResultSpoolError::Decode));
        (error, writer.reserved, writer.chunks)
    };
    if let Some(error) = error {
        rollback_page(inner, spool, offset, reserved)?;
        return Err(error);
    }
    if chunks == 0 {
        rollback_page(inner, spool, offset, reserved)?;
        return Err(StreamResultSpoolError::InvalidFrame);
    }
    inner.reserved.fetch_add(reserved, Ordering::AcqRel);
    spool.pages.push(PageLocation {
        offset,
        chunks,
        first_nonce: spool.next_nonce - u64::from(chunks),
    });
    Ok(())
}

impl<'a> EncryptedPageWriter<'a> {
    fn new(inner: &'a SpoolInner, spool: &'a mut SpoolFile, page_index: u64) -> Self {
        Self {
            inner,
            spool,
            page_index,
            buffer: Vec::with_capacity(ENCRYPTION_CHUNK_BYTES),
            chunks: 0,
            reserved: 0,
            failure: None,
        }
    }

    fn finish(&mut self) {
        if self.failure.is_some() {
            return;
        }
        if let Err(error) = self.write_buffer() {
            self.failure = Some(error);
            return;
        }
        if self.spool.file.flush().is_err() {
            self.failure = Some(StreamResultSpoolError::Io);
        }
    }

    fn write_buffer(&mut self) -> Result<(), StreamResultSpoolError> {
        if self.buffer.is_empty() {
            return Ok(());
        }
        write_payload_chunk(
            self.inner,
            self.spool,
            self.page_index,
            &self.buffer,
            &mut self.reserved,
        )?;
        self.buffer.clear();
        self.chunks = self.chunks.checked_add(1).ok_or(StreamResultSpoolError::InvalidFrame)?;
        Ok(())
    }

    fn io_error(&mut self, error: StreamResultSpoolError) -> io::Error {
        self.failure = Some(error);
        io::Error::other("encrypted result spool write failed")
    }
}

impl io::Write for EncryptedPageWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.failure.is_some() {
            return Err(io::Error::other("encrypted result spool write failed"));
        }
        let mut accepted = 0;
        while accepted < bytes.len() {
            let capacity = ENCRYPTION_CHUNK_BYTES - self.buffer.len();
            let length = capacity.min(bytes.len() - accepted);
            self.buffer.extend_from_slice(&bytes[accepted..accepted + length]);
            accepted += length;
            if self.buffer.len() == ENCRYPTION_CHUNK_BYTES
                && let Err(error) = self.write_buffer()
            {
                let error = self.io_error(error);
                return if accepted == 0 { Err(error) } else { Ok(accepted) };
            }
        }
        Ok(accepted)
    }

    fn flush(&mut self) -> io::Result<()> {
        if let Some(error) = self.failure.take() {
            return Err(self.io_error(error));
        }
        if let Err(error) = self.write_buffer() {
            return Err(self.io_error(error));
        }
        if self.spool.file.flush().is_err() {
            return Err(self.io_error(StreamResultSpoolError::Io));
        }
        Ok(())
    }
}

fn write_payload_chunk(
    inner: &SpoolInner,
    spool: &mut SpoolFile,
    page_index: u64,
    plaintext: &[u8],
    reserved: &mut u64,
) -> Result<(), StreamResultSpoolError> {
    let sequence = spool.next_nonce;
    spool.next_nonce = spool
        .next_nonce
        .checked_add(1)
        .ok_or(StreamResultSpoolError::InvalidFrame)?;
    let nonce = nonce_for(sequence);
    let aad = frame_aad(page_index, sequence, plaintext.len());
    let cipher = cipher(inner)?;
    let ciphertext = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| StreamResultSpoolError::Encryption)?;
    let frame_size = FRAME_HEADER_BYTES.saturating_add(ciphertext.len() as u64);
    reserve(&inner.budget, frame_size)?;
    *reserved = reserved.saturating_add(frame_size);
    write_frame(&mut spool.file, page_index, sequence, plaintext.len(), &ciphertext)
}

fn write_frame(
    file: &mut File,
    page_index: u64,
    sequence: u64,
    plaintext_len: usize,
    ciphertext: &[u8],
) -> Result<(), StreamResultSpoolError> {
    let plaintext_len = u32::try_from(plaintext_len).map_err(|_| StreamResultSpoolError::InvalidFrame)?;
    let ciphertext_len = u32::try_from(ciphertext.len()).map_err(|_| StreamResultSpoolError::InvalidFrame)?;
    file.write_all(&[FRAME_VERSION])
        .map_err(|_| StreamResultSpoolError::Io)?;
    file.write_all(&page_index.to_be_bytes())
        .map_err(|_| StreamResultSpoolError::Io)?;
    file.write_all(&sequence.to_be_bytes())
        .map_err(|_| StreamResultSpoolError::Io)?;
    file.write_all(&plaintext_len.to_be_bytes())
        .map_err(|_| StreamResultSpoolError::Io)?;
    file.write_all(&ciphertext_len.to_be_bytes())
        .map_err(|_| StreamResultSpoolError::Io)?;
    file.write_all(ciphertext).map_err(|_| StreamResultSpoolError::Io)
}

fn rollback_page(
    inner: &SpoolInner,
    spool: &mut SpoolFile,
    offset: u64,
    reserved: u64,
) -> Result<(), StreamResultSpoolError> {
    if spool.file.set_len(offset).is_err() {
        inner.reserved.fetch_add(reserved, Ordering::AcqRel);
        return Err(StreamResultSpoolError::Io);
    }
    inner.budget.reserved.fetch_sub(reserved, Ordering::AcqRel);
    spool
        .file
        .seek(SeekFrom::Start(offset))
        .map_err(|_| StreamResultSpoolError::Io)?;
    Ok(())
}

fn load_page_blocking(
    inner: &Arc<SpoolInner>,
    index: u64,
    columns: Vec<ColumnInfo>,
) -> Result<Arc<QueryResult>, StreamResultSpoolError> {
    let mut spool = inner.file.lock().map_err(|_| StreamResultSpoolError::Io)?;
    let location = *spool
        .pages
        .get(usize::try_from(index).map_err(|_| StreamResultSpoolError::MissingPage)?)
        .ok_or(StreamResultSpoolError::MissingPage)?;
    spool
        .file
        .seek(SeekFrom::Start(location.offset))
        .map_err(|_| StreamResultSpoolError::Io)?;
    let page = read_page_payload(inner, &mut spool.file, index, location)?;
    Ok(Arc::new(page.into_query_result(columns)?))
}

fn read_page_payload(
    inner: &SpoolInner,
    file: &mut File,
    page_index: u64,
    location: PageLocation,
) -> Result<StoredPage, StreamResultSpoolError> {
    let mut payload = Vec::new();
    let mut expected_sequence = location.first_nonce;
    for _ in 0..location.chunks {
        let (sequence, plaintext) = read_frame(inner, file, page_index)?;
        if sequence != expected_sequence {
            return Err(StreamResultSpoolError::InvalidFrame);
        }
        expected_sequence = expected_sequence
            .checked_add(1)
            .ok_or(StreamResultSpoolError::InvalidFrame)?;
        payload.extend_from_slice(&plaintext);
    }
    rmp_serde::from_slice(&payload).map_err(|_| StreamResultSpoolError::Decode)
}

fn read_frame(
    inner: &SpoolInner,
    file: &mut File,
    expected_page: u64,
) -> Result<(u64, Vec<u8>), StreamResultSpoolError> {
    let version = read_byte(file)?;
    let page = read_u64(file)?;
    let sequence = read_u64(file)?;
    let plaintext_len = read_u32(file)? as usize;
    let ciphertext_len = read_u32(file)? as usize;
    if version != FRAME_VERSION
        || page != expected_page
        || plaintext_len > ENCRYPTION_CHUNK_BYTES
        || ciphertext_len != plaintext_len.saturating_add(AUTH_TAG_BYTES as usize)
    {
        return Err(StreamResultSpoolError::InvalidFrame);
    }
    let mut ciphertext = vec![0_u8; ciphertext_len];
    file.read_exact(&mut ciphertext)
        .map_err(|_| StreamResultSpoolError::Io)?;
    let nonce = nonce_for(sequence);
    let aad = frame_aad(page, sequence, plaintext_len);
    let plaintext = cipher(inner)?
        .decrypt(
            &nonce,
            Payload {
                msg: &ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| StreamResultSpoolError::Encryption)?;
    if plaintext.len() != plaintext_len {
        return Err(StreamResultSpoolError::InvalidFrame);
    }
    Ok((sequence, plaintext))
}

fn read_byte(file: &mut File) -> Result<u8, StreamResultSpoolError> {
    let mut bytes = [0_u8; 1];
    file.read_exact(&mut bytes).map_err(|_| StreamResultSpoolError::Io)?;
    Ok(bytes[0])
}

fn read_u32(file: &mut File) -> Result<u32, StreamResultSpoolError> {
    let mut bytes = [0_u8; 4];
    file.read_exact(&mut bytes).map_err(|_| StreamResultSpoolError::Io)?;
    Ok(u32::from_be_bytes(bytes))
}

fn read_u64(file: &mut File) -> Result<u64, StreamResultSpoolError> {
    let mut bytes = [0_u8; 8];
    file.read_exact(&mut bytes).map_err(|_| StreamResultSpoolError::Io)?;
    Ok(u64::from_be_bytes(bytes))
}

fn nonce_for(sequence: u64) -> Nonce<U12> {
    let mut nonce = [0_u8; 12];
    nonce[4..].copy_from_slice(&sequence.to_be_bytes());
    nonce.into()
}

fn frame_aad(page_index: u64, sequence: u64, plaintext_len: usize) -> [u8; 21] {
    let mut aad = [0_u8; 21];
    aad[0] = FRAME_VERSION;
    aad[1..9].copy_from_slice(&page_index.to_be_bytes());
    aad[9..17].copy_from_slice(&sequence.to_be_bytes());
    aad[17..].copy_from_slice(&(plaintext_len as u32).to_be_bytes());
    aad
}

fn cipher(inner: &SpoolInner) -> Result<Aes256Gcm, StreamResultSpoolError> {
    Aes256Gcm::new_from_slice(inner.key.expose_secret()).map_err(|_| StreamResultSpoolError::Encryption)
}

fn reserve(budget: &SpoolBudget, bytes: u64) -> Result<(), StreamResultSpoolError> {
    let mut current = budget.reserved.load(Ordering::Acquire);
    loop {
        let next = current
            .checked_add(bytes)
            .ok_or(StreamResultSpoolError::QuotaExceeded)?;
        if next > budget.limit {
            return Err(StreamResultSpoolError::QuotaExceeded);
        }
        match budget
            .reserved
            .compare_exchange(current, next, Ordering::AcqRel, Ordering::Acquire)
        {
            Ok(_) => return Ok(()),
            Err(observed) => current = observed,
        }
    }
}

#[cfg(test)]
mod tests;
