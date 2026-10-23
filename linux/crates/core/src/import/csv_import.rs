use thiserror::Error;

use crate::column::ColumnInfo;
use crate::edit::{CellInput, EditParseError, parse_literal_text};
use crate::export::CsvDelimiter;

use super::ImportColumn;

/// The most a CSV may be before the import refuses it.
///
/// Every row becomes an INSERT in one transaction, so the file's size
/// decides how much the app holds at once. Refusing is better than a
/// window that stops painting halfway through a file nobody meant to
/// open.
pub const MAX_CSV_FILE_BYTES: usize = 64 * 1024 * 1024;

/// How many rows the mapping dialog shows. Enough to tell whether the
/// delimiter and the header switch are right, few enough that a
/// gigabyte file still opens the dialog at once.
pub const MAX_PREVIEW_ROWS: usize = 50;

/// The most fields one record may have. No engine takes a table this
/// wide (MySQL stops at 4,096 columns), and every row of the preview is
/// padded to the widest, so a line of nothing but commas must not decide
/// how much is allocated.
pub const MAX_FIELDS: usize = 4_096;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ImportError {
    #[error("the file is not valid UTF-8 at byte {offset}")]
    NotUtf8 { offset: usize },

    /// The csv crate's message is English only, so only where it
    /// stopped is kept.
    #[error("the file could not be read as CSV")]
    Malformed { line: Option<u64> },

    #[error("the file has no columns in it")]
    NoColumns,

    #[error("line {line} has more than {limit} fields")]
    TooManyFields { line: u64, limit: usize },
}

/// What a row could not be turned into, named well enough for the user
/// to find the cell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CsvRowError {
    /// The row's position in the file, counting the header as row 1 so
    /// it matches what a spreadsheet shows.
    pub line: usize,
    pub column: String,
    pub text: String,
    pub reason: EditParseError,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CsvImportOptions {
    pub delimiter: CsvDelimiter,
    /// Whether the first record names the columns rather than holding
    /// data.
    pub has_header: bool,
    /// The text standing for NULL. Empty by default, which is what
    /// every export in this app writes for a NULL.
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

/// A CSV file as the import reads it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CsvSheet {
    /// One name per field, from the header record. Empty when the file
    /// has no header, for the app to name the field by its position.
    pub headers: Vec<String>,
    pub rows: Vec<Vec<String>>,
    /// Rows past `MAX_PREVIEW_ROWS` when the read was a preview, so the
    /// dialog can say how much more there is.
    pub truncated: bool,
}

/// Read `bytes` as CSV. `limit` caps the rows returned, for the preview
/// the mapping dialog draws before the user commits to anything.
///
/// Ragged records are kept rather than refused: a short row is padded
/// with empty fields and a long one keeps its extra fields, because the
/// mapping decides which fields matter and a file the user already has
/// is not improved by refusing to look at it.
pub fn read_csv(bytes: &[u8], options: &CsvImportOptions, limit: Option<usize>) -> Result<CsvSheet, ImportError> {
    if let Err(error) = std::str::from_utf8(bytes) {
        return Err(ImportError::NotUtf8 {
            offset: error.valid_up_to(),
        });
    }
    let mut reader = csv::ReaderBuilder::new()
        .delimiter(delimiter_byte(options.delimiter))
        .has_headers(options.has_header)
        .flexible(true)
        .from_reader(bytes);

    let headers: Vec<String> = match options.has_header {
        true => {
            let header = reader.headers().map_err(malformed)?;
            within_width(header)?;
            header.iter().map(str::to_owned).collect()
        }
        false => Vec::new(),
    };

    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut truncated = false;
    for record in reader.records() {
        let record = record.map_err(malformed)?;
        if let Some(limit) = limit
            && rows.len() >= limit
        {
            truncated = true;
            break;
        }
        within_width(&record)?;
        rows.push(record.iter().map(str::to_owned).collect());
    }

    let width = headers.len().max(rows.iter().map(Vec::len).max().unwrap_or(0));
    if width == 0 {
        return Err(ImportError::NoColumns);
    }
    let headers = match headers.is_empty() {
        true => vec![String::new(); width],
        false => headers,
    };
    // A short row is padded so every row can be indexed by field
    // number without a bounds check at every cell.
    for row in &mut rows {
        row.resize(width.max(row.len()), String::new());
    }

    Ok(CsvSheet {
        headers,
        rows,
        truncated,
    })
}

pub(super) fn malformed(error: csv::Error) -> ImportError {
    ImportError::Malformed {
        line: error.position().map(csv::Position::line),
    }
}

/// Refuse a record wider than `MAX_FIELDS` before its fields are copied.
pub(super) fn within_width(record: &csv::StringRecord) -> Result<(), ImportError> {
    match record.len() > MAX_FIELDS {
        true => Err(ImportError::TooManyFields {
            line: record.position().map_or(1, csv::Position::line),
            limit: MAX_FIELDS,
        }),
        false => Ok(()),
    }
}

/// A starting mapping: each table column takes the CSV field whose
/// header matches its name, ignoring case and surrounding space.
///
/// Columns the file has no match for are left unmapped, which the
/// dialog shows as "Skip" and the insert turns into the column's own
/// default. A column the server fills is never mapped.
pub fn suggest_mapping(headers: &[String], columns: &[ImportColumn]) -> Vec<Option<usize>> {
    columns
        .iter()
        .map(|column| {
            if column.server_filled {
                return None;
            }
            let wanted = column.info.name.trim().to_lowercase();
            headers.iter().position(|header| header.trim().to_lowercase() == wanted)
        })
        .collect()
}

/// Turn one CSV record into the cells an INSERT takes.
///
/// A column with no mapped field, or one whose field is past the end of
/// a short row, is left to its default rather than written as NULL: the
/// file said nothing about it, which is not the same as saying it is
/// empty. A column the server fills is left to it whatever the mapping
/// says.
pub fn row_to_cells(
    row: &[String],
    mapping: &[Option<usize>],
    columns: &[ImportColumn],
    options: &CsvImportOptions,
    line: usize,
) -> Result<Vec<CellInput>, CsvRowError> {
    columns
        .iter()
        .zip(mapping)
        .map(|(column, field)| {
            let Some(text) = field.filter(|_| !column.server_filled).and_then(|index| row.get(index)) else {
                return Ok(CellInput::Default);
            };
            cell_for(text, &column.info, options).map_err(|reason| CsvRowError {
                line,
                column: column.info.name.clone(),
                text: text.clone(),
                reason,
            })
        })
        .collect()
}

fn cell_for(text: &str, column: &ColumnInfo, options: &CsvImportOptions) -> Result<CellInput, EditParseError> {
    if text == options.null_marker {
        // An empty string is a value in its own right for a text
        // column, and the marker being empty is the common case. The
        // file holds it, so it wins over the column's default.
        if options.null_marker.is_empty() && column.column_type.kind.accepts_empty_string() {
            return Ok(CellInput::Value(crate::value::Value::Text(String::new())));
        }
        // A NOT NULL column with a default is better served by its
        // default than by an insert the server will refuse.
        if !column.nullable && !column.default.is_none() {
            return Ok(CellInput::Default);
        }
        return Ok(CellInput::Value(crate::value::Value::Null));
    }
    parse_literal_text(text, &column.column_type).map(CellInput::Value)
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
    use crate::column::{
        ColumnDefault, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm, SqlExpression, TextLength,
    };
    use crate::value::Value;

    fn options() -> CsvImportOptions {
        CsvImportOptions::default()
    }

    fn column(name: &str, kind: ColumnKind, sql: &str) -> ImportColumn {
        ImportColumn {
            info: column_info(name, kind, sql),
            server_filled: false,
        }
    }

    fn column_info(name: &str, kind: ColumnKind, sql: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType {
                name: sql.to_owned(),
                kind,
                catalog: None,
                dynamic_storage: true,
                read_form: ReadForm::Native,
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn text_column(name: &str) -> ImportColumn {
        column(
            name,
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
            "text",
        )
    }

    fn int_column(name: &str) -> ImportColumn {
        column(
            name,
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W64,
                signed: true,
            }),
            "bigint",
        )
    }

    #[test]
    fn a_header_row_names_the_fields() {
        let sheet = read_csv(b"id,name\n1,ada\n", &options(), None).expect("read");

        assert_eq!(sheet.headers, vec!["id", "name"]);
        assert_eq!(sheet.rows, vec![vec!["1".to_owned(), "ada".to_owned()]]);
        assert!(!sheet.truncated);
    }

    #[test]
    fn a_file_with_no_header_leaves_its_field_names_empty() {
        let mut options = options();
        options.has_header = false;

        let sheet = read_csv(b"1,ada\n2,grace\n", &options, None).expect("read");

        assert_eq!(sheet.headers, vec![String::new(), String::new()]);
        assert_eq!(sheet.rows.len(), 2);
    }

    #[test]
    fn another_delimiter_is_read_as_asked() {
        let mut options = options();
        options.delimiter = CsvDelimiter::Semicolon;

        let sheet = read_csv(b"id;name\n1;ada\n", &options, None).expect("read");

        assert_eq!(sheet.headers, vec!["id", "name"]);
        assert_eq!(sheet.rows[0], vec!["1".to_owned(), "ada".to_owned()]);
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
    fn a_quoted_field_keeps_its_commas_and_newlines() {
        let sheet = read_csv(b"a,b\n\"one, two\",\"line\nbreak\"\n", &options(), None).expect("read");

        assert_eq!(sheet.rows[0][0], "one, two");
        assert_eq!(sheet.rows[0][1], "line\nbreak");
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
    fn a_record_wider_than_any_table_is_refused_before_it_is_padded() {
        let mut file = String::from("a,b\n1,2\n");
        file.push_str(&",".repeat(MAX_FIELDS));
        file.push('\n');
        let header = format!("{}\n1\n", ",".repeat(MAX_FIELDS));

        assert_eq!(
            read_csv(file.as_bytes(), &options(), Some(MAX_PREVIEW_ROWS)),
            Err(ImportError::TooManyFields {
                line: 3,
                limit: MAX_FIELDS
            })
        );
        assert_eq!(
            read_csv(header.as_bytes(), &options(), None),
            Err(ImportError::TooManyFields {
                line: 1,
                limit: MAX_FIELDS
            })
        );
        let widest = format!("{}\n", ",".repeat(MAX_FIELDS - 1));
        assert!(read_csv(widest.as_bytes(), &options(), None).is_ok());
    }

    #[test]
    fn an_empty_file_has_no_columns() {
        assert_eq!(read_csv(b"", &options(), None), Err(ImportError::NoColumns));
    }

    #[test]
    fn a_mapping_matches_on_name_whatever_the_case_or_spacing() {
        let headers = vec!["ID".to_owned(), " Name ".to_owned(), "extra".to_owned()];
        let columns = vec![text_column("name"), int_column("id"), text_column("missing")];

        assert_eq!(suggest_mapping(&headers, &columns), vec![Some(1), Some(0), None]);
    }

    #[test]
    fn a_mapped_field_is_parsed_into_the_columns_type() {
        let columns = vec![int_column("id"), text_column("name")];
        let row = vec!["7".to_owned(), "ada".to_owned()];

        let cells = row_to_cells(&row, &[Some(0), Some(1)], &columns, &options(), 2).expect("cells");

        assert_eq!(cells[0], CellInput::Value(Value::Int(7)));
        assert_eq!(cells[1], CellInput::Value(Value::Text("ada".to_owned())));
    }

    #[test]
    fn an_unmapped_column_is_left_to_its_default() {
        let columns = vec![int_column("id"), text_column("name")];
        let row = vec!["7".to_owned()];

        let cells = row_to_cells(&row, &[Some(0), None], &columns, &options(), 2).expect("cells");

        assert_eq!(cells[1], CellInput::Default);
    }

    #[test]
    fn an_empty_field_is_null_for_a_column_that_is_not_text() {
        let columns = vec![int_column("id")];
        let row = vec![String::new()];

        let cells = row_to_cells(&row, &[Some(0)], &columns, &options(), 2).expect("cells");

        assert_eq!(cells[0], CellInput::Value(Value::Null));
    }

    #[test]
    fn an_empty_field_stays_an_empty_string_for_a_text_column() {
        // Every export in this app writes NULL as an empty field, but
        // so is an empty string, and for text the empty string is the
        // reading that loses nothing.
        let columns = vec![text_column("name")];
        let row = vec![String::new()];

        let cells = row_to_cells(&row, &[Some(0)], &columns, &options(), 2).expect("cells");

        assert_eq!(cells[0], CellInput::Value(Value::Text(String::new())));
    }

    #[test]
    fn a_null_marker_the_user_set_is_null_even_for_text() {
        let mut options = options();
        options.null_marker = "\\N".to_owned();
        let columns = vec![text_column("name")];

        let cells = row_to_cells(&["\\N".to_owned()], &[Some(0)], &columns, &options, 2).expect("cells");

        assert_eq!(cells[0], CellInput::Value(Value::Null));
    }

    #[test]
    fn a_not_null_column_with_a_default_takes_the_default_rather_than_a_refused_insert() {
        let mut columns = vec![int_column("id")];
        columns[0].info.nullable = false;
        columns[0].info.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("0"));

        let cells = row_to_cells(&[String::new()], &[Some(0)], &columns, &options(), 2).expect("cells");

        assert_eq!(cells[0], CellInput::Default);
    }

    #[test]
    fn an_empty_field_for_a_not_null_text_column_with_a_default_stays_empty() {
        let mut columns = vec![text_column("status")];
        columns[0].info.nullable = false;
        columns[0].info.default = ColumnDefault::Literal(Value::Text("active".to_owned()));

        let cells = row_to_cells(&[String::new()], &[Some(0)], &columns, &options(), 2).expect("cells");

        assert_eq!(cells[0], CellInput::Value(Value::Text(String::new())));
    }

    #[test]
    fn a_column_the_server_fills_is_never_mapped_or_written() {
        let mut columns = vec![int_column("id"), text_column("name")];
        columns[0].server_filled = true;
        let headers = vec!["id".to_owned(), "name".to_owned()];

        let mapping = suggest_mapping(&headers, &columns);
        let cells = row_to_cells(
            &["7".to_owned(), "ada".to_owned()],
            &[Some(0), Some(1)],
            &columns,
            &options(),
            2,
        )
        .expect("cells");

        assert_eq!(mapping, vec![None, Some(1)]);
        assert_eq!(
            cells[0],
            CellInput::Default,
            "a value went to a column the server fills"
        );
        assert_eq!(cells[1], CellInput::Value(Value::Text("ada".to_owned())));
    }

    #[test]
    fn an_auto_increment_column_takes_the_files_value() {
        let mut columns = vec![int_column("id")];
        columns[0].info.is_auto_increment = true;

        let mapping = suggest_mapping(&["id".to_owned()], &columns);
        let cells = row_to_cells(&["100".to_owned()], &mapping, &columns, &options(), 2).expect("cells");

        assert_eq!(cells[0], CellInput::Value(Value::Int(100)));
    }

    #[test]
    fn a_field_the_column_cannot_hold_names_the_row_and_the_cell() {
        let columns = vec![int_column("id")];

        let error = row_to_cells(&["not a number".to_owned()], &[Some(0)], &columns, &options(), 4)
            .expect_err("not an integer");

        assert_eq!(error.line, 4);
        assert_eq!(error.column, "id");
        assert_eq!(error.text, "not a number");
        assert_eq!(error.reason, EditParseError::InvalidInteger);
    }
}
