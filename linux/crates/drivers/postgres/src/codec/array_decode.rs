use fallible_iterator::FallibleIterator;
use postgres_protocol::types::{ArrayDimension, array_from_sql};
use postgres_types::Type;
use tablepro_core::Value;
use tablepro_core::export::value_to_text;
use tablepro_core::value::OtherValue;

use super::WireError;
use super::decode::{decode_binary, quote_element};

/// Deeper than PostgreSQL allows (MAXDIM is 6), so a hostile header
/// cannot drive the nesting.
const MAX_DIMENSIONS: usize = 6;

/// An array as nested `Value::Array`s, one level per dimension.
///
/// `Value::Array` has nowhere to keep a lower bound, so an array that
/// does not start at 1 is kept as the server's text instead, bounds
/// included, rather than silently renumbered.
pub(crate) fn decode_array(ty: &Type, element: &Type, raw: &[u8]) -> Result<Value, WireError> {
    let array = array_from_sql(raw).map_err(|_| WireError::Malformed)?;
    let dimensions: Vec<ArrayDimension> = array.dimensions().collect().map_err(|_| WireError::Malformed)?;
    if dimensions.is_empty() {
        return Ok(Value::Array(Vec::new()));
    }
    if dimensions.len() > MAX_DIMENSIONS {
        return Err(WireError::Malformed);
    }
    let lengths: Vec<usize> = dimensions
        .iter()
        .map(|dimension| usize::try_from(dimension.len).map_err(|_| WireError::Malformed))
        .collect::<Result<_, _>>()?;
    let total = lengths
        .iter()
        .try_fold(1usize, |total, length| total.checked_mul(*length))
        .ok_or(WireError::Malformed)?;
    let values: Vec<Value> = array
        .values()
        .map(|value| {
            Ok(match value {
                Some(bytes) => decode_binary(element, bytes),
                None => Value::Null,
            })
        })
        .collect()
        .map_err(|_| WireError::Malformed)?;
    if values.len() != total {
        return Err(WireError::Malformed);
    }
    let nested = nest(&lengths, &mut values.into_iter());
    if dimensions.iter().all(|dimension| dimension.lower_bound == 1) {
        return Ok(nested);
    }
    let bounds: String = dimensions
        .iter()
        .map(|dimension| {
            let upper = i64::from(dimension.lower_bound) + i64::from(dimension.len) - 1;
            format!("[{}:{upper}]", dimension.lower_bound)
        })
        .collect();
    Ok(Value::Other(Box::new(OtherValue {
        type_name: ty.name().to_owned(),
        text: format!("{bounds}={}", array_literal(&nested)),
    })))
}

fn nest(lengths: &[usize], values: &mut impl Iterator<Item = Value>) -> Value {
    match lengths.split_first() {
        Some((length, [])) => Value::Array(values.take(*length).collect()),
        Some((length, inner)) => Value::Array((0..*length).map(|_| nest(inner, values)).collect()),
        None => Value::Array(Vec::new()),
    }
}

/// The array's text form: `{1,2}`, nested braces per dimension, NULL
/// unquoted.
fn array_literal(value: &Value) -> String {
    match value {
        Value::Array(elements) => {
            let inner: Vec<String> = elements.iter().map(array_literal).collect();
            format!("{{{}}}", inner.join(","))
        }
        Value::Null => "NULL".to_owned(),
        other => {
            let text = value_to_text(other).unwrap_or_default();
            if text.eq_ignore_ascii_case("null") {
                return format!("\"{text}\"");
            }
            quote_element(&text, ",{}")
        }
    }
}

#[cfg(test)]
mod tests {
    use bytes::BytesMut;
    use postgres_protocol::IsNull;
    use postgres_protocol::types::{ArrayDimension, array_to_sql, int4_to_sql, text_to_sql};

    use super::*;

    fn int4_array(dimensions: Vec<ArrayDimension>, values: &[Option<i32>]) -> BytesMut {
        let mut out = BytesMut::new();
        array_to_sql(
            dimensions,
            Type::INT4.oid(),
            values.iter().copied(),
            |value, out| match value {
                Some(value) => {
                    int4_to_sql(value, out);
                    Ok(IsNull::No)
                }
                None => Ok(IsNull::Yes),
            },
            &mut out,
        )
        .expect("an array");
        out
    }

    #[test]
    fn a_two_dimensional_array_nests_by_dimension() {
        let dimensions = vec![
            ArrayDimension { len: 2, lower_bound: 1 },
            ArrayDimension { len: 2, lower_bound: 1 },
        ];
        let raw = int4_array(dimensions, &[Some(1), Some(2), None, Some(4)]);

        let value = decode_array(&Type::INT4_ARRAY, &Type::INT4, &raw).expect("an array");

        assert_eq!(
            value,
            Value::Array(vec![
                Value::Array(vec![Value::Int(1), Value::Int(2)]),
                Value::Array(vec![Value::Null, Value::Int(4)]),
            ])
        );
    }

    #[test]
    fn array_lower_bound_2_is_other_text() {
        let raw = int4_array(vec![ArrayDimension { len: 2, lower_bound: 2 }], &[Some(7), None]);

        let value = decode_array(&Type::INT4_ARRAY, &Type::INT4, &raw).expect("an array");

        let Value::Other(other) = value else {
            panic!("a renumbered array was not kept as text: {value:?}");
        };
        assert_eq!(other.text, "[2:3]={7,NULL}");
        assert_eq!(other.type_name, "_int4");
    }

    #[test]
    fn an_empty_array_has_no_dimensions() {
        let raw = int4_array(Vec::new(), &[]);

        assert_eq!(
            decode_array(&Type::INT4_ARRAY, &Type::INT4, &raw),
            Ok(Value::Array(Vec::new()))
        );
    }

    #[test]
    fn text_elements_are_quoted_where_the_text_form_needs_it() {
        let mut raw = BytesMut::new();
        array_to_sql(
            vec![ArrayDimension { len: 2, lower_bound: 0 }],
            Type::TEXT.oid(),
            ["a b", "NULL"],
            |value, out| {
                text_to_sql(value, out);
                Ok(IsNull::No)
            },
            &mut raw,
        )
        .expect("an array");

        let Ok(Value::Other(other)) = decode_array(&Type::TEXT_ARRAY, &Type::TEXT, &raw) else {
            panic!("a renumbered array was not kept as text");
        };
        assert_eq!(other.text, "[0:1]={\"a b\",\"NULL\"}");
    }
}
