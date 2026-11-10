use std::fmt::Display;

use serde_json::value::RawValue;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Cell {
    Null,
    Text(String),
    // A number, a boolean or a nested document as the server wrote it, so no digit is lost on the way.
    Json(String),
}

impl Cell {
    pub(crate) fn from_raw(raw: &RawValue) -> Self {
        let text = raw.get().trim();
        match text.as_bytes().first() {
            Some(b'n') => Self::Null,
            Some(b'"') => serde_json::from_str(text).map_or_else(|_| Self::Json(text.to_owned()), Self::Text),
            _ => Self::Json(text.to_owned()),
        }
    }

    pub(crate) fn text(value: impl Into<String>) -> Self {
        Self::Text(value.into())
    }

    pub(crate) fn optional(value: Option<String>) -> Self {
        value.map_or(Self::Null, Self::Text)
    }

    pub(crate) fn literal(value: impl Display) -> Self {
        Self::Json(value.to_string())
    }

    pub(crate) fn as_text(&self) -> Option<&str> {
        match self {
            Self::Null => None,
            Self::Text(text) | Self::Json(text) => Some(text),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Table {
    pub(crate) columns: Vec<String>,
    pub(crate) rows: Vec<Vec<Cell>>,
}

impl Table {
    pub(crate) fn new(columns: &[&str]) -> Self {
        Self {
            columns: columns.iter().map(|&column| column.to_owned()).collect(),
            rows: Vec::new(),
        }
    }

    pub(crate) fn push(&mut self, row: Vec<Cell>) {
        self.rows.push(row);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell(json: &str) -> Cell {
        let raw: Box<RawValue> = serde_json::from_str(json).expect("JSON");
        Cell::from_raw(&raw)
    }

    #[test]
    fn a_value_keeps_the_text_the_server_sent() {
        assert_eq!(cell("null"), Cell::Null);
        assert_eq!(cell(r#""a \"b\"""#), Cell::text("a \"b\""));
        assert_eq!(cell("18446744073709551615"), Cell::literal("18446744073709551615"));
        assert_eq!(
            cell("12345678901234567890.12345678901234567890"),
            Cell::literal("12345678901234567890.12345678901234567890")
        );
        assert_eq!(cell("true"), Cell::literal(true));
        assert_eq!(cell(r#"{"k":[1,2]}"#), Cell::literal(r#"{"k":[1,2]}"#));
    }
}
