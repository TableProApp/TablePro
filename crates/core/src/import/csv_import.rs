use std::path::Path;

use thiserror::Error;

use crate::export::CsvDelimiter;
use crate::query::ColumnInfo;

/// Largest file the import will read into memory. A delimited file is
/// read whole because the mapping dialog and the row budget both need
/// the row count before the first statement runs.
pub const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;

pub const MAX_COLUMNS: usize = 512;

// Hex-escaped binary doubles in CSV and adds its `\\x` prefix, so this admits
// a 1 MiB binary value while keeping each untrusted field bounded.
pub const MAX_FIELD_BYTES: usize = 2 * 1024 * 1024 + 2;

pub const MAX_IMPORT_ROWS: usize = 1_000_000;

/// Rows the mapping dialog reads before the user commits to anything.
pub const MAX_PREVIEW_ROWS: usize = 50;

/// Lines the format detector looks at. Enough to tell a delimiter from a
/// character that happens to appear in the first row.
const DETECT_LINES: usize = 20;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ImportError {
    #[error("the file is {size} bytes, over the {limit} byte limit")]
    FileTooLarge { size: u64, limit: u64 },

    #[error("the file could not be opened")]
    Unreadable,

    #[error("the file is not valid UTF-8 at byte {offset}")]
    NotUtf8 { offset: usize },

    #[error("line {line} could not be read as delimited text")]
    Malformed { line: u64 },

    #[error("the file has no columns in it")]
    NoColumns,

    #[error("the file has {columns} columns, over the {limit} column limit")]
    TooManyColumns { columns: usize, limit: usize },

    #[error("the file has more than {limit} rows")]
    TooManyRows { limit: usize },

    #[error("a field on line {line} is over the {limit} byte limit")]
    FieldTooLong { line: usize, limit: usize },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CsvFormat {
    pub delimiter: CsvDelimiter,
    pub has_header: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CsvImportOptions {
    pub delimiter: CsvDelimiter,
    /// Whether the first record names the columns rather than holding data.
    pub has_header: bool,
    /// The text standing for NULL. Empty by default, which is what every
    /// export in this app writes for a NULL.
    pub null_marker: String,
}

impl Default for CsvImportOptions {
    fn default() -> Self {
        Self {
            delimiter: CsvDelimiter::Comma,
            has_header: true,
            null_marker: String::new(),
        }
    }
}

impl From<CsvFormat> for CsvImportOptions {
    fn from(format: CsvFormat) -> Self {
        Self {
            delimiter: format.delimiter,
            has_header: format.has_header,
            null_marker: String::new(),
        }
    }
}

/// A delimited file as the import reads it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CsvSheet {
    /// One name per field, from the header record or made up from the
    /// position when there is none.
    pub headers: Vec<String>,
    pub rows: Vec<Vec<String>>,
    /// Rows past `limit` when the read was a preview, so the dialog can
    /// say there is more behind it.
    pub truncated: bool,
}

pub fn read_csv_file(path: &Path, options: &CsvImportOptions, limit: Option<usize>) -> Result<CsvSheet, ImportError> {
    let size = std::fs::metadata(path).map_err(|_| ImportError::Unreadable)?.len();
    check_file_size(size)?;
    let bytes = std::fs::read(path).map_err(|_| ImportError::Unreadable)?;
    read_csv(&bytes, options, limit)
}

fn check_file_size(size: u64) -> Result<(), ImportError> {
    if size > MAX_FILE_BYTES {
        return Err(ImportError::FileTooLarge {
            size,
            limit: MAX_FILE_BYTES,
        });
    }
    Ok(())
}

/// Read `bytes` as delimited text. `limit` caps the rows returned, for the
/// preview the mapping dialog draws.
///
/// Ragged records are kept rather than refused: a short row is padded with
/// empty fields and a long one keeps its extra fields, because the mapping
/// decides which fields matter.
pub fn read_csv(bytes: &[u8], options: &CsvImportOptions, limit: Option<usize>) -> Result<CsvSheet, ImportError> {
    check_file_size(bytes.len() as u64)?;
    if let Err(error) = std::str::from_utf8(bytes) {
        return Err(ImportError::NotUtf8 {
            offset: error.valid_up_to(),
        });
    }
    let mut reader = reader_for(bytes, options);
    let headers = match options.has_header {
        true => record_strings(reader.headers().map_err(malformed)?, 1)?,
        false => Vec::new(),
    };
    check_width(headers.len())?;
    let (rows, truncated) = collect_rows(&mut reader, options, limit)?;
    finish_sheet(headers, rows, truncated)
}

fn reader_for<'a>(bytes: &'a [u8], options: &CsvImportOptions) -> csv::Reader<&'a [u8]> {
    csv::ReaderBuilder::new()
        .delimiter(delimiter_byte(options.delimiter))
        .has_headers(options.has_header)
        .flexible(true)
        .from_reader(bytes)
}

fn collect_rows(
    reader: &mut csv::Reader<&[u8]>,
    options: &CsvImportOptions,
    limit: Option<usize>,
) -> Result<(Vec<Vec<String>>, bool), ImportError> {
    let header_offset = usize::from(options.has_header);
    let mut rows: Vec<Vec<String>> = Vec::new();
    for (index, record) in reader.records().enumerate() {
        if let Some(limit) = limit
            && rows.len() >= limit
        {
            return Ok((rows, true));
        }
        if rows.len() >= MAX_IMPORT_ROWS {
            return Err(ImportError::TooManyRows { limit: MAX_IMPORT_ROWS });
        }
        let record = record.map_err(malformed)?;
        let line = index + header_offset + 1;
        check_width(record.len())?;
        rows.push(record_strings(&record, line)?);
    }
    Ok((rows, false))
}

fn finish_sheet(headers: Vec<String>, mut rows: Vec<Vec<String>>, truncated: bool) -> Result<CsvSheet, ImportError> {
    let width = headers.len().max(rows.iter().map(Vec::len).max().unwrap_or(0));
    if width == 0 {
        return Err(ImportError::NoColumns);
    }
    check_width(width)?;
    let headers = match headers.is_empty() {
        true => (1..=width).map(|index| format!("Column {index}")).collect(),
        false => headers,
    };
    for row in &mut rows {
        row.resize(width.max(row.len()), String::new());
    }
    Ok(CsvSheet {
        headers,
        rows,
        truncated,
    })
}

fn record_strings(record: &csv::StringRecord, line: usize) -> Result<Vec<String>, ImportError> {
    let mut out = Vec::with_capacity(record.len());
    for field in record.iter() {
        if field.len() > MAX_FIELD_BYTES {
            return Err(ImportError::FieldTooLong {
                line,
                limit: MAX_FIELD_BYTES,
            });
        }
        out.push(field.to_owned());
    }
    Ok(out)
}

fn check_width(width: usize) -> Result<(), ImportError> {
    if width > MAX_COLUMNS {
        return Err(ImportError::TooManyColumns {
            columns: width,
            limit: MAX_COLUMNS,
        });
    }
    Ok(())
}

fn malformed(error: csv::Error) -> ImportError {
    ImportError::Malformed {
        line: error.position().map_or(0, csv::Position::line),
    }
}

/// Guess the delimiter and whether the first record is a header. Both are
/// overridable; this only decides what the dialog opens with.
pub fn detect_format(bytes: &[u8]) -> CsvFormat {
    let delimiter = detect_delimiter(bytes);
    CsvFormat {
        delimiter,
        has_header: detect_header(bytes, delimiter),
    }
}

fn detect_delimiter(bytes: &[u8]) -> CsvDelimiter {
    let mut best = CsvDelimiter::Comma;
    let mut best_score = 0;
    for delimiter in CsvDelimiter::ALL {
        let score = delimiter_score(bytes, delimiter);
        if score > best_score {
            best = delimiter;
            best_score = score;
        }
    }
    best
}

/// A delimiter scores by how many fields it finds across the sample. A
/// character that is not the delimiter yields one field per record, which
/// scores zero and leaves the default in place.
fn delimiter_score(bytes: &[u8], delimiter: CsvDelimiter) -> usize {
    let records = sample_records(bytes, delimiter);
    let Some(width) = records.first().map(Vec::len) else {
        return 0;
    };
    if width < 2 {
        return 0;
    }
    // Every delimiter candidate sees the same CSV record boundaries; compare
    // sampled width directly instead of scaling each candidate by that count.
    width
}

fn sample_records(bytes: &[u8], delimiter: CsvDelimiter) -> Vec<Vec<String>> {
    let options = CsvImportOptions {
        delimiter,
        has_header: false,
        null_marker: String::new(),
    };
    read_csv(bytes, &options, Some(DETECT_LINES)).map_or_else(|_| Vec::new(), |sheet| sheet.rows)
}

fn detect_header(bytes: &[u8], delimiter: CsvDelimiter) -> bool {
    let records = sample_records(bytes, delimiter);
    let Some(first) = records.first() else {
        return false;
    };
    if records.len() < 2 {
        return false;
    }
    first
        .iter()
        .all(|field| !field.trim().is_empty() && !looks_like_data(field))
}

fn looks_like_data(field: &str) -> bool {
    let trimmed = field.trim();
    trimmed.parse::<f64>().is_ok() || matches!(trimmed.to_ascii_lowercase().as_str(), "true" | "false" | "null")
}

/// A starting mapping: each table column takes the field whose header
/// matches its name, ignoring case and surrounding space. Columns the file
/// has no match for are left unmapped.
pub fn suggest_mapping(headers: &[String], columns: &[ColumnInfo]) -> Vec<Option<usize>> {
    columns
        .iter()
        .map(|column| {
            let wanted = column.name.trim().to_lowercase();
            headers.iter().position(|header| header.trim().to_lowercase() == wanted)
        })
        .collect()
}

fn delimiter_byte(delimiter: CsvDelimiter) -> u8 {
    match delimiter {
        CsvDelimiter::Comma => b',',
        CsvDelimiter::Semicolon => b';',
        CsvDelimiter::Tab => b'\t',
        CsvDelimiter::Pipe => b'|',
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn options() -> CsvImportOptions {
        CsvImportOptions::default()
    }

    #[test]
    fn csv_format_conversion_preserves_delimiter_and_header_choice() {
        let format = CsvFormat {
            delimiter: CsvDelimiter::Pipe,
            has_header: false,
        };

        let options = CsvImportOptions::from(format);

        assert_eq!(options.delimiter, CsvDelimiter::Pipe);
        assert!(!options.has_header);
        assert!(options.null_marker.is_empty());
    }

    #[test]
    fn public_import_limits_keep_their_documented_units() {
        assert_eq!(MAX_FILE_BYTES, 67_108_864);
        assert_eq!(MAX_COLUMNS, 512);
        assert_eq!(MAX_FIELD_BYTES, 2_097_154);
        assert_eq!(MAX_IMPORT_ROWS, 1_000_000);
        assert_eq!(MAX_PREVIEW_ROWS, 50);
    }

    #[test]
    fn file_size_limit_accepts_exact_boundary_and_refuses_one_byte_more() {
        assert_eq!(check_file_size(MAX_FILE_BYTES), Ok(()));
        assert_eq!(
            check_file_size(MAX_FILE_BYTES + 1),
            Err(ImportError::FileTooLarge {
                size: MAX_FILE_BYTES + 1,
                limit: MAX_FILE_BYTES,
            })
        );
    }

    #[test]
    fn read_csv_file_observes_delimiter_header_and_preview_options() {
        let mut file = tempfile::NamedTempFile::new().expect("temporary csv file");
        file.write_all(b"id\tname\n1\tAda\n2\tGrace\n")
            .expect("write csv fixture");
        let options = CsvImportOptions {
            delimiter: CsvDelimiter::Tab,
            has_header: true,
            null_marker: "\\N".into(),
        };

        let sheet = read_csv_file(file.path(), &options, Some(1)).expect("read from path");

        assert_eq!(sheet.headers, vec!["id", "name"]);
        assert_eq!(sheet.rows, vec![vec!["1", "Ada"]]);
        assert!(sheet.truncated);
    }

    #[test]
    fn read_csv_file_refuses_oversized_sparse_files_from_metadata() {
        let file = tempfile::NamedTempFile::new().expect("temporary csv file");
        file.as_file().set_len(MAX_FILE_BYTES + 1).expect("make sparse file");

        assert_eq!(
            read_csv_file(file.path(), &options(), None),
            Err(ImportError::FileTooLarge {
                size: MAX_FILE_BYTES + 1,
                limit: MAX_FILE_BYTES,
            })
        );
    }

    fn column(name: &str, data_type: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            data_type: data_type.to_owned(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    #[test]
    fn a_header_row_names_the_fields() {
        let sheet = read_csv(b"id,name\n1,ada\n", &options(), None).expect("read");

        assert_eq!(sheet.headers, vec!["id", "name"]);
        assert_eq!(sheet.rows, vec![vec!["1".to_owned(), "ada".to_owned()]]);
        assert!(!sheet.truncated);
    }

    #[test]
    fn a_file_with_no_header_gets_names_from_the_positions() {
        let mut options = options();
        options.has_header = false;

        let sheet = read_csv(b"1,ada\n2,grace\n", &options, None).expect("read");

        assert_eq!(sheet.headers, vec!["Column 1", "Column 2"]);
        assert_eq!(sheet.rows.len(), 2);
    }

    #[test]
    fn a_quoted_field_keeps_its_delimiters_and_newlines() {
        let sheet = read_csv(b"a,b\n\"one, two\",\"line\nbreak\"\n", &options(), None).expect("read");

        assert_eq!(sheet.rows[0][0], "one, two");
        assert_eq!(sheet.rows[0][1], "line\nbreak");
    }

    #[test]
    fn a_doubled_quote_inside_a_quoted_field_is_one_quote() {
        let sheet = read_csv(b"a\n\"say \"\"hi\"\"\"\n", &options(), None).expect("read");

        assert_eq!(sheet.rows[0][0], "say \"hi\"");
    }

    #[test]
    fn carriage_returns_do_not_survive_into_the_last_field() {
        let sheet = read_csv(b"a,b\r\n1,two\r\n", &options(), None).expect("read");

        assert_eq!(sheet.headers, vec!["a", "b"]);
        assert_eq!(sheet.rows[0], vec!["1".to_owned(), "two".to_owned()]);
    }

    /// The csv crate strips a leading UTF-8 byte order mark itself. If it
    /// ever stopped, the first header name would start with U+FEFF and
    /// match no column, so the import must keep testing for it.
    #[test]
    fn a_byte_order_mark_is_not_part_of_the_first_column_name() {
        let sheet = read_csv("\u{feff}id,name\n1,ada\n".as_bytes(), &options(), None).expect("read");

        assert_eq!(sheet.headers, vec!["id", "name"]);
    }

    #[test]
    fn a_short_row_is_padded_rather_than_refused() {
        let sheet = read_csv(b"a,b,c\n1\n", &options(), None).expect("read");

        assert_eq!(sheet.rows[0], vec!["1".to_owned(), String::new(), String::new()]);
    }

    #[test]
    fn a_long_row_keeps_the_fields_the_header_did_not_name() {
        let sheet = read_csv(b"a,b\n1,2,3\n", &options(), None).expect("read");

        assert_eq!(sheet.rows[0], vec!["1".to_owned(), "2".to_owned(), "3".to_owned()]);
    }

    #[test]
    fn a_preview_stops_at_the_limit_and_says_so() {
        let mut file = String::from("a\n");
        for index in 0..10 {
            file.push_str(&format!("{index}\n"));
        }

        let sheet = read_csv(file.as_bytes(), &options(), Some(3)).expect("read");

        assert_eq!(sheet.rows.len(), 3);
        assert!(sheet.truncated);
    }

    #[test]
    fn a_file_that_fits_the_limit_is_not_called_truncated() {
        let sheet = read_csv(b"a\n1\n2\n", &options(), Some(50)).expect("read");

        assert_eq!(sheet.rows.len(), 2);
        assert!(!sheet.truncated);
    }

    #[test]
    fn a_file_that_is_not_utf8_says_where_it_stops_being_text() {
        let error = read_csv(b"a,b\n1,\xff\n", &options(), None).expect_err("not utf-8");

        assert_eq!(error, ImportError::NotUtf8 { offset: 6 });
    }

    #[test]
    fn an_empty_file_has_no_columns() {
        assert_eq!(read_csv(b"", &options(), None), Err(ImportError::NoColumns));
    }

    #[test]
    fn a_field_over_the_length_limit_is_refused_and_names_the_line() {
        let mut file = String::from("a\n");
        file.push_str(&"x".repeat(MAX_FIELD_BYTES + 1));
        file.push('\n');

        let error = read_csv(file.as_bytes(), &options(), None).expect_err("too long");

        assert_eq!(
            error,
            ImportError::FieldTooLong {
                line: 2,
                limit: MAX_FIELD_BYTES
            }
        );
    }

    #[test]
    fn a_field_at_the_length_limit_is_accepted() {
        let mut file = String::from("a\n");
        file.push_str(&"x".repeat(MAX_FIELD_BYTES));
        file.push('\n');

        let sheet = read_csv(file.as_bytes(), &options(), None).expect("exact maximum field");

        assert_eq!(sheet.rows[0][0].len(), MAX_FIELD_BYTES);
    }

    #[test]
    fn a_file_over_the_size_limit_is_refused_before_it_is_parsed() {
        let bytes = vec![b'a'; (MAX_FILE_BYTES + 1) as usize];

        let error = read_csv(&bytes, &options(), None).expect_err("too large");

        assert!(matches!(error, ImportError::FileTooLarge { limit, .. } if limit == MAX_FILE_BYTES));
    }

    #[test]
    fn more_columns_than_the_limit_are_refused() {
        let header = (0..=MAX_COLUMNS).map(|index| format!("c{index}")).collect::<Vec<_>>();

        let error = read_csv(header.join(",").as_bytes(), &options(), None).expect_err("too wide");

        assert!(matches!(error, ImportError::TooManyColumns { limit, .. } if limit == MAX_COLUMNS));
    }

    #[test]
    fn the_maximum_column_count_is_accepted() {
        let header = (0..MAX_COLUMNS).map(|index| format!("c{index}")).collect::<Vec<_>>();

        let sheet = read_csv(header.join(",").as_bytes(), &options(), None).expect("exact maximum columns");

        assert_eq!(sheet.headers.len(), MAX_COLUMNS);
    }

    #[test]
    fn a_semicolon_file_is_detected_as_semicolon_delimited() {
        let format = detect_format(b"id;name;age\n1;ada;36\n2;grace;30\n");

        assert_eq!(format.delimiter, CsvDelimiter::Semicolon);
        assert!(format.has_header);
    }

    #[test]
    fn a_comma_file_is_detected_as_comma_delimited() {
        let format = detect_format(b"id,name,age\n1,ada,36\n");

        assert_eq!(format.delimiter, CsvDelimiter::Comma);
        assert!(format.has_header);
    }

    #[test]
    fn a_tab_file_is_detected_as_tab_delimited() {
        let format = detect_format(b"id\tname\n1\tada\n");

        assert_eq!(format.delimiter, CsvDelimiter::Tab);
        assert!(format.has_header);
    }

    #[test]
    fn a_file_whose_first_row_is_data_is_not_read_as_having_a_header() {
        let format = detect_format(b"1,ada\n2,grace\n3,alan\n");

        assert!(!format.has_header);
    }

    #[test]
    fn a_single_column_file_falls_back_to_the_comma() {
        let format = detect_format(b"name\nada\ngrace\n");

        assert_eq!(format.delimiter, CsvDelimiter::Comma);
    }

    #[test]
    fn a_mapping_matches_on_name_whatever_the_case_or_spacing() {
        let headers = vec!["ID".to_owned(), " Name ".to_owned(), "extra".to_owned()];
        let columns = vec![
            column("name", "text"),
            column("id", "bigint"),
            column("missing", "text"),
        ];

        assert_eq!(suggest_mapping(&headers, &columns), vec![Some(1), Some(0), None]);
    }
}
