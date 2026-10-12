use serde::Serialize;
use serde::ser::{Error as _, SerializeSeq, Serializer};
use tablepro_core::Value;
use tablepro_core::statement::BoundParam;
use tablepro_core::value::Temporal;

/// One bound value in the text form ClickHouse parses a `{pN:Type}`
/// query parameter from.
///
/// The client escapes what this writes, so a string reaches the server
/// byte for byte, and bytes that are not UTF-8 go as `\xNN` escapes.
pub(crate) struct ParamValue<'a>(pub(crate) &'a Value);

/// The name a statement's parameter `index` goes by, which is the name
/// the dialect wrote into its `{pN:Type}` marker.
pub(crate) fn param_name(index: usize) -> String {
    format!("p{index}")
}

/// Bind every parameter of a statement to its query, by position.
pub(crate) fn bind_params(mut query: clickhouse::query::Query, params: &[BoundParam]) -> clickhouse::query::Query {
    for (index, param) in params.iter().enumerate() {
        query = query.param(&param_name(index), ParamValue(param.value()));
    }
    query
}

impl Serialize for ParamValue<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self.0 {
            Value::Null => serializer.serialize_none(),
            Value::Bool(flag) => serializer.serialize_bool(*flag),
            Value::Int(int) => serializer.serialize_i64(*int),
            Value::UInt(int) => serializer.serialize_u64(*int),
            Value::WideInt(int) => serializer.serialize_str(&int.to_string()),
            Value::Float32(float) => match float_text(f64::from(*float)) {
                Some(text) => serializer.serialize_str(text),
                None => serializer.serialize_f32(*float),
            },
            Value::Float64(float) => match float_text(*float) {
                Some(text) => serializer.serialize_str(text),
                None => serializer.serialize_f64(*float),
            },
            Value::Decimal(decimal) => serializer.serialize_str(&decimal.to_string()),
            Value::Text(text) => serializer.serialize_str(text),
            Value::Bytes(bytes) => serializer.serialize_bytes(bytes),
            Value::Uuid(uuid) => serializer.serialize_str(&uuid.hyphenated().to_string()),
            Value::Json(json) => serializer.serialize_str(json.as_str()),
            Value::Date(Temporal::Finite(date)) => serializer.serialize_str(&date.format("%Y-%m-%d").to_string()),
            Value::Timestamp(Temporal::Finite(stamp)) => {
                serializer.serialize_str(&stamp.format("%Y-%m-%d %H:%M:%S%.f").to_string())
            }
            Value::Time(time) => serializer.serialize_str(&time.format(None)),
            Value::Array(values) => {
                let mut seq = serializer.serialize_seq(Some(values.len()))?;
                for value in values {
                    seq.serialize_element(&ParamValue(value))?;
                }
                seq.end()
            }
            Value::Other(other) => serializer.serialize_str(&other.text),
            // An infinite date has no ClickHouse spelling, an offset
            // timestamp would be read in the column's own zone, and an
            // unreadable value must not be written back as a guess.
            other => Err(S::Error::custom(format!(
                "a {} value has no ClickHouse parameter form",
                other.variant_name()
            ))),
        }
    }
}

/// The words ClickHouse reads for the non-finite floats.
fn float_text(value: f64) -> Option<&'static str> {
    if value.is_nan() {
        return Some("nan");
    }
    if value.is_infinite() {
        return Some(if value.is_sign_negative() { "-inf" } else { "inf" });
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_finite_floats_use_clickhouse_spellings() {
        assert_eq!(float_text(f64::NAN), Some("nan"));
        assert_eq!(float_text(f64::INFINITY), Some("inf"));
        assert_eq!(float_text(f64::NEG_INFINITY), Some("-inf"));
        assert_eq!(float_text(1.5), None);
    }

    #[test]
    fn parameters_are_named_by_position() {
        assert_eq!(param_name(0), "p0");
        assert_eq!(param_name(12), "p12");
    }
}
