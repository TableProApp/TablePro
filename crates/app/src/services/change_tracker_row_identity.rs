//! Row identity for the pending changeset, and the errors building it.
//!
//! A `RowKey` survives sort, filter and page navigation because it is
//! built from the row's primary key rather than its position. `KeyValue`
//! is the hash- and ord-friendly mirror of `Value` that makes that key
//! usable as a map key.

use tablepro_core::{Value, sql_dialect::BuildSqlError};

/// Stable identity for a row across sort / filter / page navigation.
/// Persisted rows are keyed by their primary key tuple; draft rows
/// (not yet committed) are keyed by a monotonic local id assigned by
/// the tracker.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum RowKey {
    Persisted(Vec<KeyValue>),
    Draft(u64),
}

impl RowKey {
    /// Build a `Persisted` key from an existing row's PK column
    /// values, or `None` if the slice is empty (table has no PK,
    /// editing is blocked at the UI level) or any component could not
    /// be decoded by the driver.
    ///
    /// An undecodable component carries only its type name, so two rows
    /// whose keys failed to decode the same way would share one key and
    /// merge in the tracker. It also cannot be written back: a
    /// placeholder bound from it reaches the database as NULL, so the
    /// UPDATE or DELETE matches nothing while the UI reports success.
    /// A row whose identity cannot be read has no identity here.
    pub fn from_pk_values(pk_values: &[Value]) -> Option<Self> {
        if pk_values.is_empty() || pk_values_are_unreadable(pk_values) {
            return None;
        }
        Some(RowKey::Persisted(pk_values.iter().map(KeyValue::from).collect()))
    }
}

/// True when at least one primary-key component could not be decoded by
/// the driver, which makes the row unidentifiable and unmodifiable.
pub fn pk_values_are_unreadable(pk_values: &[Value]) -> bool {
    pk_values.iter().any(|v| matches!(v, Value::Undecodable(_)))
}

/// Failure building the pending changeset's statements. `BuildSql`
/// forwards the shared dialect errors; the remaining variant is owned
/// here because it is a property of the tracker's row identity rather
/// than of SQL construction.
#[derive(Debug, thiserror::Error)]
pub enum MaterializeError {
    #[error(transparent)]
    BuildSql(#[from] BuildSqlError),

    #[error("a row cannot be updated or deleted because its key value could not be read from the database")]
    UnreadableRowKey,
}

/// Hash- and Eq-friendly mirror of `Value`. Floats are stored as
/// IEEE-754 bits (so NaN equals NaN for identity purposes — pathological
/// PK case but defined behaviour). `Decimal` and `Json` are stored as
/// their canonical string forms because neither type derives `Hash`.
///
/// `Ord` exists to give a batch of statements one canonical order, not
/// to express a meaningful ranking: `FloatBits` compares raw bits, so
/// negative floats do not sort numerically. Consistency is all the
/// ordering needs, because it only decides the sequence rows are locked
/// and written in.
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
            Value::Undecodable(type_name) => KeyValue::Undecodable(type_name.clone()),
        }
    }
}

/// Lossy KeyValue → Value mapping. Used only by `materialize` to feed
/// PK values back into SQL params; equality-correctness preserved.
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
        KeyValue::Undecodable(type_name) => Value::Undecodable(type_name.clone()),
    }
}
