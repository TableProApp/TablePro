//! What SQLite's own catalogue says, and what the app makes of it.
//!
//! Every query reads a pragma through its table-valued function, so the
//! table and schema names travel as bound arguments rather than as SQL.
//! The only name spliced into SQL is a schema qualifying
//! `sqlite_schema`, which goes through the dialect's quoting.

mod dependents;
mod runtime_version;
mod sqlite_column_row;
mod table_definition;

use tablepro_core::column::{
    BoolStorage, CatalogType, ColumnDefault, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm,
    SqlExpression, SqlTypeExpr, TemporalZone, TextLength, TimeRange, classify_type_name,
};
use tablepro_core::sql_syntax::{LiteralToken, MAX_EXPRESSION_LEN, SqlGrammar, parse_expression};
use tablepro_core::value::{SqlDecimal, Value};

pub(crate) use dependents::{SchemaRow, select_dependents};
pub use runtime_version::{SQLITE_MIN_VERSION, SqliteVersion, check_runtime_version};
pub(crate) use sqlite_column_row::{SqliteColumnRow, TableFacts};
pub(crate) use table_definition::{InboundKeyRow, foreign_key_name, generated_expressions, inbound_foreign_keys};

/// The schema unqualified names resolve to.
pub(crate) const MAIN_SCHEMA: &str = "main";

/// `temp` belongs to the connection rather than the file, so another
/// connection never sees what one put there.
pub(crate) const DATABASE_LIST_SQL: &str = "SELECT name FROM pragma_database_list WHERE name <> 'temp' ORDER BY seq";

pub(crate) const TABLE_XINFO_SQL: &str = "SELECT cid, name, type, \"notnull\", dflt_value, pk, hidden \
     FROM pragma_table_xinfo(?1, ?2) ORDER BY cid";

/// `table_list` takes no schema argument, so the schema is a filter.
pub(crate) const TABLE_LIST_SQL: &str = "SELECT type, wr, strict FROM pragma_table_list(?1) WHERE schema = ?2";

pub(crate) const INDEX_LIST_SQL: &str =
    "SELECT name, \"unique\", origin, partial FROM pragma_index_list(?1, ?2) ORDER BY name";

pub(crate) const INDEX_XINFO_SQL: &str =
    "SELECT cid, name, \"desc\" FROM pragma_index_xinfo(?1, ?2) WHERE key = 1 ORDER BY seqno";

pub(crate) const FOREIGN_KEY_LIST_SQL: &str = "SELECT id, \"table\", \"from\", \"to\", on_update, on_delete \
     FROM pragma_foreign_key_list(?1, ?2) ORDER BY id, seq";

pub(crate) const FOREIGN_KEY_CHECK_SQL: &str = "SELECT \"table\", rowid, parent FROM pragma_foreign_key_check(?1, ?2)";

/// `sqlite_schema` of one schema, which has to be named in the FROM.
pub(crate) fn objects_sql(schema_sql: &str) -> String {
    format!(
        "SELECT name, type FROM {schema_sql}.sqlite_schema \
         WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite!_%' ESCAPE '!' ORDER BY name"
    )
}

pub(crate) fn object_sql(schema_sql: &str) -> String {
    format!("SELECT type, sql FROM {schema_sql}.sqlite_schema WHERE name = ?1 COLLATE NOCASE")
}

pub(crate) fn index_sql(schema_sql: &str) -> String {
    format!("SELECT sql FROM {schema_sql}.sqlite_schema WHERE type = 'index' AND name = ?1")
}

pub(crate) fn dependents_sql(schema_sql: &str) -> String {
    format!(
        "SELECT type, name, tbl_name, sql FROM {schema_sql}.sqlite_schema \
         WHERE type IN ('index', 'trigger', 'view') AND sql IS NOT NULL ORDER BY rowid"
    )
}

pub(crate) fn inbound_keys_sql(schema_sql: &str) -> String {
    format!(
        "SELECT m.name AS child, f.id AS id, f.\"from\" AS \"from\", f.\"to\" AS \"to\" \
         FROM {schema_sql}.sqlite_schema m, pragma_foreign_key_list(m.name, ?2) f \
         WHERE m.type = 'table' AND f.\"table\" = ?1 COLLATE NOCASE ORDER BY m.name, f.id, f.seq"
    )
}

/// `sqlite_sequence` exists only once some table was declared with
/// AUTOINCREMENT, so its presence is checked before it is read.
pub(crate) fn has_table_sql(schema_sql: &str) -> String {
    format!("SELECT count(*) FROM {schema_sql}.sqlite_schema WHERE type = 'table' AND name = ?1")
}

pub(crate) fn sequence_sql(schema_sql: &str) -> String {
    format!("SELECT count(*) FROM {schema_sql}.sqlite_sequence WHERE name = ?1")
}

/// The first number of a `sqlite_stat1` row is the row count ANALYZE
/// saw. A table without indexes has one row whose `idx` is NULL.
pub(crate) fn statistics_sql(schema_sql: &str) -> String {
    format!("SELECT stat FROM {schema_sql}.sqlite_stat1 WHERE tbl = ?1 ORDER BY idx IS NOT NULL LIMIT 1")
}

/// A column's type from its declaration.
///
/// SQLite stores what it is given whatever the declaration says, unless
/// the table is STRICT, so the declaration decides how a value is shown
/// and edited, never what the value is. The affinity rules of
/// datatype3 section 3.1 come first, in their order, so a type reads
/// the way SQLite itself reads it: `FLOATING POINT` is an integer.
pub(crate) fn declared_column_type(declared: &str, strict: bool) -> ColumnType {
    let declaration = SqlTypeExpr::from_catalog_text(declared);
    // ANY is the one STRICT type that keeps whatever it is given.
    let any = strict && declared.trim().eq_ignore_ascii_case("ANY");
    ColumnType {
        name: declared.to_owned(),
        kind: declared_kind(declared),
        catalog: Some(CatalogType {
            cast_target: declaration.clone(),
            declaration,
        }),
        dynamic_storage: !strict || any,
        read_form: ReadForm::Native,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Affinity {
    Integer,
    Text,
    Blob,
    Real,
    Numeric,
}

fn affinity(declared: &str) -> Affinity {
    let upper = declared.to_ascii_uppercase();
    if upper.contains("INT") {
        Affinity::Integer
    } else if ["CHAR", "CLOB", "TEXT"].iter().any(|word| upper.contains(word)) {
        Affinity::Text
    } else if upper.contains("BLOB") || upper.trim().is_empty() {
        Affinity::Blob
    } else if ["REAL", "FLOA", "DOUB"].iter().any(|word| upper.contains(word)) {
        Affinity::Real
    } else {
        Affinity::Numeric
    }
}

fn declared_kind(declared: &str) -> ColumnKind {
    match affinity(declared) {
        // SQLite keeps any 64-bit integer whatever width is declared.
        Affinity::Integer => integer(),
        // A declared length is not enforced, not even as a cap.
        Affinity::Text => ColumnKind::Text {
            length: TextLength::Unbounded,
        },
        // A column with no type holds anything, which is not the same
        // as holding bytes: shown as bytes it could not be edited.
        Affinity::Blob if declared.trim().is_empty() => ColumnKind::Other,
        Affinity::Blob => ColumnKind::Bytes {
            length: TextLength::Unbounded,
        },
        Affinity::Real => ColumnKind::Float(FloatWidth::F64),
        Affinity::Numeric => numeric_kind(declared),
    }
}

/// Within numeric affinity, the names that say how a value is meant:
/// BOOLEAN is 0 and 1, DATE and DATETIME are ISO text, DECIMAL is a
/// number with a scale. Anything else is shown as stored.
fn numeric_kind(declared: &str) -> ColumnKind {
    match classify_type_name(declared) {
        ColumnKind::Bool(_) => ColumnKind::Bool(BoolStorage::Integer),
        kind @ (ColumnKind::Decimal { .. }
        | ColumnKind::Date
        | ColumnKind::Time { .. }
        | ColumnKind::Timestamp { .. }
        | ColumnKind::Json { binary: false }) => kind,
        _ => ColumnKind::Other,
    }
}

fn integer() -> ColumnKind {
    ColumnKind::Integer(IntegerKind {
        width: IntegerWidth::W64,
        signed: true,
    })
}

/// The type of a result column, from the name sqlx gives its declared
/// type. `None` for an expression or a declaration sqlx does not name,
/// which only a row can resolve.
pub(crate) fn result_column_type(type_name: &str) -> Option<ColumnType> {
    let kind = match type_name {
        "INTEGER" => integer(),
        "REAL" => ColumnKind::Float(FloatWidth::F64),
        "TEXT" => ColumnKind::Text {
            length: TextLength::Unbounded,
        },
        "BLOB" => ColumnKind::Bytes {
            length: TextLength::Unbounded,
        },
        "BOOLEAN" => ColumnKind::Bool(BoolStorage::Integer),
        "DATE" => ColumnKind::Date,
        "TIME" => ColumnKind::Time {
            fractional_digits: None,
            with_offset: false,
            range: TimeRange::TimeOfDay,
        },
        "DATETIME" => ColumnKind::Timestamp {
            fractional_digits: None,
            zone: TemporalZone::Naive,
        },
        "NUMERIC" => ColumnKind::Decimal {
            precision: None,
            scale: None,
        },
        _ => return None,
    };
    Some(result_type(type_name, kind))
}

/// The type of a result column that has no declared type, from the
/// storage class of the value a row holds there.
pub(crate) fn storage_class_type(value: &Value) -> ColumnType {
    match value {
        Value::Int(_) => result_type("INTEGER", integer()),
        Value::Float64(_) => result_type("REAL", ColumnKind::Float(FloatWidth::F64)),
        Value::Text(_) => result_type(
            "TEXT",
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
        ),
        Value::Bytes(_) => result_type(
            "BLOB",
            ColumnKind::Bytes {
                length: TextLength::Unbounded,
            },
        ),
        _ => result_type("", ColumnKind::Other),
    }
}

/// A result column has no server spelling to splice, and its value can
/// be of any class whatever the column says.
fn result_type(name: &str, kind: ColumnKind) -> ColumnType {
    ColumnType {
        name: name.to_owned(),
        kind,
        catalog: None,
        dynamic_storage: true,
        read_form: ReadForm::Native,
    }
}

/// A column's DEFAULT, from the text `pragma_table_xinfo` reports.
///
/// A literal is kept as the value SQLite would store for it, so the
/// insert path binds exactly that: a quoted string stays text however
/// the column is declared, and a number stays an integer or a real.
/// Anything else, `CURRENT_TIMESTAMP` included, is left to the server.
pub(crate) fn classify_default(text: &str) -> ColumnDefault {
    let literal = parse_expression(SqlGrammar::Sqlite, text, MAX_EXPRESSION_LEN)
        .ok()
        .and_then(|parsed| parsed.literal)
        .and_then(literal_value);
    match literal {
        Some(value) => ColumnDefault::Literal(value),
        None => ColumnDefault::Expression(SqlExpression::from_catalog_text(text)),
    }
}

fn literal_value(token: LiteralToken) -> Option<Value> {
    match token {
        LiteralToken::Text(text) => Some(Value::Text(text)),
        LiteralToken::Number(number) => number_value(&number),
        // SQLite has no boolean storage class: TRUE is stored as 1.
        LiteralToken::Boolean(flag) => Some(Value::Int(i64::from(flag))),
        LiteralToken::Null => Some(Value::Null),
    }
}

/// SQLite reads a number literal as an integer when it has no fraction
/// and fits in 64 bits, and as a real otherwise.
fn number_value(number: &SqlDecimal) -> Option<Value> {
    if let Some((mantissa, 0)) = number.to_scaled_i128()
        && let Ok(integer) = i64::try_from(mantissa)
    {
        return Some(Value::Int(integer));
    }
    number.to_string().parse::<f64>().ok().map(Value::Float64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sqlite_affinity_rules_and_strict() {
        let cases = [
            ("INT", integer()),
            ("TINYINT", integer()),
            ("UNSIGNED BIG INT", integer()),
            ("FLOATING POINT", integer()),
            (
                "VARCHAR(255)",
                ColumnKind::Text {
                    length: TextLength::Unbounded,
                },
            ),
            (
                "NCHAR(55)",
                ColumnKind::Text {
                    length: TextLength::Unbounded,
                },
            ),
            (
                "CLOB",
                ColumnKind::Text {
                    length: TextLength::Unbounded,
                },
            ),
            (
                "BLOB",
                ColumnKind::Bytes {
                    length: TextLength::Unbounded,
                },
            ),
            ("", ColumnKind::Other),
            ("REAL", ColumnKind::Float(FloatWidth::F64)),
            ("DOUBLE PRECISION", ColumnKind::Float(FloatWidth::F64)),
            ("BOOLEAN", ColumnKind::Bool(BoolStorage::Integer)),
            ("DATE", ColumnKind::Date),
            (
                "DATETIME",
                ColumnKind::Timestamp {
                    fractional_digits: None,
                    zone: TemporalZone::Naive,
                },
            ),
            (
                "DECIMAL(10,5)",
                ColumnKind::Decimal {
                    precision: Some(10),
                    scale: Some(5),
                },
            ),
            ("STRING", ColumnKind::Other),
        ];
        for (declared, kind) in cases {
            assert_eq!(declared_column_type(declared, false).kind, kind, "{declared:?}");
        }

        assert!(declared_column_type("INTEGER", false).dynamic_storage);
        assert!(!declared_column_type("INTEGER", true).dynamic_storage);
        assert!(
            declared_column_type("ANY", true).dynamic_storage,
            "ANY keeps any class even in a STRICT table"
        );
    }

    #[test]
    fn a_declaration_is_kept_verbatim_for_ddl() {
        let column = declared_column_type("decimal(10, 2)", false);

        assert_eq!(column.name, "decimal(10, 2)");
        assert_eq!(
            column.catalog.map(|catalog| catalog.declaration.as_sql().to_owned()),
            Some("decimal(10, 2)".to_owned())
        );
    }

    #[test]
    fn classify_default_table() {
        let cases = [
            ("'pending'", ColumnDefault::Literal(Value::Text("pending".to_owned()))),
            ("'it''s'", ColumnDefault::Literal(Value::Text("it's".to_owned()))),
            ("0", ColumnDefault::Literal(Value::Int(0))),
            ("-5", ColumnDefault::Literal(Value::Int(-5))),
            ("1.50", ColumnDefault::Literal(Value::Float64(1.5))),
            ("(7)", ColumnDefault::Literal(Value::Int(7))),
            ("TRUE", ColumnDefault::Literal(Value::Int(1))),
            ("NULL", ColumnDefault::Literal(Value::Null)),
            ("'2024-1-5'", ColumnDefault::Literal(Value::Text("2024-1-5".to_owned()))),
            (
                "CURRENT_TIMESTAMP",
                ColumnDefault::Expression(SqlExpression::from_catalog_text("CURRENT_TIMESTAMP")),
            ),
            (
                "(strftime('%s', 'now'))",
                ColumnDefault::Expression(SqlExpression::from_catalog_text("(strftime('%s', 'now'))")),
            ),
        ];
        for (text, expected) in cases {
            assert_eq!(classify_default(text), expected, "{text}");
        }
    }

    #[test]
    fn a_result_column_without_a_declared_type_waits_for_a_row() {
        assert_eq!(result_column_type("NULL"), None);
        assert_eq!(
            result_column_type("BOOLEAN").map(|column| column.kind),
            Some(ColumnKind::Bool(BoolStorage::Integer))
        );
        assert_eq!(storage_class_type(&Value::Int(3)).kind, integer());
        assert_eq!(storage_class_type(&Value::Null).kind, ColumnKind::Other);
    }
}
