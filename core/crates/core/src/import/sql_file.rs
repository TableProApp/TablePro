use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use flate2::bufread::MultiGzDecoder;

use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{ScriptReadError, ScriptReader, ScriptUnit};

/// Bytes read from the file at a time.
const READ_BYTES: usize = 256 * 1024;

const GZIP_MAGIC: [u8; 2] = [0x1f, 0x8b];

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SqlFileError {
    #[error("the file could not be read: {0}")]
    Read(String),
    /// Bytes on the line that are not UTF-8, as a dump of binary values
    /// written without hex has.
    #[error("line {line} is not UTF-8 text")]
    NotUtf8 { line: u64 },
    #[error(transparent)]
    Script(#[from] ScriptReadError),
}

impl SqlFileError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Read(_) => "sql_file.read",
            Self::NotUtf8 { .. } => "sql_file.not_utf8",
            Self::Script(ScriptReadError::TooLong { .. }) => "sql_file.statement_too_long",
        }
    }
}

/// A SQL file's units, read as they are needed: gzip when the file starts
/// with gzip's magic bytes, UTF-8 with or without a byte order mark.
pub struct SqlFileReader {
    source: Box<dyn BufRead + Send>,
    reader: Option<ScriptReader>,
    units: VecDeque<ScriptUnit>,
    /// Bytes of the file read so far, before any gunzip, for progress
    /// against its size.
    consumed: Arc<AtomicU64>,
    /// A character cut by the end of a read, finished by the next.
    partial: Vec<u8>,
    line: u64,
    first: bool,
    failed: bool,
}

impl SqlFileReader {
    pub fn new(file: Box<dyn Read + Send>, grammar: SqlGrammar, copy_overriding: Option<&str>) -> Self {
        let consumed = Arc::new(AtomicU64::new(0));
        let counted = Counted {
            inner: file,
            consumed: Arc::clone(&consumed),
        };
        let mut buffered = BufReader::with_capacity(READ_BYTES, counted);
        let gzipped = buffered
            .fill_buf()
            .map(|head| head.starts_with(&GZIP_MAGIC))
            .unwrap_or(false);
        let source: Box<dyn BufRead + Send> = match gzipped {
            true => Box::new(BufReader::with_capacity(READ_BYTES, MultiGzDecoder::new(buffered))),
            false => Box::new(buffered),
        };
        Self {
            source,
            reader: Some(ScriptReader::new(grammar).with_copy_overriding(copy_overriding)),
            units: VecDeque::new(),
            consumed,
            partial: Vec::new(),
            line: 1,
            first: true,
            failed: false,
        }
    }

    /// The bytes of the file read so far, shared so another thread can
    /// show progress.
    pub fn consumed(&self) -> Arc<AtomicU64> {
        Arc::clone(&self.consumed)
    }

    fn fill(&mut self) -> Result<bool, SqlFileError> {
        let mut bytes = vec![0; READ_BYTES];
        let read = loop {
            match self.source.read(&mut bytes) {
                Ok(read) => break read,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(SqlFileError::Read(error.to_string())),
            }
        };
        if read == 0 {
            if !self.partial.is_empty() {
                return Err(SqlFileError::NotUtf8 { line: self.line });
            }
            let Some(reader) = self.reader.take() else {
                return Ok(false);
            };
            self.units.extend(reader.finish()?);
            return Ok(true);
        }
        if self.reader.is_none() {
            return Ok(false);
        }
        bytes.truncate(read);
        let mut chunk = std::mem::take(&mut self.partial);
        chunk.extend_from_slice(&bytes);
        if self.first {
            self.first = false;
            if chunk.starts_with(b"\xEF\xBB\xBF") {
                chunk.drain(..3);
            }
        }
        let valid = match std::str::from_utf8(&chunk) {
            Ok(_) => chunk.len(),
            Err(error) if error.error_len().is_none() => error.valid_up_to(),
            Err(error) => {
                let before = chunk.get(..error.valid_up_to()).unwrap_or_default();
                let line = self.line + before.iter().filter(|byte| **byte == b'\n').count() as u64;
                return Err(SqlFileError::NotUtf8 { line });
            }
        };
        self.partial = chunk.split_off(valid);
        let text = String::from_utf8(chunk).map_err(|_| SqlFileError::NotUtf8 { line: self.line })?;
        self.line += text.matches('\n').count() as u64;
        let Some(reader) = self.reader.as_mut() else {
            return Ok(false);
        };
        self.units.extend(reader.push(&text)?);
        Ok(true)
    }
}

impl Iterator for SqlFileReader {
    type Item = Result<ScriptUnit, SqlFileError>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            if let Some(unit) = self.units.pop_front() {
                return Some(Ok(unit));
            }
            if self.failed {
                return None;
            }
            match self.fill() {
                Ok(true) => {}
                Ok(false) => return None,
                Err(error) => {
                    self.failed = true;
                    return Some(Err(error));
                }
            }
        }
    }
}

struct Counted {
    inner: Box<dyn Read + Send>,
    consumed: Arc<AtomicU64>,
}

impl Read for Counted {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let read = self.inner.read(buffer)?;
        self.consumed.fetch_add(read as u64, Ordering::Relaxed);
        Ok(read)
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write as _;

    use flate2::Compression;
    use flate2::write::GzEncoder;

    use super::*;

    fn units(bytes: Vec<u8>) -> Vec<Result<ScriptUnit, SqlFileError>> {
        SqlFileReader::new(Box::new(std::io::Cursor::new(bytes)), SqlGrammar::Sqlite, None).collect()
    }

    fn texts(bytes: Vec<u8>) -> Vec<String> {
        units(bytes)
            .into_iter()
            .map(|unit| unit.expect("a unit").text)
            .collect()
    }

    #[test]
    fn a_gzipped_file_reads_as_its_text() {
        let text = (0..5000)
            .map(|n| format!("INSERT INTO t VALUES ({n}, 'é');\n"))
            .collect::<String>();
        let mut gzip = GzEncoder::new(Vec::new(), Compression::fast());
        gzip.write_all(text.as_bytes()).expect("write");
        let plain = texts(text.clone().into_bytes());

        let read = texts(gzip.finish().expect("finish"));

        assert_eq!(read.len(), 5000);
        assert_eq!(read, plain);
    }

    #[test]
    fn a_byte_order_mark_is_passed_over() {
        assert_eq!(texts(b"\xEF\xBB\xBFSELECT 1;".to_vec()), ["SELECT 1"]);
    }

    #[test]
    fn bytes_that_are_not_utf8_name_their_line() {
        let read = units(b"SELECT 1;\nSELECT 2;\nSELECT X'00', '\xff';\n".to_vec());

        assert_eq!(read.last(), Some(&Err(SqlFileError::NotUtf8 { line: 3 })));
    }

    #[test]
    fn a_character_cut_between_reads_is_whole() {
        // The read ends between the two bytes of the é.
        let mut text = "-".repeat(READ_BYTES - 10);
        text.push_str("\nSELECT 'é';\n");

        assert_eq!(texts(text.into_bytes()), ["SELECT 'é'"]);
    }
}
