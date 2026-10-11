#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

pub fn corpus() -> serde_json::Value {
    serde_json::from_str(include_str!("../../../../testdata/value-contract.json")).unwrap()
}

pub fn corpus_texts(field: &str) -> Vec<String> {
    let corpus = corpus();
    corpus[field]
        .as_array()
        .unwrap()
        .iter()
        .map(|text| text.as_str().unwrap().to_owned())
        .collect()
}

pub fn assert_numeric_parsers(
    integer: impl Fn(&str) -> Option<Value>,
    decimal: impl Fn(&str) -> Option<Value>,
    float: impl Fn(&str) -> Option<Value>,
) {
    for (field, parse) in [
        ("integer_rejected", &integer as &dyn Fn(&str) -> Option<Value>),
        ("decimal_rejected", &decimal),
        ("float_rejected", &float),
    ] {
        for text in corpus_texts(field) {
            assert_eq!(parse(&text), None, "{field}: {text}");
        }
    }
    for text in corpus_texts("integers") {
        assert_eq!(integer(&text), Some(Value::Int(text.parse().unwrap())), "{text}");
    }
    for text in corpus_texts("decimals") {
        assert_eq!(decimal(&text), Some(Value::Decimal(text.parse().unwrap())), "{text}");
    }
}
