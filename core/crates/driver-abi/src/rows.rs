// A result set as one Arrow batch. A column whose values are all of one kind Arrow has a type for keeps that
// type; any other column carries the exact text the core's export writes, with the value's kind in the field's
// metadata. Typed Arrow extensions for intervals, wide integers and the rest are a later minor
// (docs/decisions/0004-driver-plugin-abi.md).

use std::collections::HashMap;
use std::sync::Arc;

use arrow_array::builder::{
    BinaryBuilder, FixedSizeBinaryBuilder, Float32Builder, Float64Builder, Int64Builder, StringBuilder, UInt64Builder,
};
use arrow_array::{ArrayRef, BooleanArray, NullArray, RecordBatch, RecordBatchOptions};
use arrow_schema::{ArrowError, DataType, Field, Schema};
use tablepro_core::Value;
use tablepro_core::column::{ColumnType, ResultColumn};
use tablepro_core::export::value_text;

pub const EXTENSION_NAME: &str = "ARROW:extension:name";
pub const KIND: &str = "tablepro.kind";
pub const DECLARED_TYPE: &str = "tablepro.declared_type";
pub const MIXED: &str = "Mixed";

#[derive(Clone, Copy, PartialEq, Eq)]
enum Native {
    Bool,
    Int,
    UInt,
    Float32,
    Float64,
    Text,
    Bytes,
    Json,
    Uuid,
}

fn native(value: &Value) -> Option<Native> {
    Some(match value {
        Value::Bool(_) => Native::Bool,
        Value::Int(_) => Native::Int,
        Value::UInt(_) => Native::UInt,
        Value::Float32(_) => Native::Float32,
        Value::Float64(_) => Native::Float64,
        Value::Text(_) => Native::Text,
        Value::Bytes(_) => Native::Bytes,
        Value::Json(_) => Native::Json,
        Value::Uuid(_) => Native::Uuid,
        _ => return None,
    })
}

pub fn batch(columns: &[ResultColumn], rows: &[Vec<Value>]) -> Result<RecordBatch, ArrowError> {
    let mut fields = Vec::with_capacity(columns.len());
    let mut arrays = Vec::with_capacity(columns.len());
    for (index, column) in columns.iter().enumerate() {
        let values: Vec<&Value> = rows.iter().map(|row| row.get(index).unwrap_or(&Value::Null)).collect();
        let (field, array) = column_array(column, &values)?;
        fields.push(field);
        arrays.push(array);
    }
    let options = RecordBatchOptions::new().with_row_count(Some(rows.len()));
    RecordBatch::try_new_with_options(Arc::new(Schema::new(fields)), arrays, &options)
}

fn column_array(column: &ResultColumn, values: &[&Value]) -> Result<(Field, ArrayRef), ArrowError> {
    let mut kinds = values
        .iter()
        .filter(|value| !value.is_null())
        .map(|value| value.variant_name());
    let first = kinds.next();
    let uniform = first.is_some_and(|first| kinds.all(|kind| kind == first));
    let mut metadata = HashMap::from([(DECLARED_TYPE.to_owned(), column.column_type.name.clone())]);
    let Some(first) = first else {
        metadata.insert(KIND.to_owned(), "Null".to_owned());
        let field = Field::new(&column.name, DataType::Null, true).with_metadata(metadata);
        return Ok((field, Arc::new(NullArray::new(values.len()))));
    };
    let kind = if uniform { first } else { MIXED };
    metadata.insert(KIND.to_owned(), kind.to_owned());
    let found = values.iter().find_map(|value| native(value));
    let (data_type, array) = match found {
        Some(native) if uniform => native_array(native, values)?,
        _ => (DataType::Utf8, text_array(&column.column_type, values)),
    };
    match found {
        Some(Native::Json) if uniform => {
            metadata.insert(EXTENSION_NAME.to_owned(), "arrow.json".to_owned());
        }
        Some(Native::Uuid) if uniform => {
            metadata.insert(EXTENSION_NAME.to_owned(), "arrow.uuid".to_owned());
        }
        _ => {}
    }
    Ok((Field::new(&column.name, data_type, true).with_metadata(metadata), array))
}

fn native_array(native: Native, values: &[&Value]) -> Result<(DataType, ArrayRef), ArrowError> {
    Ok(match native {
        Native::Bool => (
            DataType::Boolean,
            Arc::new(
                values
                    .iter()
                    .map(|value| match value {
                        Value::Bool(flag) => Some(*flag),
                        _ => None,
                    })
                    .collect::<BooleanArray>(),
            ) as ArrayRef,
        ),
        Native::Int => {
            let mut builder = Int64Builder::with_capacity(values.len());
            for value in values {
                builder.append_option(if let Value::Int(number) = value {
                    Some(*number)
                } else {
                    None
                });
            }
            (DataType::Int64, Arc::new(builder.finish()))
        }
        Native::UInt => {
            let mut builder = UInt64Builder::with_capacity(values.len());
            for value in values {
                builder.append_option(if let Value::UInt(number) = value {
                    Some(*number)
                } else {
                    None
                });
            }
            (DataType::UInt64, Arc::new(builder.finish()))
        }
        Native::Float32 => {
            let mut builder = Float32Builder::with_capacity(values.len());
            for value in values {
                builder.append_option(if let Value::Float32(number) = value {
                    Some(*number)
                } else {
                    None
                });
            }
            (DataType::Float32, Arc::new(builder.finish()))
        }
        Native::Float64 => {
            let mut builder = Float64Builder::with_capacity(values.len());
            for value in values {
                builder.append_option(if let Value::Float64(number) = value {
                    Some(*number)
                } else {
                    None
                });
            }
            (DataType::Float64, Arc::new(builder.finish()))
        }
        Native::Text | Native::Json => {
            let mut builder = StringBuilder::new();
            for value in values {
                match value {
                    Value::Text(text) => builder.append_value(text),
                    Value::Json(json) => builder.append_value(json.as_str()),
                    _ => builder.append_null(),
                }
            }
            (DataType::Utf8, Arc::new(builder.finish()))
        }
        Native::Bytes => {
            let mut builder = BinaryBuilder::new();
            for value in values {
                match value {
                    Value::Bytes(bytes) => builder.append_value(bytes),
                    _ => builder.append_null(),
                }
            }
            (DataType::Binary, Arc::new(builder.finish()))
        }
        Native::Uuid => {
            let mut builder = FixedSizeBinaryBuilder::with_capacity(values.len(), 16);
            for value in values {
                match value {
                    Value::Uuid(uuid) => builder.append_value(uuid.as_bytes())?,
                    _ => builder.append_null(),
                }
            }
            (DataType::FixedSizeBinary(16), Arc::new(builder.finish()))
        }
    })
}

fn text_array(column_type: &ColumnType, values: &[&Value]) -> ArrayRef {
    let mut builder = StringBuilder::new();
    for value in values {
        builder.append_option(value_text(value, column_type));
    }
    Arc::new(builder.finish())
}

#[cfg(test)]
mod tests {
    use arrow_array::{Array, BinaryArray, Int64Array, StringArray};

    use super::*;

    fn column(name: &str) -> ResultColumn {
        ResultColumn::new(name, ColumnType::untyped_text("TEXT"))
    }

    #[test]
    fn a_column_of_one_kind_keeps_its_arrow_type() {
        let rows = vec![
            vec![Value::Int(1), Value::Text("Ada".into()), Value::Bytes(vec![1, 2])],
            vec![Value::Null, Value::Text("Linus".into()), Value::Null],
        ];

        let batch = batch(&[column("id"), column("name"), column("blob")], &rows).unwrap();

        let ids = batch.column(0).as_any().downcast_ref::<Int64Array>().unwrap();
        assert_eq!(ids.value(0), 1);
        assert!(ids.is_null(1));
        let names = batch.column(1).as_any().downcast_ref::<StringArray>().unwrap();
        assert_eq!(names.value(1), "Linus");
        let blobs = batch.column(2).as_any().downcast_ref::<BinaryArray>().unwrap();
        assert_eq!(blobs.value(0), [1, 2]);
        assert_eq!(
            batch.schema().field(0).metadata().get(KIND).map(String::as_str),
            Some("Int")
        );
    }

    // SQLite types each value, not the column, so one column can hold an integer and a text.
    #[test]
    fn a_mixed_column_carries_each_value_as_its_exact_text() {
        let rows = vec![
            vec![Value::Int(7)],
            vec![Value::Text("seven".into())],
            vec![Value::Null],
        ];

        let batch = batch(&[column("mixed")], &rows).unwrap();

        let texts = batch.column(0).as_any().downcast_ref::<StringArray>().unwrap();
        assert_eq!(texts.value(0), "7");
        assert_eq!(texts.value(1), "seven");
        assert!(texts.is_null(2));
        assert_eq!(
            batch.schema().field(0).metadata().get(KIND).map(String::as_str),
            Some(MIXED)
        );
    }

    #[test]
    fn a_decimal_keeps_its_digits_as_text() {
        let rows = vec![vec![Value::Decimal("12345678901234567890.0100".parse().unwrap())]];

        let batch = batch(&[column("amount")], &rows).unwrap();

        let texts = batch.column(0).as_any().downcast_ref::<StringArray>().unwrap();
        assert_eq!(texts.value(0), "12345678901234567890.0100");
        assert_eq!(
            batch.schema().field(0).metadata().get(KIND).map(String::as_str),
            Some("Decimal")
        );
    }

    #[test]
    fn rows_with_no_columns_keep_their_count() {
        let batch = batch(&[], &[vec![], vec![]]).unwrap();

        assert_eq!(batch.num_rows(), 2);
        assert_eq!(batch.num_columns(), 0);
    }

    #[test]
    fn a_column_of_nulls_is_a_null_column() {
        let batch = batch(&[column("nothing")], &[vec![Value::Null]]).unwrap();

        assert_eq!(batch.schema().field(0).data_type(), &DataType::Null);
        assert_eq!(batch.num_rows(), 1);
    }
}
