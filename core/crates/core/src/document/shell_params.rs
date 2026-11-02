use crate::column::{ColumnInfo, SqlTypeExpr};
use crate::dialect::BindError;
use crate::sql_syntax::mongo::{ShellCall, ShellValue};
use crate::statement::{BoundParam, ParamType, Statement, StatementBuilder};
use crate::value::Value;

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

    /// Bind `value` as the next parameter, typed by `column` where there
    /// is one, and return the marker that stands for it.
    pub(crate) fn bind(&mut self, value: Value, column: Option<&ColumnInfo>) -> Result<ShellValue, BindError> {
        let param = bind_param(value, column)?;
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
pub fn bind_param(value: Value, column: Option<&ColumnInfo>) -> Result<BoundParam, BindError> {
    let type_name = column.map(|column| column.column_type.name.as_str());
    let param_type = match (&value, type_name) {
        (Value::Null, Some(name)) => param_type_named(name),
        (Value::Null, None) | (Value::Text(_), _) => ParamType::Text,
        (Value::Int(_), Some("int")) => ParamType::Int32,
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
