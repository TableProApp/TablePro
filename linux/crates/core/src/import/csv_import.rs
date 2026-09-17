use thiserror::Error;

use crate::column::ColumnInfo;
use crate::edit::{CellInput, parse_literal_text};
use crate::export::CsvDelimiter;

/// How many rows the mapping dialog shows. Enough to tell whether the
/// delimiter and the header switch are right, few enough that a
/// gigabyte file still opens the dialog at once.
pub const MAX_PREVIEW_ROWS: usize = 50;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ImportError {
    #[error("the file is not valid UTF-8 at byte {offset}")]
    NotUtf8 { offset: usize },

    #[error("the file could not be read as CSV: {0}")]
    Malformed(String),

    #[error("the file has no columns in it")]
    NoColumns,
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
    pub reason: String,
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
    /// One name per field, from the header record or made up from the
    /// position when there is none.
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
        true => reader
            .headers()
            .map_err(|error| ImportError::Malformed(error.to_string()))?
            .iter()
            .map(str::to_owned)
            .collect(),
        false => Vec::new(),
    };

    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut truncated = false;
    for record in reader.records() {
        let record = record.map_err(|error| ImportError::Malformed(error.to_string()))?;
        if let Some(limit) = limit
            && rows.len() >= limit
        {
            truncated = true;
            break;
        }
        rows.push(record.iter().map(str::to_owned).collect());
    }

    let width = headers.len().max(rows.iter().map(Vec::len).max().unwrap_or(0));
    if width == 0 {
        return Err(ImportError::NoColumns);
    }
    let headers = match headers.is_empty() {
        true => (1..=width).map(|index| format!("Column {index}")).collect(),
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

/// A starting mapping: each table column takes the CSV field whose
/// header matches its name, ignoring case and surrounding space.
///
/// Columns the file has no match for are left unmapped, which the
/// dialog shows as "Skip" and the insert turns into the column's own
/// default.
pub fn suggest_mapping(headers: &[String], columns: &[ColumnInfo]) -> Vec<Option<usize>> {
    columns
        .iter()
        .map(|column| {
            let wanted = column.name.trim().to_lowercase();
            headers.iter().position(|header| header.trim().to_lowercase() == wanted)
        })
        .collect()
}

/// Turn one CSV record into the cells an INSERT takes.
///
/// A column with no mapped field, or one whose field is past the end of
/// a short row, is left to its default rather than written as NULL: the
/// file said nothing about it, which is not the same as saying it is
/// empty.
pub fn row_to_cells(
    row: &[String],
    mapping: &[Option<usize>],
    columns: &[ColumnInfo],
    options: &CsvImportOptions,
    line: usize,
) -> Result<Vec<CellInput>, CsvRowError> {
    columns
        .iter()
        .zip(mapping)
        .map(|(column, field)| {
            let Some(text) = field.and_then(|index| row.get(index)) else {
                return Ok(CellInput::Default);
            };
            cell_for(text, column, options).map_err(|reason| CsvRowError {
                line,
                column: column.name.clone(),
                text: text.clone(),
                reason,
            })
        })
        .collect()
}

fn cell_for(text: &str, column: &ColumnInfo, options: &CsvImportOptions) -> Result<CellInput, String> {
    if text == options.null_marker {
        // A NOT NULL column with a default is better served by its
        // default than by an insert the server will refuse.
        if !column.nullable && !column.default.is_none() {
            return Ok(CellInput::Default);
        }
        // An empty string is a value in its own right for a text
        // column, and the marker being empty is the common case.
        if options.null_marker.is_empty() && column.column_type.kind().accepts_empty_string() {
            return Ok(CellInput::Value(crate::value::Value::Text(String::new())));
        }
        return Ok(CellInput::Value(crate::value::Value::Null));
    }
    parse_literal_text(text, &column.column_type)
        .map(CellInput::Value)
        .map_err(|error| error.to_string())
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
        CatalogType, ColumnDefault, ColumnKind, ColumnType, IntegerKind, ReadForm, SqlExpression, SqlTypeExpr, TextKind,
    };
    use crate::value::Value;

    fn options() -> CsvImportOptions {
        CsvImportOptions::default()
    }

    fn column(name: &str, kind: ColumnKind, sql: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::new(
                SqlTypeExpr::from_catalog_text(sql),
                kind,
                CatalogType::Unknown,
                true,
                ReadForm::Native,
            ),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn text_column(name: &str) -> ColumnInfo {
        column(name, ColumnKind::Text(TextKind::Variable), "text")
    }

    fn int_column(name: &str) -> ColumnInfo {
        column(name, ColumnKind::Integer(IntegerKind::I64), "bigint")
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
        columns[0].nullable = false;
        columns[0].default = ColumnDefault::Expression(SqlExpression::from_catalog_text("0"));

        let cells = row_to_cells(&[String::new()], &[Some(0)], &columns, &options(), 2).expect("cells");

        assert_eq!(cells[0], CellInput::Default);
    }

    #[test]
    fn a_field_the_column_cannot_hold_names_the_row_and_the_cell() {
        let columns = vec![int_column("id")];

        let error = row_to_cells(&["not a number".to_owned()], &[Some(0)], &columns, &options(), 4)
            .expect_err("not an integer");

        assert_eq!(error.line, 4);
        assert_eq!(error.column, "id");
        assert_eq!(error.text, "not a number");
        assert!(!error.reason.is_empty());
    }
}
