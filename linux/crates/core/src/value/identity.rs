use std::hash::{Hash, Hasher};

use crate::value::Value;

#[derive(Debug, Clone)]
pub struct ValueIdentity(Value);

impl ValueIdentity {
    pub fn new(value: Value) -> Self {
        Self(value)
    }

    pub fn value(&self) -> &Value {
        &self.0
    }

    pub fn into_value(self) -> Value {
        self.0
    }
}

impl PartialEq for ValueIdentity {
    fn eq(&self, other: &Self) -> bool {
        same_value(&self.0, &other.0)
    }
}

impl Eq for ValueIdentity {}

impl Hash for ValueIdentity {
    fn hash<H: Hasher>(&self, state: &mut H) {
        hash_value(&self.0, state);
    }
}

pub fn same_value(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Float32(left), Value::Float32(right)) => left.to_bits() == right.to_bits(),
        (Value::Float64(left), Value::Float64(right)) => left.to_bits() == right.to_bits(),
        (Value::Array(left), Value::Array(right)) => {
            left.len() == right.len() && left.iter().zip(right).all(|(left, right)| same_value(left, right))
        }
        _ => left == right,
    }
}

fn hash_value<H: Hasher>(value: &Value, state: &mut H) {
    std::mem::discriminant(value).hash(state);
    match value {
        Value::Null => {}
        Value::Bool(value) => value.hash(state),
        Value::Int(value) => value.hash(state),
        Value::UInt(value) => value.hash(state),
        Value::WideInt(value) => value.hash(state),
        Value::Float32(value) => value.to_bits().hash(state),
        Value::Float64(value) => value.to_bits().hash(state),
        Value::Decimal(value) => value.hash(state),
        Value::Text(value) => value.hash(state),
        Value::Bytes(value) => value.hash(state),
        Value::Uuid(value) => value.hash(state),
        Value::Json(value) => value.hash(state),
        Value::Date(value) => value.hash(state),
        Value::Time(value) => value.hash(state),
        Value::TimeTz(value) => value.hash(state),
        Value::Timestamp(value) => value.hash(state),
        Value::TimestampTz(value) => value.hash(state),
        Value::Interval(value) => value.hash(state),
        Value::Bits(value) => value.hash(state),
        Value::Array(values) => {
            values.len().hash(state);
            for value in values {
                hash_value(value, state);
            }
        }
        Value::Other(value) => value.hash(state),
        Value::Undecodable(value) => value.hash(state),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use chrono::{DateTime, FixedOffset};

    use super::*;
    use crate::value::{OffsetTimestamp, Temporal};

    fn timestamp(offset_hours: i32) -> Value {
        let instant = DateTime::parse_from_rfc3339("2024-06-15T06:00:00Z").unwrap();
        let offset = FixedOffset::east_opt(offset_hours * 3600).unwrap();
        Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
            instant.with_timezone(&offset),
        )))
    }

    #[test]
    fn value_identity_nan_equal_negative_zero_differs_offsets_differ() {
        assert!(same_value(&Value::Float64(f64::NAN), &Value::Float64(f64::NAN)));
        assert!(!same_value(&Value::Float64(0.0), &Value::Float64(-0.0)));
        assert!(!same_value(&timestamp(0), &timestamp(7)));
        assert!(same_value(
            &Value::Array(vec![Value::Float32(f32::NAN), Value::Int(1)]),
            &Value::Array(vec![Value::Float32(f32::NAN), Value::Int(1)])
        ));

        let identities: HashSet<ValueIdentity> = [
            Value::Float64(f64::NAN),
            Value::Float64(f64::NAN),
            Value::Float64(0.0),
            Value::Float64(-0.0),
            timestamp(0),
            timestamp(7),
        ]
        .into_iter()
        .map(ValueIdentity::new)
        .collect();
        assert_eq!(identities.len(), 5);
    }
}
