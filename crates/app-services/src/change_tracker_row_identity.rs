use tablepro_core::{Value, sql_dialect::BuildSqlError};

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum RowKey {
    Persisted(Vec<KeyValue>),
    Draft(u64),
}

impl RowKey {
    pub fn from_pk_values(pk_values: &[Value]) -> Option<Self> {
        if pk_values.is_empty() || pk_values_are_unreadable(pk_values) {
            return None;
        }
        Some(RowKey::Persisted(pk_values.iter().map(KeyValue::from).collect()))
    }
}

pub fn pk_values_are_unreadable(pk_values: &[Value]) -> bool {
    pk_values.iter().any(|v| matches!(v, Value::Undecodable(_)))
}

#[derive(Debug, thiserror::Error)]
pub enum MaterializeError {
    #[error(transparent)]
    BuildSql(#[from] BuildSqlError),

    #[error("a row cannot be updated or deleted because its key value could not be read from the database")]
    UnreadableRowKey,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum KeyValue {
    Null,
    Bool(bool),
    Int(i64),
    FloatBits(u64),
    Text(String),
    Bytes(Vec<u8>),
    Date(chrono::NaiveDate),
    Time(chrono::NaiveTime),
    DateTime(chrono::NaiveDateTime),
    TimestampTz(chrono::DateTime<chrono::Utc>),
    Decimal(String),
    Uuid(uuid::Uuid),
    Json(String),
    JsonText(String),
    Undecodable(String),
}

impl From<&Value> for KeyValue {
    fn from(v: &Value) -> Self {
        match v {
            Value::Null => KeyValue::Null,
            Value::Bool(b) => KeyValue::Bool(*b),
            Value::Int(i) => KeyValue::Int(*i),
            Value::Float(f) => KeyValue::FloatBits(f.to_bits()),
            Value::Text(s) => KeyValue::Text(s.clone()),
            Value::Bytes(b) => KeyValue::Bytes(b.clone()),
            Value::Date(d) => KeyValue::Date(*d),
            Value::Time(t) => KeyValue::Time(*t),
            Value::DateTime(dt) => KeyValue::DateTime(*dt),
            Value::TimestampTz(ts) => KeyValue::TimestampTz(*ts),
            Value::Decimal(d) => KeyValue::Decimal(d.to_string()),
            Value::Uuid(u) => KeyValue::Uuid(*u),
            Value::Json(j) => KeyValue::Json(j.to_string()),
            Value::JsonText(j) => KeyValue::JsonText(j.clone()),
            Value::Undecodable(type_name) => KeyValue::Undecodable(type_name.clone()),
        }
    }
}

pub(crate) fn keyvalue_to_value(kv: &KeyValue) -> Value {
    match kv {
        KeyValue::Null => Value::Null,
        KeyValue::Bool(b) => Value::Bool(*b),
        KeyValue::Int(i) => Value::Int(*i),
        KeyValue::FloatBits(bits) => Value::Float(f64::from_bits(*bits)),
        KeyValue::Text(s) => Value::Text(s.clone()),
        KeyValue::Bytes(b) => Value::Bytes(b.clone()),
        KeyValue::Date(d) => Value::Date(*d),
        KeyValue::Time(t) => Value::Time(*t),
        KeyValue::DateTime(dt) => Value::DateTime(*dt),
        KeyValue::TimestampTz(ts) => Value::TimestampTz(*ts),
        KeyValue::Decimal(s) => s.parse().map(Value::Decimal).unwrap_or(Value::Text(s.clone())),
        KeyValue::Uuid(u) => Value::Uuid(*u),
        KeyValue::Json(s) => serde_json::from_str(s)
            .map(Value::Json)
            .unwrap_or(Value::Text(s.clone())),
        KeyValue::JsonText(s) => Value::JsonText(s.clone()),
        KeyValue::Undecodable(type_name) => Value::Undecodable(type_name.clone()),
    }
}
