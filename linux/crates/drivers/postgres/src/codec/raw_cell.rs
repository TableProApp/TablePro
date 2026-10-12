use std::error::Error;

use postgres_types::{FromSql, Type};
use tablepro_core::Value;

use super::decode::decode_binary;

/// One cell of a binary result, whatever its type.
///
/// It accepts every type so tokio-postgres never refuses a column the
/// app has no Rust type for; the decode itself picks the `Value`.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct RawCell(pub(crate) Value);

impl<'a> FromSql<'a> for RawCell {
    fn from_sql(ty: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        Ok(Self(decode_binary(ty, raw)))
    }

    fn from_sql_null(_: &Type) -> Result<Self, Box<dyn Error + Sync + Send>> {
        Ok(Self(Value::Null))
    }

    fn accepts(_: &Type) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_null_is_null_and_a_value_is_decoded() {
        assert_eq!(
            RawCell::from_sql_nullable(&Type::INT4, None).map(|cell| cell.0).ok(),
            Some(Value::Null)
        );
        assert_eq!(
            RawCell::from_sql_nullable(&Type::BOOL, Some(&[1]))
                .map(|cell| cell.0)
                .ok(),
            Some(Value::Bool(true))
        );
        assert!(RawCell::accepts(&Type::TS_VECTOR));
    }
}
