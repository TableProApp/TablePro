use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use flate2::bufread::MultiGzDecoder;

use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{LexicalSettings, ScriptReadError, ScriptReader, ScriptUnit};

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
    /// The error that ended the reading, given once the units read before
    /// it are taken.
    error: Option<SqlFileError>,
    /// Set by whoever stopped taking units, so a long run of lines that
    /// make none, such as a refused COPY block, is not read to its end.
    stop: Arc<AtomicBool>,
}

impl SqlFileReader {
    pub fn new(file: Box<dyn Read + Send>, grammar: SqlGrammar) -> Self {
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
            reader: Some(ScriptReader::new(grammar)),
            units: VecDeque::new(),
            consumed,
            partial: Vec::new(),
            line: 1,
            first: true,
            failed: false,
            error: None,
            stop: Arc::new(AtomicBool::new(false)),
        }
    }

    /// How the session reads a string as the file starts.
    pub fn with_settings(mut self, settings: LexicalSettings) -> Self {
        self.reader = self.reader.map(|reader| reader.with_settings(settings));
        self
    }

    /// The flag that ends the reading once set.
    pub fn stop(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.stop)
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
                Err(error) => {
                    self.plan_held()?;
                    return Err(SqlFileError::Read(error.to_string()));
                }
            }
        };
        if read == 0 {
            if !self.partial.is_empty() {
                self.plan_held()?;
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
                // The statements that end before the byte still run.
                if let (Ok(text), Some(reader)) = (std::str::from_utf8(before), self.reader.as_mut()) {
                    self.units.extend(reader.push_last(text)?);
                }
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

impl SqlFileReader {
    /// Plan what the reader holds now, so the statements read whole before
    /// the file stops being readable still run.
    fn plan_held(&mut self) -> Result<(), SqlFileError> {
        if let Some(reader) = self.reader.as_mut() {
            self.units.extend(reader.push_last("")?);
        }
        Ok(())
    }
}

impl Iterator for SqlFileReader {
    type Item = Result<ScriptUnit, SqlFileError>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            if let Some(unit) = self.units.pop_front() {
                return Some(Ok(unit));
            }
            if let Some(error) = self.error.take() {
                return Some(Err(error));
            }
            if self.failed || self.stop.load(Ordering::Relaxed) {
                return None;
            }
            match self.fill() {
                Ok(true) => {}
                Ok(false) => return None,
                Err(error) => {
                    self.failed = true;
                    self.error = Some(error);
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
        SqlFileReader::new(Box::new(std::io::Cursor::new(bytes)), SqlGrammar::Sqlite).collect()
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

        let ran: Vec<&str> = read
            .iter()
            .filter_map(|unit| unit.as_ref().ok())
            .map(|unit| unit.text.as_str())
            .collect();
        assert_eq!(ran, ["SELECT 1", "SELECT 2"], "the statements before the byte");
        assert_eq!(read.last(), Some(&Err(SqlFileError::NotUtf8 { line: 3 })));
    }

    #[test]
    fn a_copy_row_that_is_not_utf8_names_its_line() {
        let file = b"COPY t (a) FROM stdin;\nok\n\xff\n\\.\n".to_vec();

        let read: Vec<Result<ScriptUnit, SqlFileError>> =
            SqlFileReader::new(Box::new(std::io::Cursor::new(file)), SqlGrammar::PostgreSql).collect();

        assert_eq!(read.last(), Some(&Err(SqlFileError::NotUtf8 { line: 3 })));
    }

    /// Gives at most `chunk` bytes a read, as a pipe can, and then fails
    /// when `fails`.
    struct Trickle {
        bytes: Vec<u8>,
        at: usize,
        chunk: usize,
        fails: bool,
    }

    impl Trickle {
        fn new(bytes: &[u8], fails: bool) -> Self {
            Self {
                bytes: bytes.to_vec(),
                at: 0,
                chunk: 20,
                fails,
            }
        }
    }

    impl Read for Trickle {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            let rest = self.bytes.get(self.at..).unwrap_or_default();
            if rest.is_empty() && self.fails {
                return Err(std::io::Error::other("the copy was cut off"));
            }
            let read = rest.len().min(self.chunk).min(buffer.len());
            buffer[..read].copy_from_slice(&rest[..read]);
            self.at += read;
            Ok(read)
        }
    }

    fn read_trickle(file: Trickle) -> (Vec<String>, Option<SqlFileError>) {
        let read: Vec<Result<ScriptUnit, SqlFileError>> =
            SqlFileReader::new(Box::new(file), SqlGrammar::Sqlite).collect();
        let ran = read
            .iter()
            .filter_map(|unit| unit.as_ref().ok())
            .map(|unit| unit.text.clone())
            .collect();
        (ran, read.last().and_then(|unit| unit.clone().err()))
    }

    #[test]
    fn the_statements_read_whole_before_the_file_stops_being_readable_run() {
        let cases = [
            (
                Trickle::new(b"SELECT 1;\nSELECT 2;\nSELECT 3;\n'\xff';\n", false),
                SqlFileError::NotUtf8 { line: 4 },
            ),
            (
                Trickle::new(b"SELECT 1;\nSELECT 2;\nSELECT 3;\n\xc3", false),
                SqlFileError::NotUtf8 { line: 4 },
            ),
            (
                Trickle::new(b"SELECT 1;\nSELECT 2;\nSELECT 3;\n", true),
                SqlFileError::Read("the copy was cut off".to_owned()),
            ),
        ];

        for (file, error) in cases {
            let (ran, last) = read_trickle(file);

            assert_eq!(ran, ["SELECT 1", "SELECT 2", "SELECT 3"], "{error:?}");
            assert_eq!(last, Some(error));
        }
    }

    #[test]
    fn a_character_cut_between_reads_is_whole() {
        // The read ends between the two bytes of the é.
        let mut text = "-".repeat(READ_BYTES - 10);
        text.push_str("\nSELECT 'é';\n");

        assert_eq!(texts(text.into_bytes()), ["SELECT 'é'"]);
    }
}
