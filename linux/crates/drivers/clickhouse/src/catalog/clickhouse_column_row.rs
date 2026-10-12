use tablepro_core::column::{ColumnDefault, ColumnInfo, ColumnType, SqlExpression};
use tablepro_core::ddl::{ColumnAttributes, ColumnKeyRoles, GeneratedColumn, GeneratedStorage, UnmodeledAttribute};
use tablepro_core::edit::parse_literal_text;
use tablepro_core::sql_syntax::{LiteralToken, MAX_EXPRESSION_LEN, SqlGrammar, parse_expression};
use tablepro_core::{DriverError, Value};

use crate::clickhouse_type::ClickHouseType;
use crate::result_reader::CatalogRow;

/// The columns `ClickHouseColumnRow::read` expects, in order.
pub(crate) const COLUMN_SELECT: &str = "SELECT name, type, default_kind, default_expression, comment, \
     is_in_primary_key, is_in_sorting_key, is_in_partition_key \
     FROM system.columns WHERE database = {db:String} AND table = {tbl:String} ORDER BY position";

/// One row of `system.columns`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ClickHouseColumnRow {
    pub(crate) name: String,
    pub(crate) type_text: String,
    pub(crate) default_kind: String,
    pub(crate) default_expression: String,
    pub(crate) comment: String,
    pub(crate) in_primary_key: bool,
    pub(crate) in_sorting_key: bool,
    pub(crate) in_partition_key: bool,
}

impl ClickHouseColumnRow {
    pub(crate) fn read(row: &[Value]) -> Result<Self, DriverError> {
        let row = CatalogRow(row);
        Ok(Self {
            name: row.text(0)?,
            type_text: row.text(1)?,
            default_kind: row.text(2)?,
            default_expression: row.text(3)?,
            comment: row.text(4)?,
            in_primary_key: row.flag(5)?,
            in_sorting_key: row.flag(6)?,
            in_partition_key: row.flag(7)?,
        })
    }

    /// MATERIALIZED and ALIAS are computed by the server, and an
    /// EPHEMERAL column is never stored, so none of them is written.
    fn is_generated(&self) -> bool {
        matches!(self.default_kind.as_str(), "MATERIALIZED" | "ALIAS" | "EPHEMERAL")
    }

    pub(crate) fn info(&self) -> ColumnInfo {
        let parsed = ClickHouseType::parse(&self.type_text);
        let default = match self.default_kind.as_str() {
            "DEFAULT" => classify_default(&self.default_expression, &parsed.column_type),
            _ => ColumnDefault::None,
        };
        ColumnInfo {
            name: self.name.clone(),
            nullable: parsed.nullable,
            column_type: parsed.column_type,
            primary_key: self.in_primary_key,
            is_auto_increment: false,
            is_generated: self.is_generated(),
            default,
            // An uncommented column comes back as the empty string, so
            // the engine cannot tell "no comment" from an empty one.
            comment: (!self.comment.is_empty()).then(|| self.comment.clone()),
        }
    }

    pub(crate) fn attributes(&self) -> ColumnAttributes {
        let expression = || SqlExpression::from_catalog_text(self.default_expression.as_str());
        let generated = match self.default_kind.as_str() {
            "MATERIALIZED" => Some(GeneratedColumn {
                expression: expression(),
                storage: GeneratedStorage::Stored,
            }),
            "ALIAS" => Some(GeneratedColumn {
                expression: expression(),
                storage: GeneratedStorage::Virtual,
            }),
            _ => None,
        };
        let unmodeled = match self.default_kind.as_str() {
            "EPHEMERAL" => vec![UnmodeledAttribute::new("EPHEMERAL")],
            _ => Vec::new(),
        };
        ColumnAttributes {
            generated,
            key_roles: ColumnKeyRoles {
                sorting_key: self.in_sorting_key,
                partition_key: self.in_partition_key,
            },
            unmodeled,
            ..ColumnAttributes::default()
        }
    }
}

/// A DEFAULT as a value the insert path can bind where it is a literal,
/// and as the server's expression otherwise.
fn classify_default(text: &str, column_type: &ColumnType) -> ColumnDefault {
    let text = text.trim();
    if text.is_empty() {
        return ColumnDefault::None;
    }
    let expression = || ColumnDefault::Expression(SqlExpression::from_catalog_text(text));
    let Ok(parsed) = parse_expression(SqlGrammar::ClickHouse, text, MAX_EXPRESSION_LEN) else {
        return expression();
    };
    let literal_text = match parsed.literal {
        None => return expression(),
        Some(LiteralToken::Null) => return ColumnDefault::None,
        Some(LiteralToken::Text(text)) => text,
        Some(LiteralToken::Number(number)) => number.to_string(),
        Some(LiteralToken::Boolean(flag)) => flag.to_string(),
    };
    match parse_literal_text(&literal_text, column_type) {
        Ok(Value::Null) | Err(_) => expression(),
        Ok(value) => ColumnDefault::Literal(value),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnKind, TextLength};

    use super::*;

    fn row(name: &str, type_text: &str, kind: &str, expression: &str) -> ClickHouseColumnRow {
        ClickHouseColumnRow {
            name: name.to_owned(),
            type_text: type_text.to_owned(),
            default_kind: kind.to_owned(),
            default_expression: expression.to_owned(),
            comment: String::new(),
            in_primary_key: false,
            in_sorting_key: true,
            in_partition_key: false,
        }
    }

    #[test]
    fn classify_default_table() {
        let default = |type_text: &str, expression: &str| row("c", type_text, "DEFAULT", expression).info().default;

        assert_eq!(default("UInt8", "42"), ColumnDefault::Literal(Value::Int(42)));
        assert_eq!(default("Int32", "-1"), ColumnDefault::Literal(Value::Int(-1)));
        assert_eq!(
            default("String", "'it\\'s'"),
            ColumnDefault::Literal(Value::Text("it's".to_owned()))
        );
        assert_eq!(
            default("DateTime", "now()"),
            ColumnDefault::Expression(SqlExpression::from_catalog_text("now()"))
        );
        assert_eq!(default("Nullable(String)", "NULL"), ColumnDefault::None);
        assert_eq!(default("String", ""), ColumnDefault::None);
    }

    #[test]
    fn defaults_and_generated_columns_follow_default_kind() {
        let plain = row("note", "Nullable(String)", "DEFAULT", "'x'").info();
        assert!(plain.nullable);
        assert_eq!(
            plain.column_type.kind,
            ColumnKind::Text {
                length: TextLength::Unbounded
            }
        );
        assert_eq!(plain.default, ColumnDefault::Literal(Value::Text("x".to_owned())));
        assert!(!plain.is_generated);
        assert_eq!(plain.comment, None);

        let materialized = row("total", "UInt64", "MATERIALIZED", "a + b");
        assert!(materialized.info().is_generated);
        assert_eq!(materialized.info().default, ColumnDefault::None);
        assert_eq!(
            materialized.attributes().generated.map(|generated| generated.storage),
            Some(GeneratedStorage::Stored)
        );
        assert!(materialized.attributes().key_roles.sorting_key);

        let ephemeral = row("raw", "String", "EPHEMERAL", "");
        assert!(ephemeral.info().is_generated);
        assert_eq!(
            ephemeral.attributes().unmodeled,
            vec![UnmodeledAttribute::new("EPHEMERAL")]
        );
    }
}
