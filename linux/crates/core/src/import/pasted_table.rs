use std::fmt;

use serde::Deserialize;
use serde::de::{self, Deserializer, IgnoredAny, SeqAccess, Visitor};

use crate::column::{ColumnInfo, ColumnKind, ReadForm};
use crate::edit::{CellInput, EditContext, EditParseError, new_draft_cell, parse_edit_text, read_only_reason};
use crate::export::TSV_NULL;
use crate::value::Value;

use super::csv_import::{malformed, within_width};
use super::{CsvRowError, ImportError, MAX_FIELDS, PastedRows};

/// The most lines a paste reads, a header among them. Each becomes a
/// pending row the grid holds, and Import CSV is the tool for more.
pub const MAX_PASTED_ROWS: usize = 100_000;

/// The most cells the new rows of a paste may hold, every column of the
/// table counted: a short line into a wide table makes a whole row, and
/// the undo history keeps a second copy.
pub const MAX_PASTED_CELLS: usize = 2_000_000;

/// Rows from the clipboard, before they meet a table: the cells a grid
/// copy wrote, or text read as tab-separated rows, which is what the
/// copy also writes and what a spreadsheet puts on the clipboard.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PastedTable {
    header: Header,
    records: Vec<PastedRecord>,
    /// More lines followed the last one kept than a paste reads.
    truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
enum Header {
    /// Text says nothing, so its first line may name them.
    #[default]
    Unknown,
    /// A grid copy that showed no names: every record is a row. It still
    /// says which columns the cells came from.
    Unnamed(Vec<String>),
    Named(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PastedRecord {
    /// Where the record starts, from 1, which an error names.
    line: usize,
    /// `None` is a NULL.
    fields: Vec<Option<PastedField>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(from = "CopiedCell")]
struct PastedField {
    text: String,
    stored: Stored,
}

/// How the copied value was stored, which its text does not say.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stored {
    Text,
    Integer,
    Real,
    Bytes,
}

/// A cell as `CellsEncoder` writes it.
#[derive(Deserialize)]
#[serde(untagged)]
enum CopiedCell {
    Text(String),
    Integer { int: String },
    Real { real: String },
    Bytes { bytes: String },
}

impl From<CopiedCell> for PastedField {
    fn from(cell: CopiedCell) -> Self {
        let (text, stored) = match cell {
            CopiedCell::Text(text) => (text, Stored::Text),
            CopiedCell::Integer { int } => (int, Stored::Integer),
            CopiedCell::Real { real } => (real, Stored::Real),
            CopiedCell::Bytes { bytes } => (bytes, Stored::Bytes),
        };
        Self { text, stored }
    }
}

impl PastedField {
    fn plain(text: &str) -> Self {
        Self {
            text: text.to_owned(),
            stored: Stored::Text,
        }
    }

    /// The value as it was stored, for a column that keeps whatever it is
    /// given.
    fn stored_value(&self) -> Option<Value> {
        match self.stored {
            Stored::Text => None,
            Stored::Integer => self
                .text
                .parse()
                .map(Value::Int)
                .or_else(|_| self.text.parse().map(Value::UInt))
                .ok(),
            // SQLite stores a NaN as NULL, which its text keeps.
            Stored::Real => self
                .text
                .parse()
                .ok()
                .filter(|real: &f64| real.is_finite())
                .map(Value::Float64),
            Stored::Bytes => crate::hex::decode(self.text.strip_prefix("0x")?).map(Value::Bytes),
        }
    }
}

/// The column each field of a record goes to, by position or by the
/// names a header gave them.
enum Placement<'a> {
    InOrder(&'a [usize]),
    Named(Vec<Option<usize>>),
}

/// What `CellsEncoder` writes. Another program can put anything under
/// its type, so the rows are counted as they are read.
#[derive(Deserialize)]
struct CopiedCells {
    #[serde(default)]
    columns: Vec<String>,
    headers: Option<Vec<String>>,
    rows: CopiedRows,
}

struct CopiedRows {
    rows: Vec<Vec<Option<PastedField>>>,
    truncated: bool,
}

impl<'de> Deserialize<'de> for CopiedRows {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_seq(RowsVisitor)
    }
}

struct RowsVisitor;

impl<'de> Visitor<'de> for RowsVisitor {
    type Value = CopiedRows;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a list of rows")
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        let mut rows = Vec::new();
        while rows.len() < MAX_PASTED_ROWS {
            match seq.next_element::<CopiedRow>()? {
                Some(CopiedRow(fields)) => rows.push(fields),
                None => return Ok(CopiedRows { rows, truncated: false }),
            }
        }
        let truncated = seq.next_element::<IgnoredAny>()?.is_some();
        while seq.next_element::<IgnoredAny>()?.is_some() {}
        Ok(CopiedRows { rows, truncated })
    }
}

/// One row's fields, refused past the widest a table can be before they
/// are all held.
struct CopiedRow(Vec<Option<PastedField>>);

impl<'de> Deserialize<'de> for CopiedRow {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_seq(RowVisitor)
    }
}

struct RowVisitor;

impl<'de> Visitor<'de> for RowVisitor {
    type Value = CopiedRow;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a list of values")
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        let mut fields = Vec::new();
        while let Some(field) = seq.next_element::<Option<PastedField>>()? {
            if fields.len() == MAX_FIELDS {
                return Err(de::Error::custom(format!("a row has more than {MAX_FIELDS} values")));
            }
            fields.push(field);
        }
        Ok(CopiedRow(fields))
    }
}

impl PastedTable {
    /// Text as tab-separated rows. A quoted field keeps its tabs, line
    /// breaks and doubled quotes, as the copy wrote them, and `NULL`,
    /// which is how the copy writes a NULL, is one.
    pub fn read(text: &str) -> Result<Self, ImportError> {
        let mut reader = csv::ReaderBuilder::new()
            .delimiter(b'\t')
            .has_headers(false)
            .flexible(true)
            .from_reader(text.as_bytes());
        let mut records = Vec::new();
        let mut truncated = false;
        for record in reader.records() {
            let record = record.map_err(malformed)?;
            if records.len() == MAX_PASTED_ROWS {
                truncated = true;
                break;
            }
            within_width(&record)?;
            let line = record
                .position()
                .map_or(1, |position| usize::try_from(position.line()).unwrap_or(usize::MAX));
            let fields = record
                .iter()
                .map(|field| (field != TSV_NULL).then(|| PastedField::plain(field)))
                .collect();
            records.push(PastedRecord { line, fields });
        }
        Ok(Self {
            header: Header::Unknown,
            records,
            truncated,
        })
    }

    /// The cells a grid copy wrote with `CellsEncoder`, each value and
    /// NULL as it was.
    pub fn from_cells(json: &[u8]) -> Result<Self, ImportError> {
        let cells: CopiedCells = serde_json::from_slice(json).map_err(|error| ImportError::Malformed {
            line: u64::try_from(error.line()).ok(),
        })?;
        let first = 1 + usize::from(cells.headers.is_some());
        let records = cells
            .rows
            .rows
            .into_iter()
            .enumerate()
            .map(|(index, fields)| PastedRecord {
                line: first + index,
                fields,
            })
            .collect();
        Ok(Self {
            header: match cells.headers {
                Some(headers) => Header::Named(headers),
                None => Header::Unnamed(cells.columns),
            },
            records,
            truncated: cells.rows.truncated,
        })
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// Whether the rows are more than a paste takes into a table of
    /// `width` columns: more lines than it reads, which were left unread,
    /// or more cells than the new rows may hold.
    pub fn too_large_for(&self, width: usize) -> bool {
        self.truncated || self.records.len().saturating_mul(width) > MAX_PASTED_CELLS
    }

    /// The one value the clipboard holds, when it holds one and nothing
    /// else: `Some(None)` is a NULL.
    pub fn single_value(&self) -> Option<Option<&str>> {
        match self.records.as_slice() {
            [record] => match record.fields.as_slice() {
                [field] => Some(field.as_ref().map(|field| field.text.as_str())),
                _ => None,
            },
            _ => None,
        }
    }

    /// The new rows the cells make in a table of `columns`. The fields
    /// of a record go to the columns `in_order` lists, the first field to
    /// the first, or by name under a header. Cells a grid copied go to
    /// the columns they came from when the table has each of them, so a
    /// copy between tables alike lands whatever order either grid shows.
    ///
    /// Each value is read as a cell edit of a new row reads it, and a
    /// NULL is NULL. A column left out holds what a new row holds. A
    /// column the server fills, and one whose values the grid cannot
    /// edit, keep that too, and a value meant for one counts as skipped.
    /// A key the server cannot fill takes the value: the row cannot be
    /// saved without it.
    pub fn rows(&self, columns: &[ColumnInfo], in_order: &[usize]) -> Result<PastedRows, CsvRowError> {
        let (placement, records) = match &self.header {
            Header::Named(names) => (Placement::Named(named_columns(columns, names)), self.records.as_slice()),
            Header::Unnamed(names) => match every_column_named(columns, names) {
                Some(named) => (Placement::Named(named), self.records.as_slice()),
                None => (Placement::InOrder(in_order), self.records.as_slice()),
            },
            Header::Unknown => match self.first_line_names(columns) {
                Some(named) => (Placement::Named(named), self.records.get(1..).unwrap_or_default()),
                None => (Placement::InOrder(in_order), self.records.as_slice()),
            },
        };
        let mut pasted = PastedRows::default();
        for record in records {
            let mut cells: Vec<CellInput> = columns.iter().map(new_draft_cell).collect();
            for (field, value) in record.fields.iter().enumerate() {
                let text = value.as_ref().map(|value| value.text.as_str());
                let target = match &placement {
                    Placement::InOrder(in_order) => in_order.get(field).copied(),
                    Placement::Named(named) => named.get(field).copied().flatten(),
                };
                let (Some(index), Some(column)) = (target, target.and_then(|index| columns.get(index))) else {
                    pasted.skipped += usize::from(carries_value(text));
                    continue;
                };
                if left_to_the_row(column) {
                    pasted.skipped += usize::from(carries_value(text));
                    continue;
                }
                cells[index] = pasted_cell(value.as_ref(), column).map_err(|reason| CsvRowError {
                    line: record.line,
                    column: column.name.clone(),
                    text: text.unwrap_or(TSV_NULL).to_owned(),
                    reason,
                })?;
            }
            pasted.rows.push(cells);
        }
        Ok(pasted)
    }

    /// The column each field of the first record names, when that
    /// record is a header: a row follows it, and more than half its
    /// fields name a column, no two the same.
    fn first_line_names(&self, columns: &[ColumnInfo]) -> Option<Vec<Option<usize>>> {
        let [first, _, ..] = self.records.as_slice() else {
            return None;
        };
        let names: Vec<&str> = first
            .fields
            .iter()
            .map(|field| field.as_ref().map_or("", |field| field.text.as_str()))
            .collect();
        let named = named_columns(columns, &names);
        let matched = named.iter().flatten().count();
        (matched * 2 > names.len()).then_some(named)
    }
}

/// The column each name names, when every one names a column of its own.
fn every_column_named(columns: &[ColumnInfo], names: &[String]) -> Option<Vec<Option<usize>>> {
    let named = named_columns(columns, names);
    (!named.is_empty() && named.iter().all(Option::is_some)).then_some(named)
}

/// The column each name names, each column taken once.
fn named_columns(columns: &[ColumnInfo], names: &[impl AsRef<str>]) -> Vec<Option<usize>> {
    let mut taken = vec![false; columns.len()];
    names
        .iter()
        .map(|name| {
            let index = column_named(columns, name.as_ref())?;
            let seen = taken.get_mut(index)?;
            (!std::mem::replace(seen, true)).then_some(index)
        })
        .collect()
}

/// The column a header field names: its exact name first, so a name
/// with spaces or capitals of its own finds its column, then the name in
/// any case with the field's surrounding space ignored, as the import's
/// mapping matches.
fn column_named(columns: &[ColumnInfo], field: &str) -> Option<usize> {
    if let Some(exact) = columns.iter().position(|column| column.name == field) {
        return Some(exact);
    }
    let wanted = field.trim().to_lowercase();
    if wanted.is_empty() {
        return None;
    }
    columns
        .iter()
        .position(|column| column.name.trim().to_lowercase() == wanted)
}

/// A column a pasted row leaves as a new row has it: the server fills
/// it, or the grid has no text form to edit its values in.
fn left_to_the_row(column: &ColumnInfo) -> bool {
    column.is_generated
        || column.is_auto_increment
        || (column.primary_key && !column.default.is_none())
        || read_only_reason(&column.column_type.kind).is_some()
}

/// A column of no type the app knows whose values are read as the
/// engine stored them, such as SQLite's untyped columns, which keep each
/// value as it comes. A type only the server knows, such as PostgreSQL's
/// `tsvector`, is read and written as its text.
fn stores_as_given(column: &ColumnInfo) -> bool {
    let column_type = &column.column_type;
    matches!(column_type.kind, ColumnKind::Other)
        && column_type.read_form == ReadForm::Native
        && column_type.dynamic_storage
}

/// Whether leaving the field out loses anything.
fn carries_value(text: Option<&str>) -> bool {
    text.is_some_and(|text| !text.is_empty())
}

fn pasted_cell(field: Option<&PastedField>, column: &ColumnInfo) -> Result<CellInput, EditParseError> {
    if let Some(field) = field {
        if stores_as_given(column)
            && let Some(value) = field.stored_value()
        {
            return Ok(CellInput::Value(value));
        }
        return parse_edit_text(&field.text, column, EditContext::InsertDraft);
    }
    if column.nullable {
        return Ok(CellInput::Value(Value::Null));
    }
    // A NOT NULL column with a default is better served by it than by
    // an insert the server refuses.
    match column.default.is_none() {
        true => Err(EditParseError::Required),
        false => Ok(CellInput::Default),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::{
        ColumnDefault, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm, SqlExpression, TextLength,
    };
    use crate::export::{CellsEncoder, RowEncoder, render_tsv};

    fn column(name: &str, kind: ColumnKind) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType {
                name: "t".to_owned(),
                kind,
                catalog: None,
                dynamic_storage: false,
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

    fn int(name: &str) -> ColumnInfo {
        column(
            name,
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W32,
                signed: true,
            }),
        )
    }

    fn text(name: &str) -> ColumnInfo {
        column(
            name,
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
        )
    }

    fn key(name: &str) -> ColumnInfo {
        let mut key = int(name);
        key.primary_key = true;
        key.nullable = false;
        key
    }

    fn serial(name: &str) -> ColumnInfo {
        let mut serial = key(name);
        serial.is_auto_increment = true;
        serial
    }

    fn value(text: &str) -> CellInput {
        CellInput::Value(Value::Text(text.to_owned()))
    }

    fn number(number: i64) -> CellInput {
        CellInput::Value(Value::Int(number))
    }

    fn null() -> CellInput {
        CellInput::Value(Value::Null)
    }

    /// The columns from `start` on, left to right.
    fn from(start: usize, columns: &[ColumnInfo]) -> Vec<usize> {
        (start..columns.len()).collect()
    }

    fn pasted(text: &str, columns: &[ColumnInfo], start: usize) -> PastedRows {
        PastedTable::read(text)
            .expect("read")
            .rows(columns, &from(start, columns))
            .expect("rows")
    }

    #[test]
    fn rows_the_copy_writes_paste_back_as_the_same_values() {
        let columns = [text("name"), text("note"), int("age")];
        let result: Vec<_> = columns.iter().map(ColumnInfo::result_column).collect();
        let copied = render_tsv(
            &result,
            &[
                vec![
                    Value::Text("tab\there".into()),
                    Value::Text("two\nlines".into()),
                    Value::Int(7),
                ],
                vec![
                    Value::Text("say \"hi\"".into()),
                    Value::Text(String::new()),
                    Value::Null,
                ],
            ],
            false,
        )
        .expect("the copy");

        let rows = pasted(&copied, &columns, 0);

        assert_eq!(
            rows.rows,
            vec![
                vec![value("tab\there"), value("two\nlines"), number(7)],
                vec![value("say \"hi\""), value(""), null()],
            ]
        );
        assert_eq!(rows.skipped, 0);
    }

    #[test]
    fn values_fill_the_columns_from_the_start_column_on() {
        let columns = [key("id"), text("name"), text("city")];

        let rows = pasted("Ada\tLondon\n", &columns, 1);

        assert_eq!(rows.rows, vec![vec![null(), value("Ada"), value("London")]]);
    }

    #[test]
    fn values_follow_the_columns_in_the_order_given() {
        let columns = [key("id"), text("name"), text("city")];

        let rows = PastedTable::read("London\tAda\n")
            .expect("read")
            .rows(&columns, &[2, 1])
            .expect("rows");

        assert_eq!(rows.rows, vec![vec![null(), value("Ada"), value("London")]]);
    }

    #[test]
    fn values_past_the_last_column_are_counted_as_skipped() {
        let columns = [text("name"), text("city")];

        let rows = pasted("Ada\tLondon\textra\t\nGrace\tNew York\n", &columns, 1);

        assert_eq!(rows.rows[0], vec![null(), value("Ada")]);
        assert_eq!(rows.skipped, 3, "London, extra and New York had no column");
    }

    #[test]
    fn a_header_maps_the_values_by_name() {
        let columns = [key("id"), text("name"), text("city")];

        let rows = pasted("City\tname\tshoe size\nLondon\tAda\t38\n", &columns, 2);

        assert_eq!(rows.rows, vec![vec![null(), value("Ada"), value("London")]]);
        assert_eq!(rows.skipped, 1, "the shoe size has no column");
    }

    #[test]
    fn a_first_line_naming_too_few_columns_is_data() {
        let columns = [text("name"), text("city")];

        let rows = pasted("name\tParis\tFrance\nAda\tLondon\tUK\n", &columns, 0);

        assert_eq!(rows.rows.len(), 2);
        assert_eq!(rows.rows[0], vec![value("name"), value("Paris")]);
    }

    #[test]
    fn a_lone_line_naming_the_columns_is_a_row() {
        let columns = [text("name"), text("city")];

        let rows = pasted("name\tcity\n", &columns, 0);

        assert_eq!(rows.rows, vec![vec![value("name"), value("city")]]);
    }

    #[test]
    fn a_column_the_server_fills_keeps_its_default_and_counts_the_value() {
        let mut stamped = text("created");
        stamped.is_generated = true;
        let columns = [serial("id"), text("name"), stamped];

        let rows = pasted("41\tAda\t2024-01-01\n42\tGrace\t\n", &columns, 0);

        assert_eq!(rows.rows[0], vec![CellInput::Default, value("Ada"), CellInput::Default]);
        assert_eq!(rows.skipped, 3, "an empty field loses nothing");
    }

    #[test]
    fn a_key_takes_the_value_unless_the_server_fills_it() {
        let mut generated_uuid = column("id", ColumnKind::Uuid);
        generated_uuid.primary_key = true;
        generated_uuid.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("gen_random_uuid()"));

        let natural = pasted("33\tFrance\n", &[key("code"), text("name")], 0);
        let filled = pasted(
            "8a5f2c4e-0000-4000-8000-000000000000\tFrance\n",
            &[generated_uuid, text("name")],
            0,
        );

        assert_eq!(natural.rows, vec![vec![number(33), value("France")]]);
        assert_eq!(filled.rows[0][0], CellInput::Default);
        assert_eq!(filled.skipped, 1);
    }

    #[test]
    fn a_bad_value_names_its_line_its_column_and_why() {
        let columns = [text("name"), int("age")];

        let error = PastedTable::read("Ada\t36\n\"Grace\nHopper\"\t\nLinus\tforty\n")
            .expect("read")
            .rows(&columns, &from(0, &columns))
            .expect_err("forty is no number");

        assert_eq!(
            error,
            CsvRowError {
                line: 4,
                column: "age".to_owned(),
                text: "forty".to_owned(),
                reason: EditParseError::InvalidInteger,
            }
        );
    }

    #[test]
    fn null_is_null_and_an_empty_field_is_read_as_an_empty_cell() {
        let mut level = int("level");
        level.nullable = false;
        level.default = ColumnDefault::Literal(Value::Int(1));
        let mut rank = int("rank");
        rank.nullable = false;
        let columns = [text("name"), int("age"), level, rank];

        let rows = pasted("NULL\t\tNULL\t3\n", &columns, 0);
        let refused = PastedTable::read("Ada\t1\t1\tNULL\n")
            .expect("read")
            .rows(&columns, &from(0, &columns))
            .expect_err("rank needs a value");

        assert_eq!(rows.rows[0], vec![null(), null(), CellInput::Default, number(3)]);
        assert_eq!(refused.reason, EditParseError::Required);
    }

    #[test]
    fn a_column_the_grid_cannot_edit_is_left_alone() {
        let blob = column(
            "data",
            ColumnKind::Bytes {
                length: TextLength::Unbounded,
            },
        );

        let rows = pasted("Ada\t0x01ff\n", &[text("name"), blob], 0);

        assert_eq!(rows.rows[0], vec![value("Ada"), null()]);
        assert_eq!(rows.skipped, 1);
    }

    #[test]
    fn windows_line_breaks_and_blank_lines_make_no_rows_of_their_own() {
        let rows = pasted("Ada\r\n\r\nGrace\r\n", &[text("name")], 0);

        assert_eq!(rows.rows, vec![vec![value("Ada")], vec![value("Grace")]]);
    }

    #[test]
    fn one_value_alone_is_a_single_value() {
        let one = PastedTable::read("Ada\n").expect("read");
        let quoted = PastedTable::read("\"two\nlines\"").expect("read");
        let row = PastedTable::read("Ada\tLondon\n").expect("read");
        let lines = PastedTable::read("Ada\nGrace\n").expect("read");

        assert_eq!(one.single_value(), Some(Some("Ada")));
        assert_eq!(quoted.single_value(), Some(Some("two\nlines")));
        assert_eq!(PastedTable::read("NULL").expect("read").single_value(), Some(None));
        assert_eq!(row.single_value(), None);
        assert_eq!(lines.single_value(), None);
    }

    #[test]
    fn empty_text_holds_no_rows() {
        assert!(PastedTable::read("").expect("read").is_empty());
        assert!(PastedTable::read("\n\n").expect("read").is_empty());
    }

    fn copied_cells(columns: &[ColumnInfo], rows: &[Vec<Value>], with_headers: bool) -> Vec<u8> {
        let result: Vec<_> = columns.iter().map(ColumnInfo::result_column).collect();
        let mut encoder = CellsEncoder::new(result.into(), with_headers);
        let mut out = Vec::new();
        encoder.begin(&mut out);
        for row in rows {
            encoder.row(&mut out, &mut row.iter()).expect("a row");
        }
        encoder.finish(&mut out);
        out
    }

    #[test]
    fn copied_cells_keep_every_value_and_null_as_it_was() {
        let columns = [text("name"), text("note"), int("age")];
        let copied = copied_cells(
            &columns,
            &[
                vec![
                    Value::Text("NULL".into()),
                    Value::Text("\"quoted\"".into()),
                    Value::Null,
                ],
                vec![
                    Value::Text("two\nlines".into()),
                    Value::Text("tab\there".into()),
                    Value::Int(3),
                ],
            ],
            false,
        );

        let rows = PastedTable::from_cells(&copied)
            .expect("read")
            .rows(&columns, &from(0, &columns))
            .expect("rows");

        assert_eq!(
            rows.rows,
            vec![
                vec![value("NULL"), value("\"quoted\""), null()],
                vec![value("two\nlines"), value("tab\there"), number(3)],
            ]
        );
    }

    #[test]
    fn copied_cells_with_names_map_by_name_from_the_first_row() {
        let source = [text("city"), text("name")];
        let copied = copied_cells(
            &source,
            &[vec![Value::Text("London".into()), Value::Text("Ada".into())]],
            true,
        );

        let rows = PastedTable::from_cells(&copied)
            .expect("read")
            .rows(&[key("id"), text("name"), text("city")], &[2])
            .expect("rows");

        assert_eq!(rows.rows, vec![vec![null(), value("Ada"), value("London")]]);
    }

    #[test]
    fn copied_cells_without_names_never_take_a_row_for_a_header() {
        let columns = [text("name"), text("city")];
        let copied = copied_cells(
            &columns,
            &[
                vec![Value::Text("name".into()), Value::Text("city".into())],
                vec![Value::Text("Ada".into()), Value::Text("London".into())],
            ],
            false,
        );

        let rows = PastedTable::from_cells(&copied)
            .expect("read")
            .rows(&columns, &from(0, &columns))
            .expect("rows");

        assert_eq!(rows.rows.len(), 2, "the first row was read as a header");
    }

    #[test]
    fn a_name_with_spaces_of_its_own_finds_its_column() {
        let columns = [text("name"), text(" name")];
        let copied = copied_cells(&[text(" name")], &[vec![Value::Text("Ada".into())]], true);

        let rows = PastedTable::from_cells(&copied)
            .expect("read")
            .rows(&columns, &from(0, &columns))
            .expect("rows");

        assert_eq!(rows.rows, vec![vec![null(), value("Ada")]]);
    }

    #[test]
    fn copied_cells_go_to_the_columns_they_came_from() {
        let source = [text("name"), text("city")];
        let copied = copied_cells(
            &source,
            &[vec![Value::Text("Ada".into()), Value::Text("London".into())]],
            false,
        );

        let rows = PastedTable::from_cells(&copied)
            .expect("read")
            .rows(&[key("id"), text("city"), text("name")], &[0, 1, 2])
            .expect("rows");

        assert_eq!(rows.rows, vec![vec![null(), value("London"), value("Ada")]]);
    }

    #[test]
    fn copied_cells_from_columns_the_table_lacks_fill_the_columns_in_order() {
        let source = [text("person"), text("town")];
        let copied = copied_cells(
            &source,
            &[vec![Value::Text("Ada".into()), Value::Text("London".into())]],
            false,
        );

        let rows = PastedTable::from_cells(&copied)
            .expect("read")
            .rows(&[key("id"), text("name"), text("city")], &[1, 2])
            .expect("rows");

        assert_eq!(rows.rows, vec![vec![null(), value("Ada"), value("London")]]);
    }

    #[test]
    fn one_copied_cell_is_a_single_value() {
        let copied = copied_cells(&[text("name")], &[vec![Value::Text("\"Ada\"".into())]], false);
        let nothing = copied_cells(&[text("name")], &[vec![Value::Null]], false);

        assert_eq!(
            PastedTable::from_cells(&copied).expect("read").single_value(),
            Some(Some("\"Ada\""))
        );
        assert_eq!(
            PastedTable::from_cells(&nothing).expect("read").single_value(),
            Some(None)
        );
    }

    #[test]
    fn cells_that_are_not_a_copy_are_refused() {
        assert!(matches!(
            PastedTable::from_cells(b"{\"rows\": 3}"),
            Err(ImportError::Malformed { .. })
        ));
    }

    #[test]
    fn more_lines_than_a_paste_reads_are_left_unread() {
        let text = "x\n".repeat(MAX_PASTED_ROWS + 1);
        let at_the_limit = "x\n".repeat(MAX_PASTED_ROWS);
        let cells = format!(
            "{{\"headers\":null,\"rows\":[{}[\"x\"]]}}",
            "[\"x\"],".repeat(MAX_PASTED_ROWS)
        );

        let over = PastedTable::read(&text).expect("read");
        let copied = PastedTable::from_cells(cells.as_bytes()).expect("read");

        assert!(over.too_large_for(1));
        assert_eq!(over.records.len(), MAX_PASTED_ROWS);
        assert!(copied.too_large_for(1));
        assert_eq!(copied.records.len(), MAX_PASTED_ROWS);
        assert!(!PastedTable::read(&at_the_limit).expect("read").too_large_for(1));
    }

    #[test]
    fn a_short_paste_into_a_wide_table_counts_every_cell_it_makes() {
        let lines = PastedTable::read(&"x\n".repeat(1_000)).expect("read");

        assert!(!lines.too_large_for(MAX_PASTED_CELLS / 1_000));
        assert!(lines.too_large_for(MAX_PASTED_CELLS / 1_000 + 1));
    }

    #[test]
    fn an_untyped_column_keeps_how_the_copied_value_was_stored() {
        let mut untyped = column("v", ColumnKind::Other);
        untyped.column_type.dynamic_storage = true;
        let copied = copied_cells(
            std::slice::from_ref(&untyped),
            &[
                vec![Value::Int(42)],
                vec![Value::Text("42".into())],
                vec![Value::Float64(1.5)],
                vec![Value::Bytes(vec![1, 255])],
            ],
            false,
        );

        let rows = PastedTable::from_cells(&copied)
            .expect("read")
            .rows(std::slice::from_ref(&untyped), &[0])
            .expect("rows");
        let typed = PastedTable::from_cells(&copied).expect("read").rows(&[int("v")], &[0]);

        assert_eq!(rows.rows[0], vec![number(42)]);
        assert!(
            matches!(&rows.rows[1][0], CellInput::Value(Value::Other(other)) if other.text == "42"),
            "{:?}",
            rows.rows[1]
        );
        assert_eq!(rows.rows[2], vec![CellInput::Value(Value::Float64(1.5))]);
        assert_eq!(rows.rows[3], vec![CellInput::Value(Value::Bytes(vec![1, 255]))]);
        assert!(typed.is_err(), "an integer column took 1.5");
    }

    #[test]
    fn a_type_only_the_server_knows_takes_the_text() {
        let mut server_typed = column("v", ColumnKind::Other);
        server_typed.column_type.dynamic_storage = true;
        server_typed.column_type.read_form = ReadForm::ServerText;
        let mut untyped = server_typed.clone();
        untyped.column_type.read_form = ReadForm::Native;
        let copied = copied_cells(
            &[server_typed.clone()],
            &[
                vec![Value::Int(42)],
                vec![Value::Decimal("9007199254740993".parse().expect("a decimal"))],
                vec![Value::Float64(f64::NAN)],
            ],
            false,
        );

        let read = |column: &ColumnInfo| {
            PastedTable::from_cells(&copied)
                .expect("read")
                .rows(std::slice::from_ref(column), &[0])
                .expect("rows")
                .rows
        };

        for rows in [read(&server_typed), read(&untyped).split_off(1)] {
            for row in rows {
                assert!(matches!(&row[0], CellInput::Value(Value::Other(_))), "{row:?}");
            }
        }
        assert_eq!(read(&untyped)[0], vec![number(42)]);
    }

    #[test]
    fn copied_cells_wider_than_any_table_are_refused() {
        let wide = format!("{{\"headers\":null,\"rows\":[[{}null]]}}", "null,".repeat(MAX_FIELDS));

        assert!(matches!(
            PastedTable::from_cells(wide.as_bytes()),
            Err(ImportError::Malformed { .. })
        ));
    }

    #[test]
    fn a_line_wider_than_any_table_is_refused() {
        let wide = "x\t".repeat(super::super::MAX_FIELDS);

        assert!(matches!(
            PastedTable::read(&wide),
            Err(ImportError::TooManyFields { line: 1, .. })
        ));
    }
}
