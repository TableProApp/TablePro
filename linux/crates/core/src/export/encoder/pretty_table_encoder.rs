use std::sync::Arc;

use unicode_width::UnicodeWidthStr;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::column_type;
use super::super::value_text::value_text;
use super::{EncodeError, RowEncoder, readable_cells};

/// A table drawn in text with borders, for a monospace place: a chat,
/// a ticket, a terminal. A column's width depends on every row, so the
/// rows are held and the whole table is written at the end.
pub struct PrettyTableEncoder {
    columns: Arc<[ResultColumn]>,
    rows: Vec<Vec<String>>,
}

impl PrettyTableEncoder {
    pub fn new(columns: Arc<[ResultColumn]>) -> Self {
        Self {
            columns,
            rows: Vec::new(),
        }
    }

    /// Numbers line up on their last digit, as a terminal client shows
    /// them.
    fn right_aligned(&self, index: usize) -> bool {
        column_type(&self.columns, index).kind.is_numeric()
    }
}

/// A line break or a tab would break the table's lines, so each is
/// written as its escape.
fn table_text(text: &str) -> String {
    text.replace("\r\n", "\\n")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}

impl RowEncoder for PrettyTableEncoder {
    fn begin(&mut self, _out: &mut Vec<u8>) {}

    fn row(&mut self, _out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?
            .into_iter()
            .enumerate()
            .map(|(index, value)| {
                table_text(&value_text(value, column_type(&self.columns, index)).unwrap_or_else(|| "NULL".to_owned()))
            })
            .collect();
        self.rows.push(cells);
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) {
        let header: Vec<String> = self.columns.iter().map(|column| table_text(&column.name)).collect();
        let count = self.rows.iter().map(Vec::len).fold(header.len(), usize::max);
        let mut widths = vec![0; count];
        for line in std::iter::once(&header).chain(&self.rows) {
            for (index, text) in line.iter().enumerate() {
                widths[index] = widths[index].max(text.width());
            }
        }
        let border = format!(
            "+{}+",
            widths
                .iter()
                .map(|width| "-".repeat(width + 2))
                .collect::<Vec<_>>()
                .join("+")
        );
        let line = |cells: &[String], align: &dyn Fn(usize) -> bool| {
            let padded: Vec<String> = widths
                .iter()
                .enumerate()
                .map(|(index, width)| {
                    let text = cells.get(index).map_or("", String::as_str);
                    let pad = " ".repeat(width - text.width());
                    match align(index) {
                        true => format!(" {pad}{text} "),
                        false => format!(" {text}{pad} "),
                    }
                })
                .collect();
            format!("|{}|", padded.join("|"))
        };
        let mut lines = vec![border.clone(), line(&header, &|_| false), border.clone()];
        lines.extend(
            self.rows
                .iter()
                .map(|row| line(row, &|index| self.right_aligned(index))),
        );
        if !self.rows.is_empty() {
            lines.push(border);
        }
        out.extend_from_slice(lines.join("\n").as_bytes());
        self.rows.clear();
    }
}
