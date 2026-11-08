// The formats are the macOS command's (CLIRowWriter.swift), so a script reads the same text on every platform.

use std::collections::HashSet;
use std::fmt::Write as _;

use unicode_width::UnicodeWidthStr;

use super::escape::escape_cell;
use super::format::OutputFormat;
use super::table::{Cell, Table};

const NULL_MARKER: &str = "NULL";

static MISSING: Cell = Cell::Null;

pub(crate) fn render(tables: &[Table], format: OutputFormat) -> String {
    let printable: Vec<&Table> = tables.iter().filter(|table| !table.columns.is_empty()).collect();
    let mut text = String::new();
    match (printable.as_slice(), format) {
        ([], _) => {}
        ([table], _) => render_one(table, format, &mut text),
        // One document either way: several result sets nest as one array each.
        (many, OutputFormat::Json) => {
            text.push_str("[\n");
            for (index, table) in many.iter().enumerate() {
                json_array(table, "  ", index + 1 == many.len(), &mut text);
            }
            text.push_str("]\n");
        }
        (many, OutputFormat::Jsonl) => {
            for table in many {
                render_one(table, format, &mut text);
            }
        }
        (many, _) => {
            for (index, table) in many.iter().enumerate() {
                if index > 0 {
                    text.push('\n');
                }
                render_one(table, format, &mut text);
            }
        }
    }
    text
}

fn render_one(table: &Table, format: OutputFormat, text: &mut String) {
    match format {
        OutputFormat::Csv => delimited(table, ',', csv_field, text),
        OutputFormat::Tsv => delimited(table, '\t', tsv_field, text),
        OutputFormat::Json => json_array(table, "", true, text),
        OutputFormat::Jsonl => {
            let keys = unique_keys(&table.columns);
            for row in &table.rows {
                json_object(&keys, row, text);
                text.push('\n');
            }
        }
        OutputFormat::Table => grid(table, text),
    }
}

fn cells(row: &[Cell], count: usize) -> impl Iterator<Item = &Cell> {
    row.iter().chain(std::iter::repeat(&MISSING)).take(count)
}

fn delimited(table: &Table, separator: char, field: fn(Option<&str>, &mut String), text: &mut String) {
    for (index, column) in table.columns.iter().enumerate() {
        if index > 0 {
            text.push(separator);
        }
        field(Some(column), text);
    }
    text.push('\n');
    for row in &table.rows {
        for (index, cell) in cells(row, table.columns.len()).enumerate() {
            if index > 0 {
                text.push(separator);
            }
            field(cell.as_text(), text);
        }
        text.push('\n');
    }
}

// NULL is an empty field and an empty string is "", so the two stay apart.
fn csv_field(value: Option<&str>, text: &mut String) {
    let Some(value) = value else {
        return;
    };
    let quoted = value.is_empty()
        || value.chars().any(|character| {
            matches!(
                character,
                ',' | '"' | '\n' | '\u{b}' | '\u{c}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
            )
        });
    if !quoted {
        text.push_str(value);
        return;
    }
    text.push('"');
    text.push_str(&value.replace('"', "\"\""));
    text.push('"');
}

fn tsv_field(value: Option<&str>, text: &mut String) {
    let Some(value) = value else {
        return;
    };
    for character in value.chars() {
        match character {
            '\\' => text.push_str("\\\\"),
            '\t' => text.push_str("\\t"),
            '\n' => text.push_str("\\n"),
            '\r' => text.push_str("\\r"),
            other => text.push(other),
        }
    }
}

fn json_array(table: &Table, indent: &str, last: bool, text: &mut String) {
    let close = match last {
        true => "]\n",
        false => "],\n",
    };
    text.push_str(indent);
    if table.rows.is_empty() {
        text.push('[');
        text.push_str(close);
        return;
    }
    let keys = unique_keys(&table.columns);
    text.push_str("[\n");
    for (index, row) in table.rows.iter().enumerate() {
        text.push_str(indent);
        text.push_str("  ");
        json_object(&keys, row, text);
        text.push_str(match index + 1 == table.rows.len() {
            true => "\n",
            false => ",\n",
        });
    }
    text.push_str(indent);
    text.push_str(close);
}

fn json_object(keys: &[String], row: &[Cell], text: &mut String) {
    text.push('{');
    for (index, (key, cell)) in keys.iter().zip(cells(row, keys.len())).enumerate() {
        if index > 0 {
            text.push(',');
        }
        json_string(key, text);
        text.push(':');
        match cell {
            Cell::Null => text.push_str("null"),
            Cell::Text(value) => json_string(value, text),
            Cell::Json(value) => text.push_str(value),
        }
    }
    text.push('}');
}

fn json_string(value: &str, text: &mut String) {
    text.push('"');
    for character in value.chars() {
        match character {
            '"' => text.push_str("\\\""),
            '\\' => text.push_str("\\\\"),
            '\n' => text.push_str("\\n"),
            '\r' => text.push_str("\\r"),
            '\t' => text.push_str("\\t"),
            other if u32::from(other) < 0x20 => {
                let _ = write!(text, "\\u{:04x}", u32::from(other));
            }
            other => text.push(other),
        }
    }
    text.push('"');
}

// A join can name two columns alike, and an object keeps only one of two equal keys.
// The rule is the server's JSON export's (json_field_names), so a key reads the same in both.
fn unique_keys(columns: &[String]) -> Vec<String> {
    let mut reserved: HashSet<String> = columns.iter().cloned().collect();
    let mut taken: HashSet<String> = HashSet::with_capacity(columns.len());
    let mut keys = Vec::with_capacity(columns.len());
    for column in columns {
        let mut key = column.clone();
        if !taken.insert(key.clone()) {
            let mut suffix = 2;
            loop {
                let candidate = format!("{column}_{suffix}");
                if !reserved.contains(&candidate) && taken.insert(candidate.clone()) {
                    key = candidate;
                    break;
                }
                suffix += 1;
            }
            reserved.insert(key.clone());
        }
        keys.push(key);
    }
    keys
}

fn grid(table: &Table, text: &mut String) {
    let header: Vec<String> = table
        .columns
        .iter()
        .map(|column| escape_cell(column).into_owned())
        .collect();
    let body: Vec<Vec<String>> = table
        .rows
        .iter()
        .map(|row| {
            cells(row, header.len())
                .map(|cell| match cell.as_text() {
                    None => NULL_MARKER.to_owned(),
                    Some(value) => escape_cell(value).into_owned(),
                })
                .collect()
        })
        .collect();
    // Terminal cells, not characters: 日本語 takes six.
    let mut widths: Vec<usize> = header.iter().map(|cell| cell.width()).collect();
    for row in &body {
        for (width, cell) in widths.iter_mut().zip(row) {
            *width = (*width).max(cell.width());
        }
    }
    grid_line(&header, &widths, text);
    let rule: Vec<String> = widths.iter().map(|&width| "-".repeat(width)).collect();
    text.push_str(&rule.join("-+-"));
    text.push('\n');
    for row in &body {
        grid_line(row, &widths, text);
    }
}

fn grid_line(cells: &[String], widths: &[usize], text: &mut String) {
    for (index, (cell, &width)) in cells.iter().zip(widths).enumerate() {
        if index > 0 {
            text.push_str(" | ");
        }
        text.push_str(cell);
        if index + 1 < cells.len() {
            text.push_str(&" ".repeat(width.saturating_sub(cell.width())));
        }
    }
    text.push('\n');
}

#[cfg(test)]
mod tests {
    use super::*;

    fn people() -> Table {
        let mut table = Table::new(&["id", "name", "note"]);
        table.push(vec![Cell::literal(1), Cell::text("Ada"), Cell::Null]);
        table.push(vec![Cell::literal(2), Cell::text("Grace, \"Amazing\""), Cell::text("")]);
        table
    }

    #[test]
    fn csv_quotes_only_what_needs_it_and_keeps_null_apart_from_empty() {
        assert_eq!(
            render(&[people()], OutputFormat::Csv),
            "id,name,note\n1,Ada,\n2,\"Grace, \"\"Amazing\"\"\",\"\"\n"
        );
    }

    #[test]
    fn csv_quotes_every_line_break() {
        let mut table = Table::new(&["a"]);
        table.push(vec![Cell::text("x\ny")]);
        table.push(vec![Cell::text("x\u{2028}y")]);

        assert_eq!(render(&[table], OutputFormat::Csv), "a\n\"x\ny\"\n\"x\u{2028}y\"\n");
    }

    #[test]
    fn tsv_escapes_tabs_line_breaks_and_backslashes() {
        let mut table = Table::new(&["a", "b"]);
        table.push(vec![Cell::text("x\ty\nz\r\\"), Cell::Null]);

        assert_eq!(render(&[table], OutputFormat::Tsv), "a\tb\nx\\ty\\nz\\r\\\\\t\n");
    }

    #[test]
    fn json_is_one_array_of_objects_keeping_numbers_as_sent() {
        let mut table = Table::new(&["n", "s"]);
        table.push(vec![Cell::literal("18446744073709551615"), Cell::text("a\"\u{1}")]);
        table.push(vec![Cell::Null, Cell::text("b")]);

        assert_eq!(
            render(&[table], OutputFormat::Json),
            "[\n  {\"n\":18446744073709551615,\"s\":\"a\\\"\\u0001\"},\n  {\"n\":null,\"s\":\"b\"}\n]\n"
        );
    }

    #[test]
    fn json_with_no_rows_is_an_empty_array() {
        assert_eq!(render(&[Table::new(&["a"])], OutputFormat::Json), "[]\n");
    }

    #[test]
    fn several_result_sets_nest_in_json_and_stack_elsewhere() {
        let mut first = Table::new(&["a"]);
        first.push(vec![Cell::literal(1)]);
        let mut second = Table::new(&["b"]);
        second.push(vec![Cell::literal(2)]);
        let sets = [first, Table::new(&[]), second];

        assert_eq!(
            render(&sets, OutputFormat::Json),
            "[\n  [\n    {\"a\":1}\n  ],\n  [\n    {\"b\":2}\n  ]\n]\n"
        );
        assert_eq!(render(&sets, OutputFormat::Csv), "a\n1\n\nb\n2\n");
        assert_eq!(render(&sets, OutputFormat::Jsonl), "{\"a\":1}\n{\"b\":2}\n");
    }

    #[test]
    fn repeated_column_names_get_numbered_keys() {
        let columns: Vec<String> = ["id", "id", "id_2"].iter().map(|&name| name.to_owned()).collect();

        assert_eq!(unique_keys(&columns), vec!["id", "id_3", "id_2"]);
    }

    #[test]
    fn a_short_row_reads_as_null_and_a_long_one_is_cut() {
        let mut table = Table::new(&["a", "b"]);
        table.push(vec![Cell::literal(1)]);
        table.push(vec![Cell::literal(1), Cell::literal(2), Cell::literal(3)]);

        assert_eq!(
            render(&[table], OutputFormat::Jsonl),
            "{\"a\":1,\"b\":null}\n{\"a\":1,\"b\":2}\n"
        );
    }

    #[test]
    fn the_table_pads_columns_and_shows_null() {
        let mut table = Table::new(&["id", "name", "note"]);
        table.push(vec![Cell::literal(1), Cell::text("Ada"), Cell::Null]);
        table.push(vec![Cell::literal(2), Cell::text("Bo"), Cell::text("")]);

        let expected = [
            "id | name | note",
            "---+------+-----",
            "1  | Ada  | NULL",
            "2  | Bo   | ",
        ]
        .join("\n")
            + "\n";
        assert_eq!(render(&[table], OutputFormat::Table), expected);
    }

    #[test]
    fn the_table_lines_up_wide_characters_by_terminal_cells() {
        let mut table = Table::new(&["name", "id"]);
        table.push(vec![Cell::text("日本語"), Cell::literal(1)]);
        table.push(vec![Cell::text("abc"), Cell::literal(2)]);

        assert_eq!(
            render(&[table], OutputFormat::Table),
            "name   | id\n-------+---\n日本語 | 1\nabc    | 2\n"
        );
    }

    #[test]
    fn the_table_escapes_control_characters() {
        let mut table = Table::new(&["note"]);
        table.push(vec![Cell::text("\u{1b}[2Jgone")]);

        assert_eq!(
            render(&[table], OutputFormat::Table),
            "note\n-----------\n\\x1B[2Jgone\n"
        );
    }
}
