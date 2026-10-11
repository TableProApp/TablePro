use crate::query::Value;

const PREFIX: &str = "bookie:sqlite-any:v1:";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DecodeError {
    Malformed,
}

pub(crate) fn is_any_type(data_type: &str) -> bool {
    data_type.trim().eq_ignore_ascii_case("any")
}

pub(crate) fn is_unknown_type(data_type: &str) -> bool {
    data_type.trim().is_empty() || data_type.trim().eq_ignore_ascii_case("null")
}

pub(crate) fn encode(value: &Value) -> Option<String> {
    let (kind, text) = match value {
        Value::Int(value) => ("integer", value.to_string()),
        Value::Float(value) => ("real", value.to_string()),
        Value::Text(value) => ("text", value.clone()),
        Value::Bytes(value) => ("blob", value.iter().map(|byte| format!("{byte:02x}")).collect()),
        _ => return None,
    };
    Some(format!("{PREFIX}{kind}:{text}"))
}

pub(crate) fn decode(text: &str) -> Result<Option<Value>, DecodeError> {
    let Some(tagged) = text.strip_prefix(PREFIX) else {
        return Ok(None);
    };
    let Some((kind, value)) = tagged.split_once(':') else {
        return Err(DecodeError::Malformed);
    };
    match kind {
        "integer" => value
            .parse()
            .map(Value::Int)
            .map(Some)
            .map_err(|_| DecodeError::Malformed),
        "real" => value
            .parse()
            .map(Value::Float)
            .map(Some)
            .map_err(|_| DecodeError::Malformed),
        "text" => Ok(Some(Value::Text(value.to_owned()))),
        "blob" => decode_hex(value).map(|bytes| Some(Value::Bytes(bytes))),
        _ => Err(DecodeError::Malformed),
    }
}

fn decode_hex(text: &str) -> Result<Vec<u8>, DecodeError> {
    if !text.len().is_multiple_of(2) {
        return Err(DecodeError::Malformed);
    }
    text.as_bytes()
        .chunks(2)
        .map(|pair| {
            let digits = std::str::from_utf8(pair).map_err(|_| DecodeError::Malformed)?;
            u8::from_str_radix(digits, 16).map_err(|_| DecodeError::Malformed)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typed_values_round_trip_and_text_can_contain_the_tag_prefix() {
        let values = [
            Value::Int(i64::MIN),
            Value::Float(-0.0),
            Value::Text("bookie:sqlite-any:v1:integer:42".into()),
            Value::Text(String::new()),
            Value::Bytes(vec![0, 255, 128]),
            Value::Bytes(vec![]),
        ];
        for value in &values {
            let encoded = encode(value).unwrap();
            assert_eq!(decode(&encoded).unwrap(), Some(value.clone()));
        }
        let encoded = encode(&values[1]).unwrap();
        let Some(Value::Float(decoded)) = decode(&encoded).unwrap() else {
            panic!("expected tagged REAL");
        };
        let Value::Float(original) = &values[1] else {
            panic!("expected original REAL");
        };
        assert_eq!(decoded.to_bits(), original.to_bits());
    }

    #[test]
    fn malformed_reserved_tags_are_rejected_and_unmarked_values_remain_text() {
        assert_eq!(decode("42").unwrap(), None);
        assert!(decode("bookie:sqlite-any:v1:integer:nope").is_err());
        assert!(decode("bookie:sqlite-any:v1:blob:0xz1").is_err());
        assert!(decode("bookie:sqlite-any:v1:blob:f").is_err());
    }
}
