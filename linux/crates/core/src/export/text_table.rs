use std::fmt::Write;

use comfy_table::{Cell, CellAlignment, Table};
use thiserror::Error;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::column::ResultColumn;
use crate::value::Value;

use super::column_type;
use super::encoder::{EncodeError, readable_cells};
use super::value_text::value_text;

/// The borders psql draws with `\pset border 2`. ASCII, since box drawing
/// characters are East Asian Ambiguous and some fonts draw them two
/// columns wide.
const BORDERS: &str = "||--+-++|    ++++++";

/// Every row is padded to each column's widest cell, so one long value
/// is repeated as spaces down the whole column, and comfy-table holds
/// each cell as strings of its own while it lays them out. A table past
/// this size is refused rather than built.
const MAX_TABLE_BYTES: usize = 64 * 1024 * 1024;

/// What comfy-table holds per cell beside its text.
const CELL_BYTES: usize = 256;

/// comfy-table keeps a column's width with its padding in a `u16`, and
/// wraps a longer line.
const MAX_COLUMN_WIDTH: usize = u16::MAX as usize - 2;

/// A tab moves to the next multiple of this, as a terminal draws it.
const TAB_STOP: usize = 8;

#[derive(Debug, Error)]
pub enum TextTableError {
    #[error(transparent)]
    Encode(#[from] EncodeError),
    #[error("the table would be too large to hold as text")]
    TooLarge,
}

/// A table drawn in text with borders, for a monospace place: a chat, a
/// ticket, a terminal. A line break in a value continues the cell on the
/// next line, numbers line up on their last digit and NULL reads `NULL`.
pub fn render_text_table<'a, R>(columns: &[ResultColumn], rows: R) -> Result<String, TextTableError>
where
    R: IntoIterator,
    R::Item: IntoIterator<Item = &'a Value>,
{
    let header: Vec<String> = columns.iter().map(|column| drawn_text(&column.name)).collect();
    let mut widths: Vec<usize> = header.iter().map(|text| drawn_width(text)).collect();
    let mut bytes: Vec<usize> = header.iter().map(|text| line_bytes(text)).collect();
    let mut lines = line_count(&header);
    let mut cell_count = header.len();
    let mut numbers = vec![NumberColumn::default(); columns.len()];
    let mut body = Vec::new();
    for row in rows {
        let cells = readable_cells(columns, &mut row.into_iter())?;
        let texts: Vec<String> = cells
            .iter()
            .enumerate()
            .map(|(index, value)| {
                let column = column_type(columns, index);
                if let Some(number) = numbers.get_mut(index) {
                    number.take(value);
                }
                value_text(value, column).map_or_else(|| "NULL".to_owned(), |text| drawn_text(&text))
            })
            .collect();
        if widths.len() < texts.len() {
            widths.resize(texts.len(), 0);
            bytes.resize(texts.len(), 0);
        }
        for ((width, most), text) in widths.iter_mut().zip(bytes.iter_mut()).zip(&texts) {
            *width = (*width).max(drawn_width(text));
            *most = (*most).max(line_bytes(text));
        }
        lines += line_count(&texts);
        cell_count += texts.len();
        body.push(texts);
    }
    // A line holds each column's widest text, a space either side and a
    // border, and the table four border lines.
    let line_size = bytes.iter().map(|most| most + 3).sum::<usize>() + 2;
    let size = (lines + 4)
        .saturating_mul(line_size)
        .saturating_add(cell_count.saturating_mul(CELL_BYTES));
    if widths.iter().any(|width| *width > MAX_COLUMN_WIDTH) || size > MAX_TABLE_BYTES {
        return Err(TextTableError::TooLarge);
    }

    let mut table = Table::new();
    // comfy-table otherwise asks whether stdout is a terminal for every
    // line it draws, and this text never goes there.
    table.force_no_tty();
    table.load_preset(BORDERS);
    table.set_header(
        header
            .into_iter()
            .map(|name| Cell::new(name).set_alignment(CellAlignment::Left)),
    );
    table.add_rows(body);
    for (index, number) in numbers.iter().enumerate() {
        let column = column_type(columns, index);
        let right = column.kind.is_numeric() || (column.kind.is_untyped() && number.only_numbers());
        if let (true, Some(column)) = (right, table.column_mut(index)) {
            column.set_cell_alignment(CellAlignment::Right);
        }
    }
    let mut out = String::with_capacity(lines.saturating_mul(line_size));
    for line in table.lines() {
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&line);
    }
    Ok(out)
}

/// Whether a column of no declared type held only numbers, as the grid
/// decides it before it lines them up.
#[derive(Debug, Clone, Copy)]
struct NumberColumn {
    held: bool,
    all: bool,
}

impl Default for NumberColumn {
    fn default() -> Self {
        Self { held: false, all: true }
    }
}

impl NumberColumn {
    fn take(&mut self, value: &Value) {
        if !value.is_null() {
            self.held = true;
            self.all &= value.is_number();
        }
    }

    fn only_numbers(self) -> bool {
        self.held && self.all
    }
}

/// The text a cell draws. A line break starts the cell's next line and a
/// tab moves to the next stop. Any other control character, the Unicode
/// line and paragraph separators and the bidi controls are written as
/// escapes: a terminal or a chat would act on them, break the row there or
/// reorder the cells after them, and the width the table counts would not
/// be the width drawn.
fn drawn_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut column = 0;
    let mut chars = text.chars().peekable();
    while let Some(character) = chars.next() {
        match character {
            '\r' if chars.peek() == Some(&'\n') => {}
            '\n' | '\r' => {
                out.push('\n');
                column = 0;
            }
            '\t' => {
                let stop = (column / TAB_STOP + 1) * TAB_STOP;
                out.extend(std::iter::repeat_n(' ', stop - column));
                column = stop;
            }
            '\u{2028}'
            | '\u{2029}'
            | '\u{061c}'
            | '\u{200e}'
            | '\u{200f}'
            | '\u{202a}'..='\u{202e}'
            | '\u{2066}'..='\u{2069}' => {
                let _ = write!(out, "\\u{:04x}", u32::from(character));
                column += 6;
            }
            control if control.is_control() => {
                let _ = write!(out, "\\x{:02x}", u32::from(control));
                column += 4;
            }
            other => {
                out.push(other);
                column += other.width().unwrap_or(0);
            }
        }
    }
    out
}

/// The columns the widest line of a cell takes.
fn drawn_width(text: &str) -> usize {
    text.split('\n').map(UnicodeWidthStr::width).max().unwrap_or(0)
}

/// The bytes the longest line of a cell takes, never fewer than the
/// columns it draws.
fn line_bytes(text: &str) -> usize {
    text.split('\n').map(str::len).max().unwrap_or(0)
}

/// The lines the tallest cell of a row takes.
fn line_count(texts: &[String]) -> usize {
    texts.iter().map(|text| text.split('\n').count()).max().unwrap_or(1)
}

#[cfg(test)]
mod tests {
    use super::super::test_columns::{cols, typed};
    use super::*;
    use crate::column::{ColumnKind, ColumnType, IntegerKind, IntegerWidth};
    use crate::value::{UndecodableReason, UndecodedValue};

    fn table(columns: &[ResultColumn], rows: &[Vec<Value>]) -> String {
        render_text_table(columns, rows).expect("the table")
    }

    fn id_column() -> ResultColumn {
        typed(
            "id",
            "bigint",
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W64,
                signed: true,
            }),
        )
    }

    #[test]
    fn text_table_draws_borders_and_lines_up_numbers_on_the_right() {
        let columns = vec![id_column(), cols(&["name"]).remove(0)];
        let rows = vec![
            vec![Value::Int(1), Value::Text("Ada Lovelace".into())],
            vec![Value::Int(200), Value::Null],
        ];

        assert_eq!(
            table(&columns, &rows),
            "+-----+--------------+\n\
             | id  | name         |\n\
             +-----+--------------+\n\
             |   1 | Ada Lovelace |\n\
             | 200 | NULL         |\n\
             +-----+--------------+"
        );
    }

    #[test]
    fn text_table_lines_up_an_untyped_column_of_numbers_as_the_grid_does() {
        let columns = vec![
            ResultColumn::new("total", ColumnType::untyped_text("text")),
            ResultColumn::new("code", ColumnType::untyped_text("text")),
        ];
        let rows = vec![
            vec![Value::Text("10.5".into()), Value::Text("7".into())],
            vec![Value::Null, Value::Text("A7".into())],
            vec![Value::Text("3".into()), Value::Text("12".into())],
        ];

        assert_eq!(
            table(&columns, &rows),
            "+-------+------+\n\
             | total | code |\n\
             +-------+------+\n\
             |  10.5 | 7    |\n\
             |  NULL | A7   |\n\
             |     3 | 12   |\n\
             +-------+------+"
        );
    }

    #[test]
    fn text_table_continues_a_line_break_on_the_next_line_and_measures_wide_characters() {
        let rows = vec![
            vec![Value::Text("two\r\nlines".into())],
            vec![Value::Text("日本".into())],
        ];

        assert_eq!(
            table(&cols(&["a"]), &rows),
            "+-------+\n\
             | a     |\n\
             +-------+\n\
             | two   |\n\
             | lines |\n\
             | 日本  |\n\
             +-------+"
        );
    }

    #[test]
    fn text_table_expands_tabs_and_escapes_other_control_and_bidi_characters() {
        let rows = vec![
            vec![Value::Text("a\tb\u{1b}[31m\u{2028}".into())],
            vec![Value::Text("Bob\u{202e}\u{2066}".into())],
        ];

        assert_eq!(
            table(&cols(&["a"]), &rows),
            "+-------------------------+\n\
             | a                       |\n\
             +-------------------------+\n\
             | a       b\\x1b[31m\\u2028 |\n\
             | Bob\\u202e\\u2066         |\n\
             +-------------------------+"
        );
    }

    #[test]
    fn text_table_of_no_rows_closes_under_its_header_as_psql_draws_it() {
        assert_eq!(table(&cols(&["id"]), &[]), "+----+\n| id |\n+----+\n+----+");
    }

    #[test]
    fn text_table_refuses_a_long_value_repeated_as_padding_down_its_column() {
        let long = Value::Text("x".repeat(60_000));
        let rows: Vec<Vec<Value>> = std::iter::once(vec![long])
            .chain((0..1_200).map(|_| vec![Value::Int(1)]))
            .collect();

        let refused = render_text_table(&cols(&["a"]), &rows);

        assert!(matches!(refused, Err(TextTableError::TooLarge)), "{refused:?}");
    }

    #[test]
    fn text_table_refuses_an_undecodable_cell() {
        let rows = vec![vec![Value::Undecodable(Box::new(UndecodedValue {
            type_name: "geometry".to_owned(),
            reason: UndecodableReason::UnsupportedType,
        }))]];

        let refused = render_text_table(&cols(&["a"]), &rows);

        assert!(
            matches!(refused, Err(TextTableError::Encode(EncodeError::Undecodable { .. }))),
            "{refused:?}"
        );
    }
}
