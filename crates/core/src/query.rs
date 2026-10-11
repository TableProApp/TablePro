use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableInfo {
    pub schema: Option<String>,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QualifiedTypeName {
    pub schema: String,
    pub name: String,
}

/// Secondary-index metadata for a table. `primary` is set on the
/// auto-PK index returned by the catalog query so the UI can render
/// it as read-only (the PK is owned by the column definition, not
/// by an editable index entry).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexInfo {
    pub name: String,
    pub columns: Vec<String>,
    pub unique: bool,
    pub primary: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub predicate: Option<String>,
}

/// Foreign-key constraint metadata. `on_delete` / `on_update` carry
/// the referential action as a normalised SQL keyword string
/// ("RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT", "NO ACTION").
/// `None` means the driver returned a value we don't recognise — the
/// UI displays it as a dim-label "—" and the DDL builder omits the
/// clause so the database picks its default.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForeignKeyInfo {
    pub name: String,
    pub columns: Vec<String>,
    pub ref_schema: Option<String>,
    pub ref_table: String,
    pub ref_columns: Vec<String>,
    pub on_delete: Option<String>,
    pub on_update: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ColumnInfo {
    pub name: String,
    pub data_type: String,
    pub nullable: bool,
    pub primary_key: bool,
    /// True for `SERIAL` / `BIGSERIAL` / `IDENTITY` (PG), `AUTO_INCREMENT`
    /// (MySQL), `INTEGER PRIMARY KEY` / `AUTOINCREMENT` (SQLite). Used by
    /// the inline-insert UX to skip these columns from the user-facing
    /// draft form (DB assigns the value on commit).
    #[serde(default)]
    pub is_auto_increment: bool,
    /// Server-side default expression as raw text (e.g. `now()`,
    /// `gen_random_uuid()`, `'pending'`). When the user leaves a cell
    /// empty in a draft row and the column has a default, omit the
    /// column from the INSERT so the server applies its default.
    #[serde(default)]
    pub default_value: Option<String>,
    /// True for `GENERATED ALWAYS AS ...` columns. Always read-only;
    /// excluded from INSERT and UPDATE.
    #[serde(default)]
    pub is_generated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collation: Option<String>,
    /// The custom PostgreSQL enum type for a scalar enum column, or the
    /// qualified enum/domain element type for an array of custom values.
    #[serde(skip)]
    pub enum_type: Option<QualifiedTypeName>,
    /// The declared PostgreSQL domain type when a column is a domain.
    #[serde(skip)]
    pub domain_type: Option<QualifiedTypeName>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Text(String),
    Bytes(Vec<u8>),
    Date(NaiveDate),
    Time(NaiveTime),
    DateTime(NaiveDateTime),
    TimestampTz(DateTime<Utc>),
    Decimal(Decimal),
    Uuid(Uuid),
    Json(serde_json::Value),
    /// A non-NULL cell the driver could not decode (e.g. a wide NUMERIC
    /// sqlx cannot represent). Carries the driver's column type name so the
    /// UI can explain the gap instead of showing it as an editable NULL.
    Undecodable(String),
}

/// Soft upper bound on rows materialized by an arbitrary SQL `query` call.
/// When a result hits this limit, drivers set `QueryResult::truncated = true`.
/// Browse pagination via `fetch_rows` uses its caller-supplied `limit` and
/// is not capped here. Prefer streaming export ([`crate::export`]) for
/// large result sets instead of raising this further for GUI queries.
pub const MAX_QUERY_ROWS: usize = 1_000_000;
pub const MAX_QUERY_RESULT_CELLS: usize = 10_000_000;
pub const MAX_QUERY_RESULT_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug, Default)]
pub struct QueryResultBudget {
    rows: usize,
    cells: usize,
    bytes: usize,
}

impl QueryResultBudget {
    pub fn admit(&mut self, row: &[Value]) -> bool {
        let cells = self.cells.saturating_add(row.len());
        let row_bytes = row_size(row);
        let bytes = self.bytes.saturating_add(row_bytes);
        if self.rows >= MAX_QUERY_ROWS || cells > MAX_QUERY_RESULT_CELLS || bytes > MAX_QUERY_RESULT_BYTES {
            return false;
        }
        self.rows += 1;
        self.cells = cells;
        self.bytes = bytes;
        true
    }
}

fn value_size(value: &Value) -> usize {
    match value {
        Value::Text(text) | Value::Undecodable(text) => text.capacity(),
        Value::Bytes(bytes) => bytes.capacity(),
        Value::Json(value) => json_heap_size(value),
        _ => 0,
    }
}

fn row_size(row: &[Value]) -> usize {
    row.len()
        .saturating_mul(std::mem::size_of::<Value>())
        .saturating_add(std::mem::size_of::<Vec<Value>>())
        .saturating_add(
            row.iter()
                .fold(0usize, |total, value| total.saturating_add(value_size(value))),
        )
}

fn json_heap_size(value: &serde_json::Value) -> usize {
    match value {
        serde_json::Value::String(value) => value.capacity(),
        serde_json::Value::Array(values) => values
            .capacity()
            .saturating_mul(std::mem::size_of::<serde_json::Value>())
            .saturating_add(
                values
                    .iter()
                    .fold(0usize, |total, value| total.saturating_add(json_heap_size(value))),
            ),
        serde_json::Value::Object(values) => values.iter().fold(0usize, |total, (key, value)| {
            total
                .saturating_add(std::mem::size_of::<(String, serde_json::Value)>())
                .saturating_add(key.capacity())
                .saturating_add(json_heap_size(value))
        }),
        _ => 0,
    }
}

#[derive(Debug, Clone)]
pub struct QueryResult {
    pub columns: Vec<ColumnInfo>,
    pub rows: Vec<Vec<Value>>,
    pub truncated: bool,
}

/// Ordered row sets returned by one query execution. The truncation flag and
/// query budget apply to the whole batch, not independently to each set.
#[derive(Debug, Clone)]
pub struct QueryResultBatch {
    pub result_sets: Vec<QueryResult>,
    pub truncated: bool,
}

impl QueryResultBatch {
    pub fn single(result: QueryResult) -> Self {
        let truncated = result.truncated;
        Self {
            result_sets: vec![result],
            truncated,
        }
    }

    pub fn into_first(self) -> QueryResult {
        let first = self.result_sets.into_iter().next().unwrap_or(QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: self.truncated,
        });
        QueryResult {
            truncated: self.truncated || first.truncated,
            ..first
        }
    }

    pub fn retained_rows(&self) -> u64 {
        self.result_sets
            .iter()
            .map(|result_set| result_set.rows.len() as u64)
            .sum()
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ExecResult {
    pub rows_affected: u64,
}

#[cfg(test)]
mod tests {
    use super::{
        ColumnInfo, MAX_QUERY_RESULT_BYTES, MAX_QUERY_RESULT_CELLS, MAX_QUERY_ROWS, QualifiedTypeName, QueryResult,
        QueryResultBatch, QueryResultBudget, Value,
    };

    #[test]
    fn enum_catalog_metadata_does_not_change_column_info_wire_shape() {
        let column = ColumnInfo {
            name: "status".into(),
            data_type: "status_type".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: Some(QualifiedTypeName {
                schema: "app".into(),
                name: "status_type".into(),
            }),
            domain_type: None,
        };

        let wire = serde_json::to_value(&column).unwrap();
        assert!(wire.get("enum_type").is_none());
        let decoded: ColumnInfo = serde_json::from_value(wire).unwrap();
        assert_eq!(decoded.enum_type, None);
    }

    #[test]
    fn result_budget_caps_cells_and_dynamic_value_storage() {
        assert_eq!(MAX_QUERY_RESULT_BYTES, 67_108_864);
        let row = vec![Value::Text("x".into())];
        let mut byte_budget = QueryResultBudget {
            bytes: super::MAX_QUERY_RESULT_BYTES - super::row_size(&row),
            ..QueryResultBudget::default()
        };
        assert!(byte_budget.admit(&row));
        assert!(!byte_budget.admit(&row));

        let one_cell = [Value::Null];
        let mut exact_cell_budget = QueryResultBudget {
            cells: MAX_QUERY_RESULT_CELLS - 1,
            ..QueryResultBudget::default()
        };
        assert!(exact_cell_budget.admit(&one_cell));
        assert!(!exact_cell_budget.admit(&one_cell));
        let mut cell_budget = QueryResultBudget {
            cells: MAX_QUERY_RESULT_CELLS,
            ..QueryResultBudget::default()
        };
        assert!(!cell_budget.admit(&[Value::Null]));
        let mut row_budget = QueryResultBudget {
            rows: MAX_QUERY_ROWS - 1,
            ..QueryResultBudget::default()
        };
        assert!(row_budget.admit(&one_cell));
        assert!(!row_budget.admit(&one_cell));
    }

    #[test]
    fn result_budget_counts_dynamic_value_storage() {
        let text = Value::Text(String::with_capacity(32));
        let undecodable = Value::Undecodable(String::with_capacity(32));
        let bytes = Value::Bytes(vec![0; 32]);
        let json_string = serde_json::json!("a dynamically stored JSON string");
        let json_array = serde_json::json!(["a dynamically stored JSON array"]);
        let json_object = serde_json::json!({"key": "a dynamically stored JSON object"});

        for value in [&text, &undecodable, &bytes] {
            assert!(super::value_size(value) > 1);
        }
        for value in [&json_string, &json_array, &json_object] {
            assert!(super::json_heap_size(value) > 1);
            assert!(super::value_size(&Value::Json(value.clone())) > 1);
        }

        let empty_row = super::row_size(&[]);
        let one_cell = super::row_size(&[Value::Null]);
        assert!(empty_row > 1);
        assert!(one_cell > empty_row);
    }

    #[test]
    fn first_result_keeps_truncation_from_either_batch_or_result_set() {
        for (batch_truncated, result_truncated, expected) in [
            (true, false, true),
            (false, true, true),
            (true, true, true),
            (false, false, false),
        ] {
            let batch = QueryResultBatch {
                result_sets: vec![QueryResult {
                    columns: Vec::new(),
                    rows: Vec::new(),
                    truncated: result_truncated,
                }],
                truncated: batch_truncated,
            };

            assert_eq!(batch.into_first().truncated, expected);
        }
    }

    #[test]
    fn result_budget_counts_admitted_rows_to_the_limit() {
        let mut budget = QueryResultBudget {
            rows: MAX_QUERY_ROWS - 1,
            ..QueryResultBudget::default()
        };

        assert!(budget.admit(&[]));
        assert!(!budget.admit(&[]));
    }

    #[test]
    fn value_size_counts_owned_text_bytes_and_json_storage() {
        let text = String::with_capacity(32);
        let text_capacity = text.capacity();
        assert_eq!(super::value_size(&Value::Text(text)), text_capacity);
        let undecodable = String::from("wide");
        let undecodable_capacity = undecodable.capacity();
        assert_eq!(
            super::value_size(&Value::Undecodable(undecodable)),
            undecodable_capacity
        );

        let bytes = vec![0; 24];
        let byte_capacity = bytes.capacity();
        assert_eq!(super::value_size(&Value::Bytes(bytes)), byte_capacity);

        let json_string = String::with_capacity(48);
        let json_capacity = json_string.capacity();
        assert_eq!(
            super::value_size(&Value::Json(serde_json::Value::String(json_string))),
            json_capacity
        );
    }

    #[test]
    fn json_heap_size_counts_strings_nested_arrays_and_object_keys() {
        let string = String::with_capacity(20);
        let string_capacity = string.capacity();
        assert_eq!(
            super::json_heap_size(&serde_json::Value::String(string)),
            string_capacity
        );

        let nested = String::with_capacity(30);
        let nested_capacity = nested.capacity();
        let mut array = Vec::with_capacity(3);
        array.push(serde_json::Value::String(nested));
        let array_size = array.capacity() * std::mem::size_of::<serde_json::Value>() + nested_capacity;
        assert_eq!(super::json_heap_size(&serde_json::Value::Array(array)), array_size);

        let key = String::with_capacity(12);
        let key_capacity = key.capacity();
        let value = String::with_capacity(40);
        let value_capacity = value.capacity();
        let mut object = serde_json::Map::new();
        object.insert(key, serde_json::Value::String(value));
        let object_size = std::mem::size_of::<(String, serde_json::Value)>() + key_capacity + value_capacity;
        assert_eq!(super::json_heap_size(&serde_json::Value::Object(object)), object_size);
    }

    #[test]
    fn row_size_counts_container_and_owned_value_storage() {
        let text = String::with_capacity(64);
        let text_capacity = text.capacity();
        let row = [Value::Text(text)];

        assert_eq!(
            super::row_size(&row),
            std::mem::size_of::<Value>() + std::mem::size_of::<Vec<Value>>() + text_capacity
        );
    }

    #[test]
    fn retained_rows_sums_all_result_sets() {
        let batch = QueryResultBatch {
            result_sets: vec![
                QueryResult {
                    columns: Vec::new(),
                    rows: vec![Vec::new(), Vec::new()],
                    truncated: false,
                },
                QueryResult {
                    columns: Vec::new(),
                    rows: vec![Vec::new()],
                    truncated: false,
                },
            ],
            truncated: false,
        };

        assert_eq!(batch.retained_rows(), 3);
    }
}
