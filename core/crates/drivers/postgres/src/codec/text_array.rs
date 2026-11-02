use std::error::Error;

use fallible_iterator::FallibleIterator;
use postgres_protocol::types::array_from_sql;
use postgres_types::{FromSql, Kind, Type};

/// A one-dimensional array of text from the catalog, read element by
/// element. `Vec<String>`'s own `FromSql` collects, which reserves room
/// for the count the header claims before reading anything, so a
/// hostile server could ask for any amount of memory in a few bytes.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct TextArray(pub(crate) Vec<String>);

impl<'a> FromSql<'a> for TextArray {
    fn from_sql(ty: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        let Kind::Array(member) = ty.kind() else {
            return Err(format!("{ty} is not an array").into());
        };
        let array = array_from_sql(raw)?;
        if array.dimensions().count()? > 1 {
            return Err("the array has more than one dimension".into());
        }
        let mut elements = array.values();
        let mut values = Vec::new();
        while let Some(element) = elements.next()? {
            values.push(String::from_sql_nullable(member, element)?);
        }
        Ok(Self(values))
    }

    fn accepts(ty: &Type) -> bool {
        matches!(ty.kind(), Kind::Array(member) if <String as FromSql>::accepts(member))
    }
}

#[cfg(test)]
mod tests {
    use bytes::BytesMut;
    use postgres_protocol::IsNull;
    use postgres_protocol::types::{ArrayDimension, array_to_sql};

    use super::*;

    fn text_array(len: i32, elements: &[&str]) -> Vec<u8> {
        let mut raw = BytesMut::new();
        array_to_sql(
            [ArrayDimension { len, lower_bound: 1 }],
            Type::TEXT.oid(),
            elements.iter(),
            |element, buf| {
                buf.extend_from_slice(element.as_bytes());
                Ok(IsNull::No)
            },
            &mut raw,
        )
        .unwrap();
        raw.to_vec()
    }

    #[test]
    fn an_array_reads_its_elements() {
        let raw = text_array(2, &["id", "email"]);

        assert_eq!(
            TextArray::from_sql(&Type::TEXT_ARRAY, &raw).unwrap(),
            TextArray(vec!["id".to_owned(), "email".to_owned()])
        );
    }

    #[test]
    fn a_count_the_bytes_do_not_hold_is_an_error() {
        let raw = text_array(i32::MAX, &["id"]);

        assert!(TextArray::from_sql(&Type::TEXT_ARRAY, &raw).is_err());
    }
}
