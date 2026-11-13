use std::cmp::Ordering;

use crate::column::{ColumnInfo, ColumnType, SqlTypeExpr};
use crate::dialect::{BindError, LiteralError};
use crate::sql_syntax::mongo::{ShellCall, ShellValue, parse_value};
use crate::statement::{BoundParam, ParamType, Statement, StatementBuilder};
use crate::value::Value;
use crate::value::order::decimal_of;

/// The values a generated shell statement binds, each written into the
/// statement as `$n`.
#[derive(Debug, Default)]
pub(crate) struct ShellParams {
    builder: StatementBuilder,
}

impl ShellParams {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    // As `StatementBuilder::inlining`: each value is written as its shell literal and none is bound.
    pub(crate) fn like(builder: &StatementBuilder) -> Self {
        match builder.is_inlining() {
            true => Self {
                builder: StatementBuilder::inlining(),
            },
            false => Self::new(),
        }
    }

    /// Bind `value` as the next parameter, typed by `column` where there
    /// is one, and return the marker that stands for it.
    pub(crate) fn bind(&mut self, value: Value, column: Option<&ColumnInfo>) -> Result<ShellValue, BindError> {
        if self.builder.is_inlining() {
            return inline_literal(&value, column);
        }
        let param = bind_param(value, column, None)?;
        Ok(ShellValue::Param(self.builder.push_bound(param)))
    }

    pub(crate) fn bind_edit(
        &mut self,
        value: Value,
        column: &ColumnInfo,
        read: Option<&Value>,
    ) -> Result<ShellValue, BindError> {
        let param = bind_param(value, Some(column), read)?;
        Ok(ShellValue::Param(self.builder.push_bound(param)))
    }

    pub(crate) fn statement(mut self, call: &ShellCall) -> Statement {
        self.builder.push_sql(&call.to_string());
        self.builder.finish()
    }

    /// Write `filter` into a statement being built elsewhere, with these
    /// parameters after the ones it already has.
    pub(crate) fn into_builder(self, builder: &mut StatementBuilder, filter: &ShellValue) {
        let (_, params) = self.builder.finish().into_parts();
        let first = builder.param_count();
        for param in params {
            builder.push_bound(param);
        }
        builder.push_sql(&renumbered(filter, first).to_string());
    }
}

fn inline_literal(value: &Value, column: Option<&ColumnInfo>) -> Result<ShellValue, BindError> {
    let unknown = ColumnType::unknown();
    let column_type = column.map_or(&unknown, |column| &column.column_type);
    let text = super::shell_literal(value, column_type).map_err(|error| match error {
        LiteralError::Undecodable { reason } => BindError::Undecodable { reason },
        LiteralError::Unrepresentable { found } => BindError::Unrepresentable {
            expected: "a shell literal",
            found,
        },
    })?;
    parse_value(&text).map_err(|_| BindError::Unrepresentable {
        expected: "a shell literal",
        found: value.variant_name(),
    })
}

fn renumbered(value: &ShellValue, by: usize) -> ShellValue {
    match value {
        ShellValue::Param(index) => ShellValue::Param(index + by),
        ShellValue::Object(fields) => ShellValue::Object(
            fields
                .iter()
                .map(|(key, value)| (key.clone(), renumbered(value, by)))
                .collect(),
        ),
        ShellValue::Array(items) => ShellValue::Array(items.iter().map(|item| renumbered(item, by)).collect()),
        other => other.clone(),
    }
}

/// The parameter a value binds as. A field's own BSON type, which names
/// its column's type, decides between an int and a long and says which
/// text is an ObjectId; a value with no column is typed by itself.
pub fn bind_param(value: Value, column: Option<&ColumnInfo>, read: Option<&Value>) -> Result<BoundParam, BindError> {
    // A column's type is the widest number its sample held, so an edited number keeps the type it was read as.
    if let Some((value, param_type)) = read.and_then(|read| in_read_type(&value, read)) {
        return BoundParam::new(value, param_type);
    }
    let type_name = column.map(|column| column.column_type.name.as_str());
    let param_type = match (&value, type_name) {
        (Value::Null, Some(name)) => param_type_named(name),
        (Value::Null, None) | (Value::Text(_), _) => ParamType::Text,
        (Value::Int32(_), _) | (Value::Int(_), Some("int")) => ParamType::Int32,
        (Value::Int(_), _) => ParamType::Int64,
        (Value::UInt(_), _) => ParamType::UInt64,
        (Value::Float32(_) | Value::Float64(_), _) => ParamType::Float64,
        (Value::Decimal(_) | Value::WideInt(_), _) => ParamType::Decimal,
        (Value::Bool(_), _) => ParamType::Bool,
        (Value::Bytes(_), _) => ParamType::Bytes,
        (Value::Uuid(_), _) => ParamType::Uuid,
        (Value::Json(_), _) => ParamType::Json,
        (Value::TimestampTz(_), _) => ParamType::TimestampTz,
        (Value::Timestamp(_), _) => ParamType::Timestamp,
        (Value::Date(_), _) => ParamType::Date,
        (Value::Other(other), _) => ParamType::ServerText(SqlTypeExpr::from_catalog_text(other.type_name.clone())),
        (
            Value::Time(_)
            | Value::TimeTz(_)
            | Value::Interval(_)
            | Value::Bits(_)
            | Value::Array(_)
            | Value::Undecodable(_),
            _,
        ) => {
            return Err(BindError::Unrepresentable {
                expected: "a MongoDB value",
                found: value.variant_name(),
            });
        }
    };
    BoundParam::new(value, param_type)
}

fn in_read_type(value: &Value, read: &Value) -> Option<(Value, ParamType)> {
    if !is_number(value) {
        return None;
    }
    match read {
        Value::Int32(_) => exact_integer(value)
            .and_then(|number| i32::try_from(number).ok())
            .map(|number| (Value::Int32(number), ParamType::Int32)),
        Value::Int(_) => exact_integer(value).map(|number| (Value::Int(number), ParamType::Int64)),
        Value::Float64(_) => exact_double(value).map(|number| (Value::Float64(number), ParamType::Float64)),
        Value::Decimal(_) => decimal_of(value).map(|number| (Value::Decimal(number.into_owned()), ParamType::Decimal)),
        _ => None,
    }
}

fn is_number(value: &Value) -> bool {
    matches!(
        value,
        Value::Int32(_)
            | Value::Int(_)
            | Value::UInt(_)
            | Value::WideInt(_)
            | Value::Float32(_)
            | Value::Float64(_)
            | Value::Decimal(_)
    )
}

// A float, or a decimal typed with a fraction such as `4.0`, is not an integer even when it is whole.
fn exact_integer(value: &Value) -> Option<i64> {
    match value {
        Value::Int32(number) => Some(i64::from(*number)),
        Value::Int(number) => Some(*number),
        Value::UInt(number) => i64::try_from(*number).ok(),
        Value::WideInt(number) => number.to_i128().and_then(|number| i64::try_from(number).ok()),
        Value::Decimal(decimal) => match decimal.to_scaled_i128()? {
            (mantissa, 0) => i64::try_from(mantissa).ok(),
            _ => None,
        },
        _ => None,
    }
}

// A double whose shortest form is the same number, so `2.5` is one and `9007199254740993` is not.
fn exact_double(value: &Value) -> Option<f64> {
    if let Value::Float64(number) = value {
        return Some(*number);
    }
    let decimal = decimal_of(value)?;
    let double = decimal.to_string().parse::<f64>().ok()?;
    let read_back = Value::Float64(double);
    let shortest = decimal_of(&read_back)?;
    (shortest.cmp_numeric(&decimal) == Ordering::Equal).then_some(double)
}

/// What a null of a field of this BSON type binds as.
fn param_type_named(name: &str) -> ParamType {
    match name {
        "int" => ParamType::Int32,
        "long" => ParamType::Int64,
        "double" => ParamType::Float64,
        "decimal" => ParamType::Decimal,
        "bool" => ParamType::Bool,
        "date" => ParamType::TimestampTz,
        "uuid" => ParamType::Uuid,
        "binData" => ParamType::Bytes,
        "string" => ParamType::Text,
        "objectId" => ParamType::ServerText(SqlTypeExpr::from_catalog_text("objectId")),
        _ => ParamType::Json,
    }
}
