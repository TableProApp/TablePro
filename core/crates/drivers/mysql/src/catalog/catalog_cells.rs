use tablepro_core::DriverError;
use tablepro_core::value::Value;

/// A catalogue row, decoded once. information_schema hands some text
/// columns back as BLOB or VARBINARY depending on the server and its
/// version, so every cell is read for what it holds, not its type.
pub(crate) struct CatalogCells {
    table: &'static str,
    values: Vec<Value>,
}

impl CatalogCells {
    pub(crate) fn new(table: &'static str, values: Vec<Value>) -> Self {
        Self { table, values }
    }

    pub(crate) fn text(&self, index: usize) -> Result<Option<String>, DriverError> {
        match self.values.get(index) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::Text(text)) => Ok(Some(text.clone())),
            Some(Value::Bytes(bytes)) => String::from_utf8(bytes.clone())
                .map(Some)
                .map_err(|error| self.error(index, &error.to_string())),
            Some(Value::Other(other)) => Ok(Some(other.text.clone())),
            Some(other) => Ok(tablepro_core::export::value_to_text(other)),
        }
    }

    pub(crate) fn required_text(&self, index: usize) -> Result<String, DriverError> {
        self.text(index)?
            .ok_or_else(|| self.error(index, "a NULL where the catalogue always has a value"))
    }

    pub(crate) fn number(&self, index: usize) -> Result<Option<u64>, DriverError> {
        match self.values.get(index) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::Int(number)) => u64::try_from(*number)
                .map(Some)
                .map_err(|_| self.error(index, "a negative count")),
            Some(Value::UInt(number)) => Ok(Some(*number)),
            Some(Value::Decimal(decimal)) => Value::Decimal(decimal.clone())
                .as_exact_u64()
                .map(Some)
                .ok_or_else(|| self.error(index, "a fractional count")),
            Some(_) => match self.text(index)? {
                Some(text) => text
                    .trim()
                    .parse()
                    .map(Some)
                    .map_err(|_| self.error(index, &format!("{text:?} is not a count"))),
                None => Ok(None),
            },
        }
    }

    fn error(&self, index: usize, detail: &str) -> DriverError {
        DriverError::Decode {
            column: format!("{} column {index}", self.table),
            detail: detail.to_owned(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalogue_cells_read_text_from_any_string_form() {
        let cells = CatalogCells::new(
            "COLUMNS",
            vec![
                Value::Bytes(b"id".to_vec()),
                Value::Text("int".to_owned()),
                Value::UInt(10),
                Value::Text("11".to_owned()),
                Value::Null,
            ],
        );

        assert_eq!(cells.text(0).ok().flatten().as_deref(), Some("id"));
        assert_eq!(cells.required_text(1).ok().as_deref(), Some("int"));
        assert_eq!(cells.number(2).ok().flatten(), Some(10));
        assert_eq!(cells.number(3).ok().flatten(), Some(11));
        assert_eq!(cells.number(4).ok().flatten(), None);
        assert!(cells.required_text(4).is_err());
    }
}
