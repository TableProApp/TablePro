use crate::column::ResultColumn;
use crate::value::Value;

use super::encoder::{EncodeError, TsvEncoder, encode_rows};

/// What a copy writes for a NULL, and what a paste reads back as one.
pub const TSV_NULL: &str = "NULL";

/// A tab, a line break or a quote inside a value would move the following
/// text into the next column or the next row, so such a value is quoted
/// and its own quotes doubled. That is what a spreadsheet puts on the
/// clipboard for a multi-line cell, and what Calc and Excel parse back on
/// paste.
pub fn tsv_writer_builder() -> csv::WriterBuilder {
    let mut builder = csv::WriterBuilder::new();
    builder
        .delimiter(b'\t')
        .terminator(csv::Terminator::Any(b'\n'))
        .quote_style(csv::QuoteStyle::Necessary);
    builder
}

pub fn render_tsv(columns: &[ResultColumn], rows: &[Vec<Value>], with_headers: bool) -> Result<String, EncodeError> {
    encode_rows(TsvEncoder::new(columns.into(), with_headers), rows)
}

#[cfg(test)]
mod tests {
    use super::super::test_columns::cols;
    use super::*;

    #[test]
    fn tsv_with_and_without_header() {
        let columns = cols(&["a", "b"]);
        let rows = vec![vec![Value::Int(1), Value::Null]];
        assert_eq!(render_tsv(&columns, &rows, true).unwrap(), "a\tb\n1\tNULL\n");
        assert_eq!(render_tsv(&columns, &rows, false).unwrap(), "1\tNULL\n");
    }

    #[test]
    fn tsv_quotes_values_that_would_break_the_grid() {
        let columns = cols(&["a", "b"]);
        let rows = vec![vec![Value::Text("line1\nline2".into()), Value::Text("has\ttab".into())]];
        assert_eq!(
            render_tsv(&columns, &rows, false).unwrap(),
            "\"line1\nline2\"\t\"has\ttab\"\n"
        );
    }

    #[test]
    fn tsv_doubles_quotes_inside_a_quoted_value() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("say \"hi\"".into())]];
        assert_eq!(render_tsv(&columns, &rows, false).unwrap(), "\"say \"\"hi\"\"\"\n");
    }

    #[test]
    fn tsv_keeps_text_that_starts_like_a_formula_as_it_is() {
        let columns = cols(&["=sum", "b", "c", "d", "e"]);
        let rows = vec![vec![
            Value::Text("-".into()),
            Value::Text("+1 555 0100".into()),
            Value::Text("@alice".into()),
            Value::Text("=1+1".into()),
            Value::Int(-5),
        ]];

        assert_eq!(
            render_tsv(&columns, &rows, true).unwrap(),
            "=sum\tb\tc\td\te\n-\t+1 555 0100\t@alice\t=1+1\t-5\n"
        );
    }

    #[test]
    fn tsv_leaves_ordinary_values_bare() {
        let columns = cols(&["a"]);
        let rows = vec![vec![Value::Text("plain, value".into())]];
        assert_eq!(render_tsv(&columns, &rows, false).unwrap(), "plain, value\n");
    }
}
