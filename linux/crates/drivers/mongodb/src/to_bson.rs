use std::str::FromStr;

use bson::oid::ObjectId;
use bson::spec::BinarySubtype;
use bson::{Binary, Bson, Decimal128, Document, JavaScriptCodeWithScope, Regex, Timestamp};
use chrono::{DateTime, NaiveDate, NaiveDateTime};
use tablepro_core::sql_syntax::mongo::{ShellConstructor, ShellNumber, ShellValue, parse_value};
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::{Temporal, Value};

/// A value the shell text names that BSON cannot hold, refused before
/// anything is sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ValueError(pub(crate) String);

impl ValueError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

type Converted = Result<Bson, ValueError>;

/// A shell value as BSON, `$n` taken from `params`. An object that is one
/// of extended JSON's wrappers, such as `{"$oid": "..."}`, is the value
/// it wraps, which is how a document read into a cell comes back.
pub(crate) fn to_bson(value: &ShellValue, params: &[BoundParam]) -> Converted {
    match value {
        ShellValue::Object(fields) => match wrapper(fields)? {
            Some(wrapped) => Ok(wrapped),
            None => Ok(Bson::Document(document(fields, params)?)),
        },
        ShellValue::Array(items) => items
            .iter()
            .map(|item| to_bson(item, params))
            .collect::<Result<Vec<_>, _>>()
            .map(Bson::Array),
        ShellValue::String(text) => Ok(Bson::String(text.clone())),
        ShellValue::Number(number) => number_bson(number),
        ShellValue::Bool(flag) => Ok(Bson::Boolean(*flag)),
        ShellValue::Null => Ok(Bson::Null),
        ShellValue::Regex { pattern, flags } => regex(pattern, flags),
        ShellValue::Constructor { kind, args } => constructed(*kind, args),
        ShellValue::Param(index) => params
            .get(index.wrapping_sub(1))
            .ok_or_else(|| ValueError::new(format!("${index} has no value")))
            .and_then(param_bson),
    }
}

/// A document, its fields in the order written.
pub(crate) fn document(fields: &[(String, ShellValue)], params: &[BoundParam]) -> Result<Document, ValueError> {
    let mut document = Document::new();
    for (key, value) in fields {
        document.insert(key.clone(), to_bson(value, params)?);
    }
    Ok(document)
}

/// A value bound by a generated statement, typed as its column asked.
pub(crate) fn param_bson(param: &BoundParam) -> Converted {
    Ok(match param.value() {
        Value::Null => Bson::Null,
        Value::Bool(flag) => Bson::Boolean(*flag),
        Value::Int(number) => match (param.param_type(), i32::try_from(*number)) {
            (ParamType::Int32, Ok(small)) => Bson::Int32(small),
            _ => Bson::Int64(*number),
        },
        Value::UInt(number) => match i64::try_from(*number) {
            Ok(number) => Bson::Int64(number),
            Err(_) => decimal(&number.to_string())?,
        },
        Value::Float32(number) => Bson::Double(f64::from(*number)),
        Value::Float64(number) => Bson::Double(*number),
        Value::Decimal(number) => decimal(&number.to_string())?,
        Value::WideInt(number) => decimal(&number.to_string())?,
        Value::Text(text) => Bson::String(text.clone()),
        Value::Bytes(bytes) => Bson::Binary(Binary {
            subtype: BinarySubtype::Generic,
            bytes: bytes.clone(),
        }),
        Value::Uuid(uuid) => Bson::Binary(Binary {
            subtype: BinarySubtype::Uuid,
            bytes: uuid.as_bytes().to_vec(),
        }),
        Value::Json(json) => {
            let value = parse_value(json.as_str()).map_err(|error| ValueError::new(error.to_string()))?;
            to_bson(&value, &[])?
        }
        Value::TimestampTz(Temporal::Finite(stamp)) => millis_bson(stamp.to_datetime().timestamp_millis()),
        Value::Timestamp(Temporal::Finite(stamp)) => millis_bson(stamp.and_utc().timestamp_millis()),
        Value::Date(Temporal::Finite(date)) => millis_bson(midnight(*date).and_utc().timestamp_millis()),
        Value::Other(other) => match other.type_name.as_str() {
            "objectId" => object_id(other.text.trim())?,
            _ => Bson::String(other.text.clone()),
        },
        other => {
            return Err(ValueError::new(format!(
                "a {} value has no MongoDB type",
                other.variant_name()
            )));
        }
    })
}

fn midnight(date: NaiveDate) -> NaiveDateTime {
    date.and_hms_opt(0, 0, 0).unwrap_or_default()
}

fn millis_bson(millis: i64) -> Bson {
    Bson::DateTime(bson::DateTime::from_millis(millis))
}

/// An integer that fits 32 bits is an int and a larger one a long, as
/// mongosh stores them; one with a fraction or an exponent is a double.
fn number_bson(number: &ShellNumber) -> Converted {
    if let Some(integer) = number.as_integer() {
        return Ok(match i32::try_from(integer) {
            Ok(small) => Bson::Int32(small),
            Err(_) => Bson::Int64(integer),
        });
    }
    number
        .as_f64()
        .map(Bson::Double)
        .ok_or_else(|| ValueError::new(format!("{} is not a number MongoDB stores", number.text())))
}

fn regex(pattern: &str, flags: &str) -> Converted {
    let mut options: Vec<char> = flags.chars().collect();
    options.sort_unstable();
    options.dedup();
    let options: String = options.into_iter().collect();
    let pattern = pattern
        .to_owned()
        .try_into()
        .map_err(|_| ValueError::new("a regular expression cannot hold a NUL character"))?;
    let options = options
        .try_into()
        .map_err(|_| ValueError::new("a regular expression's flags cannot hold a NUL character"))?;
    Ok(Bson::RegularExpression(Regex { pattern, options }))
}

fn decimal(text: &str) -> Converted {
    Decimal128::from_str(text.trim())
        .map(Bson::Decimal128)
        .map_err(|_| ValueError::new(format!("{text} is not a decimal MongoDB stores")))
}

fn object_id(hex: &str) -> Converted {
    ObjectId::parse_str(hex)
        .map(Bson::ObjectId)
        .map_err(|_| ValueError::new(format!("“{hex}” is not an ObjectId: it takes 24 hex digits")))
}

fn text_arg(args: &[ShellValue], index: usize) -> Option<&str> {
    args.get(index).and_then(ShellValue::as_str)
}

/// A number given as a number or as its digits in quotes.
fn number_text(args: &[ShellValue]) -> Option<String> {
    match args.first()? {
        ShellValue::Number(number) => Some(number.text().to_owned()),
        ShellValue::String(text) => Some(text.trim().to_owned()),
        _ => None,
    }
}

fn whole<T: TryFrom<i64>>(args: &[ShellValue], helper: &str) -> Result<T, ValueError> {
    let text = number_text(args).unwrap_or_default();
    let number = ShellNumber::new(text.clone())
        .as_integer()
        .and_then(|integer| T::try_from(integer).ok());
    number.ok_or_else(|| ValueError::new(format!("{helper}({text}) is not a whole number it holds")))
}

fn constructed(kind: ShellConstructor, args: &[ShellValue]) -> Converted {
    Ok(match kind {
        ShellConstructor::ObjectId => match text_arg(args, 0) {
            Some(hex) => object_id(hex)?,
            None => Bson::ObjectId(ObjectId::new()),
        },
        ShellConstructor::Date => match args.first() {
            None => Bson::DateTime(bson::DateTime::now()),
            Some(ShellValue::Number(number)) => match number.as_integer() {
                Some(millis) => millis_bson(millis),
                None => return Err(ValueError::new("a date takes whole milliseconds")),
            },
            Some(_) => millis_bson(date_millis(text_arg(args, 0).unwrap_or_default())?),
        },
        ShellConstructor::Int32 => Bson::Int32(whole(args, "NumberInt")?),
        ShellConstructor::Int64 => Bson::Int64(whole(args, "NumberLong")?),
        ShellConstructor::Double => Bson::Double(
            number_text(args)
                .and_then(|text| ShellNumber::new(text).as_f64())
                .ok_or_else(|| ValueError::new("Double() takes a number"))?,
        ),
        ShellConstructor::Decimal128 => decimal(&number_text(args).unwrap_or_default())?,
        ShellConstructor::Timestamp => timestamp(args)?,
        ShellConstructor::Uuid => {
            let uuid = match text_arg(args, 0) {
                Some(text) => {
                    uuid::Uuid::parse_str(text).map_err(|_| ValueError::new(format!("“{text}” is not a UUID")))?
                }
                None => uuid::Uuid::new_v4(),
            };
            Bson::Binary(Binary {
                subtype: BinarySubtype::Uuid,
                bytes: uuid.as_bytes().to_vec(),
            })
        }
        ShellConstructor::BinData => {
            let subtype: u8 = whole(args, "BinData")?;
            Bson::Binary(
                Binary::from_base64(text_arg(args, 1).unwrap_or_default(), BinarySubtype::from(subtype))
                    .map_err(|_| ValueError::new("BinData() takes base64"))?,
            )
        }
        ShellConstructor::HexData => {
            let subtype: u8 = whole(args, "HexData")?;
            Bson::Binary(Binary {
                subtype: BinarySubtype::from(subtype),
                bytes: hex_bytes(text_arg(args, 1).unwrap_or_default())?,
            })
        }
        ShellConstructor::MinKey => Bson::MinKey,
        ShellConstructor::MaxKey => Bson::MaxKey,
        ShellConstructor::RegExp => regex(
            text_arg(args, 0).unwrap_or_default(),
            text_arg(args, 1).unwrap_or_default(),
        )?,
        ShellConstructor::Code => Bson::JavaScriptCode(text_arg(args, 0).unwrap_or_default().to_owned()),
    })
}

fn timestamp(args: &[ShellValue]) -> Converted {
    let part = |value: Option<&ShellValue>| match value {
        Some(ShellValue::Number(number)) => number.as_integer().and_then(|integer| u32::try_from(integer).ok()),
        _ => None,
    };
    let (time, increment) = match args {
        [ShellValue::Object(fields)] => {
            let field = |name: &str| fields.iter().find(|(key, _)| key == name).map(|(_, value)| value);
            (part(field("t")), part(field("i")))
        }
        _ => (part(args.first()), part(args.get(1))),
    };
    match (time, increment) {
        (Some(time), Some(increment)) => Ok(Bson::Timestamp(Timestamp { time, increment })),
        _ => Err(ValueError::new("Timestamp() takes seconds and an increment")),
    }
}

fn hex_bytes(text: &str) -> Result<Vec<u8>, ValueError> {
    let digits = text.as_bytes();
    if !digits.len().is_multiple_of(2) {
        return Err(ValueError::new("HexData() takes an even number of hex digits"));
    }
    digits
        .chunks(2)
        .map(|pair| {
            std::str::from_utf8(pair)
                .ok()
                .and_then(|pair| u8::from_str_radix(pair, 16).ok())
                .ok_or_else(|| ValueError::new("HexData() takes hex digits"))
        })
        .collect()
}

/// A date as mongosh's `ISODate` reads one: a full timestamp with or
/// without its zone, which is then UTC, or a date alone at midnight UTC.
fn date_millis(text: &str) -> Result<i64, ValueError> {
    let text = text.trim();
    if let Ok(date) = DateTime::parse_from_rfc3339(text) {
        return Ok(date.timestamp_millis());
    }
    for format in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M"] {
        if let Ok(stamp) = NaiveDateTime::parse_from_str(text, format) {
            return Ok(stamp.and_utc().timestamp_millis());
        }
    }
    if let Ok(date) = NaiveDate::parse_from_str(text, "%Y-%m-%d") {
        return Ok(midnight(date).and_utc().timestamp_millis());
    }
    Err(ValueError::new(format!("“{text}” is not a date ISODate() reads")))
}

/// A DBPointer as extended JSON names one. The type has no constructor
/// of its own, so it is read back through the library's extended JSON.
fn db_pointer(pointer: Option<&ShellValue>) -> Result<Bson, ValueError> {
    let refused = || ValueError::new("$dbPointer takes a $ref and an $id");
    let pointer = pointer.ok_or_else(refused)?;
    let namespace = pointer.field("$ref").and_then(ShellValue::as_str).ok_or_else(refused)?;
    let id = pointer
        .field("$id")
        .and_then(|id| id.field("$oid"))
        .and_then(ShellValue::as_str)
        .ok_or_else(refused)?;
    let quoted = |text: &str| serde_json::to_string(text).map_err(|_| refused());
    let text = format!(
        r#"{{"$dbPointer": {{"$ref": {}, "$id": {{"$oid": {}}}}}}}"#,
        quoted(namespace)?,
        quoted(id)?
    );
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|_| refused())?;
    match Bson::try_from(json) {
        Ok(pointer @ Bson::DbPointer(_)) => Ok(pointer),
        _ => Err(refused()),
    }
}

/// The value an extended JSON wrapper stands for, or `None` when the
/// object is a plain document.
fn wrapper(fields: &[(String, ShellValue)]) -> Result<Option<Bson>, ValueError> {
    let keys: Vec<&str> = fields.iter().map(|(key, _)| key.as_str()).collect();
    let field = |name: &str| fields.iter().find(|(key, _)| key == name).map(|(_, value)| value);
    let text = |name: &str| field(name).and_then(ShellValue::as_str);
    let wrapped = match keys.as_slice() {
        ["$oid"] => object_id(text("$oid").unwrap_or_default())?,
        ["$numberInt"] => Bson::Int32(
            text("$numberInt")
                .and_then(|digits| digits.parse().ok())
                .ok_or_else(|| ValueError::new("$numberInt takes an int in quotes"))?,
        ),
        ["$numberLong"] => Bson::Int64(
            text("$numberLong")
                .and_then(|digits| digits.parse().ok())
                .ok_or_else(|| ValueError::new("$numberLong takes a long in quotes"))?,
        ),
        ["$numberDouble"] => Bson::Double(
            text("$numberDouble")
                .and_then(|digits| ShellNumber::new(digits).as_f64())
                .ok_or_else(|| ValueError::new("$numberDouble takes a double in quotes"))?,
        ),
        ["$numberDecimal"] => decimal(text("$numberDecimal").unwrap_or_default())?,
        ["$date"] => match field("$date") {
            Some(ShellValue::String(text)) => millis_bson(date_millis(text)?),
            Some(ShellValue::Number(number)) => millis_bson(
                number
                    .as_integer()
                    .ok_or_else(|| ValueError::new("$date takes whole milliseconds"))?,
            ),
            Some(ShellValue::Object(inner)) => match wrapper(inner)? {
                Some(Bson::Int64(millis)) => millis_bson(millis),
                Some(Bson::Int32(millis)) => millis_bson(i64::from(millis)),
                _ => return Err(ValueError::new("$date takes a date or its milliseconds")),
            },
            _ => return Err(ValueError::new("$date takes a date or its milliseconds")),
        },
        ["$binary"] => match field("$binary") {
            Some(ShellValue::Object(inner)) => {
                let inner_text = |name: &str| {
                    inner
                        .iter()
                        .find(|(key, _)| key == name)
                        .and_then(|(_, value)| value.as_str())
                };
                let subtype = u8::from_str_radix(inner_text("subType").unwrap_or("00"), 16)
                    .map_err(|_| ValueError::new("$binary takes a subType in hex"))?;
                Bson::Binary(
                    Binary::from_base64(inner_text("base64").unwrap_or_default(), BinarySubtype::from(subtype))
                        .map_err(|_| ValueError::new("$binary takes base64"))?,
                )
            }
            _ => return Err(ValueError::new("$binary takes base64 and a subType")),
        },
        ["$uuid"] => constructed(
            ShellConstructor::Uuid,
            &[ShellValue::string(text("$uuid").unwrap_or_default())],
        )?,
        ["$regularExpression"] => match field("$regularExpression") {
            Some(ShellValue::Object(inner)) => {
                let inner_text = |name: &str| {
                    inner
                        .iter()
                        .find(|(key, _)| key == name)
                        .and_then(|(_, value)| value.as_str())
                };
                regex(
                    inner_text("pattern").unwrap_or_default(),
                    inner_text("options").unwrap_or_default(),
                )?
            }
            _ => return Err(ValueError::new("$regularExpression takes a pattern and options")),
        },
        ["$timestamp"] => match field("$timestamp") {
            Some(inner @ ShellValue::Object(_)) => timestamp(std::slice::from_ref(inner))?,
            _ => return Err(ValueError::new("$timestamp takes t and i")),
        },
        ["$dbPointer"] => db_pointer(field("$dbPointer"))?,
        ["$minKey"] => Bson::MinKey,
        ["$maxKey"] => Bson::MaxKey,
        ["$undefined"] => Bson::Undefined,
        ["$symbol"] => Bson::Symbol(text("$symbol").unwrap_or_default().to_owned()),
        ["$code"] => Bson::JavaScriptCode(text("$code").unwrap_or_default().to_owned()),
        ["$code", "$scope"] => match field("$scope") {
            Some(ShellValue::Object(scope)) => Bson::JavaScriptCodeWithScope(JavaScriptCodeWithScope {
                code: text("$code").unwrap_or_default().to_owned(),
                scope: document(scope, &[])?,
            }),
            _ => return Err(ValueError::new("$scope takes a document")),
        },
        _ => return Ok(None),
    };
    Ok(Some(wrapped))
}

#[cfg(test)]
mod tests {
    use tablepro_core::document::bind_param;
    use tablepro_core::value::{JsonText, OtherValue};

    use super::*;
    use crate::extended_json::extended_json;

    fn shell(text: &str) -> Bson {
        to_bson(&parse_value(text).expect("a value"), &[]).expect("a BSON value")
    }

    #[test]
    fn numbers_take_the_type_mongosh_gives_them() {
        assert_eq!(shell("7"), Bson::Int32(7));
        assert_eq!(shell("-3000000000"), Bson::Int64(-3_000_000_000));
        assert_eq!(shell("7.0"), Bson::Double(7.0));
        assert_eq!(shell("1e3"), Bson::Double(1000.0));
        assert_eq!(shell("NumberLong(7)"), Bson::Int64(7));
        assert_eq!(shell("NumberInt('7')"), Bson::Int32(7));
        assert_eq!(shell("NumberDecimal('1.50')").to_string(), "1.50");
    }

    #[test]
    fn helpers_and_wrappers_make_the_same_values() {
        let id = "5f1d7a0c9b1e8b2a3c4d5e6f";
        assert_eq!(shell(&format!("ObjectId('{id}')")), shell(&format!("{{$oid: '{id}'}}")));
        assert_eq!(
            shell("ISODate('2024-01-02T03:04:05.006Z')"),
            shell("{$date: '2024-01-02T03:04:05.006Z'}")
        );
        assert_eq!(shell("ISODate('2024-01-02')"), shell("new Date('2024-01-02T00:00:00')"));
        assert_eq!(
            shell("/a.b/xi"),
            shell("{$regularExpression: {pattern: 'a.b', options: 'ix'}}")
        );
        assert_eq!(shell("Timestamp(5, 2)"), shell("{$timestamp: {t: 5, i: 2}}"));
        assert_eq!(shell("BinData(0, 'aGk=')"), shell("HexData(0, '6869')"));
        assert!(
            matches!(shell("{$oid: 'x', other: 1}"), Bson::Document(_)),
            "a wrapper with more keys"
        );
    }

    #[test]
    fn extended_json_reads_back_as_the_same_value() {
        let value = shell(
            "{z: NumberLong(1), a: 1, d: 1.0, when: ISODate('2023-11-14T22:13:20.123Z'), \
             id: ObjectId('5f1d7a0c9b1e8b2a3c4d5e6f'), bin: BinData(4, 'AAECAwQFBgcICQoLDA0ODw=='), \
             nested: {list: [MinKey(), Timestamp(1, 2), /x/i, NumberDecimal('2.5')]}}",
        );

        assert_eq!(shell(&extended_json(&value)), value);
        let pointer = Bson::try_from(
            serde_json::from_str::<serde_json::Value>(
                r#"{"$dbPointer": {"$ref": "shop.users", "$id": {"$oid": "5f1d7a0c9b1e8b2a3c4d5e6f"}}}"#,
            )
            .expect("JSON"),
        )
        .expect("a DBPointer");
        assert!(matches!(pointer, Bson::DbPointer(_)));
        assert_eq!(shell(&extended_json(&pointer)), pointer);
    }

    #[test]
    fn a_bound_value_keeps_its_columns_type() {
        let int = bind_param(Value::Int(5), None).expect("a long");
        assert_eq!(param_bson(&int), Ok(Bson::Int64(5)));
        let id = Value::Other(Box::new(OtherValue {
            type_name: "objectId".to_owned(),
            text: "5f1d7a0c9b1e8b2a3c4d5e6f".to_owned(),
        }));
        assert!(matches!(
            param_bson(&bind_param(id, None).expect("an id")),
            Ok(Bson::ObjectId(_))
        ));
        let bad = Value::Other(Box::new(OtherValue {
            type_name: "objectId".to_owned(),
            text: "nope".to_owned(),
        }));
        assert!(param_bson(&bind_param(bad, None).expect("text")).is_err());
        let json = Value::Json(JsonText::parse(r#"{"a": {"$numberLong": "2"}}"#.to_owned()).expect("JSON"));
        assert_eq!(
            param_bson(&bind_param(json, None).expect("JSON")),
            Ok(Bson::Document(bson::doc! { "a": 2_i64 }))
        );
    }
}
