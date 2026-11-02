use std::fmt::Write;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use bson::Bson;
use chrono::{DateTime, Datelike};

/// A BSON value as extended JSON a person can read and edit: relaxed,
/// so numbers, strings and dates read plainly, except that a long is
/// written canonically. Read back by the shell parser, every value comes
/// back as the type it was, an int as an int and a long as a long, and a
/// document's fields stay in their order.
pub(crate) fn extended_json(value: &Bson) -> String {
    let mut out = String::new();
    write_value(value, &mut out);
    out
}

fn write_value(value: &Bson, out: &mut String) {
    match value {
        Bson::Double(number) => write_double(*number, out),
        Bson::Int32(number) => {
            let _ = write!(out, "{number}");
        }
        Bson::Int64(number) => wrapped(out, "$numberLong", |out| write_string(&number.to_string(), out)),
        Bson::Decimal128(number) => wrapped(out, "$numberDecimal", |out| write_string(&number.to_string(), out)),
        Bson::String(text) => write_string(text, out),
        Bson::Boolean(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Bson::Null => out.push_str("null"),
        Bson::Document(document) => {
            out.push('{');
            for (index, (key, item)) in document.iter().enumerate() {
                if index > 0 {
                    out.push_str(", ");
                }
                write_string(key, out);
                out.push_str(": ");
                write_value(item, out);
            }
            out.push('}');
        }
        Bson::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push_str(", ");
                }
                write_value(item, out);
            }
            out.push(']');
        }
        Bson::ObjectId(id) => wrapped(out, "$oid", |out| write_string(&id.to_hex(), out)),
        Bson::DateTime(date) => write_date(date.timestamp_millis(), out),
        Bson::Binary(binary) => wrapped(out, "$binary", |out| {
            out.push_str("{\"base64\": ");
            write_string(&STANDARD.encode(&binary.bytes), out);
            let _ = write!(out, ", \"subType\": \"{:02x}\"}}", u8::from(binary.subtype));
        }),
        Bson::RegularExpression(regex) => wrapped(out, "$regularExpression", |out| {
            out.push_str("{\"pattern\": ");
            write_string(regex.pattern.as_str(), out);
            out.push_str(", \"options\": ");
            write_string(regex.options.as_str(), out);
            out.push('}');
        }),
        Bson::Timestamp(stamp) => {
            let _ = write!(
                out,
                "{{\"$timestamp\": {{\"t\": {}, \"i\": {}}}}}",
                stamp.time, stamp.increment
            );
        }
        Bson::JavaScriptCode(code) => wrapped(out, "$code", |out| write_string(code, out)),
        Bson::JavaScriptCodeWithScope(code) => {
            out.push_str("{\"$code\": ");
            write_string(&code.code, out);
            out.push_str(", \"$scope\": ");
            write_value(&Bson::Document(code.scope.clone()), out);
            out.push('}');
        }
        Bson::Symbol(symbol) => wrapped(out, "$symbol", |out| write_string(symbol, out)),
        Bson::Undefined => out.push_str("{\"$undefined\": true}"),
        Bson::MinKey => out.push_str("{\"$minKey\": 1}"),
        Bson::MaxKey => out.push_str("{\"$maxKey\": 1}"),
        Bson::DbPointer(_) => out.push_str(&value.clone().into_canonical_extjson().to_string()),
    }
}

fn wrapped(out: &mut String, key: &str, inner: impl FnOnce(&mut String)) {
    out.push('{');
    write_string(key, out);
    out.push_str(": ");
    inner(out);
    out.push('}');
}

fn write_string(text: &str, out: &mut String) {
    out.push_str(&serde_json::Value::String(text.to_owned()).to_string());
}

/// A double keeps a fraction or an exponent, so it reads back as a
/// double rather than an int.
fn write_double(number: f64, out: &mut String) {
    if number.is_nan() {
        out.push_str("{\"$numberDouble\": \"NaN\"}");
    } else if number.is_infinite() {
        let sign = if number < 0.0 { "-" } else { "" };
        let _ = write!(out, "{{\"$numberDouble\": \"{sign}Infinity\"}}");
    } else {
        let text = format!("{number:?}");
        out.push_str(&text);
        if !text.contains(['.', 'e', 'E']) {
            out.push_str(".0");
        }
    }
}

/// A date from 1970 to 9999 as an ISO string, any other in milliseconds,
/// as relaxed extended JSON writes them.
fn write_date(millis: i64, out: &mut String) {
    let readable = DateTime::from_timestamp_millis(millis).filter(|date| millis >= 0 && date.year() <= 9999);
    match readable {
        Some(date) => wrapped(out, "$date", |out| {
            write_string(&date.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string(), out);
        }),
        None => wrapped(out, "$date", |out| {
            wrapped(out, "$numberLong", |out| write_string(&millis.to_string(), out));
        }),
    }
}

#[cfg(test)]
mod tests {
    use bson::oid::ObjectId;
    use bson::spec::BinarySubtype;
    use bson::{Binary, Decimal128, Timestamp, doc};

    use super::*;

    #[test]
    fn a_document_keeps_its_order_and_each_value_its_type() {
        let id = ObjectId::parse_str("5f1d7a0c9b1e8b2a3c4d5e6f").expect("an id");
        let document = doc! {
            "z": 1_i32,
            "a": 2_i64,
            "d": 2.0_f64,
            "e": 1.5e20_f64,
            "id": id,
            "when": bson::DateTime::from_millis(1_700_000_000_123),
            "dec": "12.50".parse::<Decimal128>().expect("a decimal"),
            "nested": { "list": [true, null, "x\"y"] },
        };

        assert_eq!(
            extended_json(&Bson::Document(document)),
            concat!(
                r#"{"z": 1, "a": {"$numberLong": "2"}, "d": 2.0, "e": 1.5e20, "id": {"$oid": "5f1d7a0c9b1e8b2a3c4d5e6f"}, "#,
                r#""when": {"$date": "2023-11-14T22:13:20.123Z"}, "dec": {"$numberDecimal": "12.50"}, "#,
                r#""nested": {"list": [true, null, "x\"y"]}}"#
            )
        );
    }

    #[test]
    fn the_other_types_are_written_as_extended_json() {
        let cases = [
            (Bson::Double(f64::NAN), r#"{"$numberDouble": "NaN"}"#),
            (Bson::Double(f64::NEG_INFINITY), r#"{"$numberDouble": "-Infinity"}"#),
            (
                Bson::DateTime(bson::DateTime::from_millis(-1)),
                r#"{"$date": {"$numberLong": "-1"}}"#,
            ),
            (
                Bson::Binary(Binary {
                    subtype: BinarySubtype::Generic,
                    bytes: b"hi".to_vec(),
                }),
                r#"{"$binary": {"base64": "aGk=", "subType": "00"}}"#,
            ),
            (
                Bson::Timestamp(Timestamp { time: 5, increment: 2 }),
                r#"{"$timestamp": {"t": 5, "i": 2}}"#,
            ),
            (Bson::MinKey, r#"{"$minKey": 1}"#),
            (Bson::Symbol("s".to_owned()), r#"{"$symbol": "s"}"#),
        ];
        for (value, expected) in cases {
            assert_eq!(extended_json(&value), expected);
        }
    }
}
