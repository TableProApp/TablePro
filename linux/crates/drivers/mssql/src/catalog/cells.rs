use tablepro_core::DriverError;
use tablepro_core::value::Value;

/// One decoded row of a catalogue query, read by position.
///
/// The catalogue's bit and small integer columns arrive as whatever
/// TDS type the projection produced, so each reader accepts every form
/// the value can take instead of one exact type.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Cells<'a> {
    values: &'a [Value],
    query: &'static str,
}

impl<'a> Cells<'a> {
    pub(crate) fn new(values: &'a [Value], query: &'static str) -> Self {
        Self { values, query }
    }

    pub(crate) fn text(&self, index: usize) -> Option<String> {
        match self.values.get(index) {
            Some(Value::Text(text)) => Some(text.clone()),
            _ => None,
        }
    }

    /// A text column the query never returns NULL for.
    pub(crate) fn required_text(&self, index: usize) -> Result<String, DriverError> {
        self.text(index).ok_or_else(|| self.missing(index))
    }

    pub(crate) fn int(&self, index: usize) -> Option<i64> {
        match self.values.get(index) {
            Some(Value::Int(integer)) => Some(*integer),
            Some(Value::UInt(integer)) => i64::try_from(*integer).ok(),
            Some(Value::Bool(flag)) => Some(i64::from(*flag)),
            Some(Value::Decimal(decimal)) => match decimal.to_scaled_i128() {
                Some((mantissa, 0)) => i64::try_from(mantissa).ok(),
                _ => None,
            },
            _ => None,
        }
    }

    pub(crate) fn flag(&self, index: usize) -> bool {
        self.int(index).is_some_and(|integer| integer != 0)
    }

    fn missing(&self, index: usize) -> DriverError {
        DriverError::Decode {
            column: format!("{} column {index}", self.query),
            detail: format!("expected text, read {:?}", self.values.get(index)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readers_accept_every_form_a_catalogue_value_takes() {
        let values = [
            Value::Bool(true),
            Value::Int(0),
            Value::Decimal("42".parse().unwrap()),
            Value::Text("dbo".to_owned()),
            Value::Null,
        ];
        let cells = Cells::new(&values, "test");

        assert!(cells.flag(0));
        assert!(!cells.flag(1));
        assert_eq!(cells.int(2), Some(42));
        assert_eq!(cells.text(3).as_deref(), Some("dbo"));
        assert_eq!(cells.text(4), None);
        assert!(!cells.flag(4));
        assert!(matches!(cells.required_text(4), Err(DriverError::Decode { .. })));
        assert_eq!(cells.int(9), None);
    }
}
