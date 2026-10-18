use crate::dialect::BindError;
use crate::value::Value;

use super::ParamType;

/// A value checked against the type the server expects for it.
///
/// There is no way to build one without that check, so a statement's
/// parameters are known to fit before any of it reaches the wire.
#[derive(Debug, Clone, PartialEq)]
pub struct BoundParam {
    value: Value,
    param_type: ParamType,
}

impl BoundParam {
    pub fn new(value: Value, param_type: ParamType) -> Result<Self, BindError> {
        if let Value::Undecodable(undecodable) = &value {
            return Err(BindError::Undecodable {
                reason: format!("{:?} is not decodable here", undecodable.reason),
            });
        }
        if !param_type.accepts(&value) {
            return Err(BindError::ValueTypeMismatch {
                expected: param_type.name(),
                found: value.variant_name(),
            });
        }
        Ok(Self { value, param_type })
    }

    pub fn value(&self) -> &Value {
        &self.value
    }

    pub fn param_type(&self) -> &ParamType {
        &self.param_type
    }
}

#[cfg(test)]
mod tests {
    use crate::value::{UndecodableReason, UndecodedValue};

    use super::*;

    #[test]
    fn bound_param_rejects_text_for_uuid_and_undecodable() {
        let mismatch =
            BoundParam::new(Value::Text("not a uuid".to_owned()), ParamType::Uuid).expect_err("text for a uuid");
        assert_eq!(
            mismatch,
            BindError::ValueTypeMismatch {
                expected: "Uuid",
                found: "Text",
            }
        );

        let undecodable = Value::Undecodable(Box::new(UndecodedValue {
            type_name: "geography".to_owned(),
            reason: UndecodableReason::UnsupportedType,
        }));
        let refused = BoundParam::new(undecodable, ParamType::Text).expect_err("an undecodable value");
        assert!(matches!(refused, BindError::Undecodable { .. }), "{refused:?}");
    }

    #[test]
    fn a_null_binds_to_any_type() {
        let bound = BoundParam::new(Value::Null, ParamType::Uuid).expect("a null uuid");

        assert_eq!(bound.value(), &Value::Null);
        assert_eq!(bound.param_type(), &ParamType::Uuid);
    }
}
