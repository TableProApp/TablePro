//! Columns classified from PostgreSQL's own catalogue rather than from
//! type names.

mod pg_column_row;
mod pg_typmod;
mod table_definition;
mod type_facts;

pub(crate) use pg_column_row::{COLUMNS_SQL, PgColumnRow};
pub(crate) use table_definition::{INBOUND_FOREIGN_KEYS_SQL, PRIMARY_KEY_NAME_SQL, inbound_foreign_key};
pub(crate) use type_facts::TypeFacts;

use tablepro_core::column::{
    CatalogType, ColumnDefault, ColumnInfo, ColumnType, ResultColumn, SqlExpression, SqlTypeExpr, has_dynamic_storage,
};
use tablepro_core::ddl::{
    CollationName, ColumnAttributes, ColumnDefinition, GeneratedColumn, GeneratedStorage, IdentityStyle,
};
use tablepro_core::edit::parse_literal_text;
use tablepro_core::sql_syntax::{LiteralToken, MAX_EXPRESSION_LEN, SqlGrammar, parse_expression};
use tablepro_core::value::Value;
use tokio_postgres::Column;

/// A column of a result set, typed from the OID and modifier the server
/// sent with it.
pub(crate) fn result_column(column: &Column) -> ResultColumn {
    let facts = TypeFacts::of_type(column.type_(), column.type_modifier());
    let kind = facts.kind();
    ResultColumn::new(
        column.name(),
        ColumnType {
            name: facts.name.clone(),
            dynamic_storage: has_dynamic_storage(&kind),
            kind,
            catalog: None,
            read_form: facts.read_form(),
        },
    )
}

/// A column the simple protocol returned, which carries only its name
/// until tokio-postgres exposes the type OID there.
pub(crate) fn text_column(name: &str) -> ResultColumn {
    ResultColumn::new(name, ColumnType::untyped_text("text"))
}

pub(crate) fn column_info(row: &PgColumnRow) -> ColumnInfo {
    let kind = row.facts.kind();
    let column_type = ColumnType {
        name: row.declaration.clone(),
        dynamic_storage: has_dynamic_storage(&kind),
        kind,
        catalog: Some(CatalogType {
            declaration: SqlTypeExpr::from_catalog_text(row.declaration.as_str()),
            cast_target: SqlTypeExpr::from_catalog_text(row.cast_target.as_str()),
        }),
        read_form: row.facts.read_form(),
    };
    let identity = identity_style(row);
    let generated = !row.generated.is_empty();
    let default = match (identity, generated) {
        (IdentityStyle::None, false) => classify_default(row.default_expression.as_deref(), &column_type),
        _ => ColumnDefault::None,
    };
    ColumnInfo {
        name: row.name.clone(),
        column_type,
        nullable: !row.not_null,
        primary_key: row.primary_key,
        is_auto_increment: identity != IdentityStyle::None,
        is_generated: generated,
        default,
        comment: row.comment.clone(),
    }
}

pub(crate) fn column_definition(row: &PgColumnRow) -> ColumnDefinition {
    let generated = match row.generated.as_str() {
        "s" => Some(GeneratedStorage::Stored),
        "v" => Some(GeneratedStorage::Virtual),
        _ => None,
    };
    let attributes = ColumnAttributes {
        collation: row
            .collation
            .as_ref()
            .map(|(schema, name)| CollationName::new(schema.clone(), name.clone())),
        generated: generated.and_then(|storage| {
            row.default_expression.as_ref().map(|expression| GeneratedColumn {
                expression: SqlExpression::from_catalog_text(expression.as_str()),
                storage,
            })
        }),
        identity: identity_style(row),
        ..ColumnAttributes::default()
    };
    ColumnDefinition::new(column_info(row), attributes)
}

fn identity_style(row: &PgColumnRow) -> IdentityStyle {
    match row.identity.as_str() {
        "a" => IdentityStyle::GeneratedAlways,
        "d" => IdentityStyle::GeneratedByDefault,
        _ if row
            .default_expression
            .as_deref()
            .is_some_and(|expression| expression.trim_start().starts_with("nextval(")) =>
        {
            IdentityStyle::SequenceDefault
        }
        _ => IdentityStyle::None,
    }
}

/// A DEFAULT as a value the insert path can bind where it is a literal,
/// and as the server's expression otherwise.
pub(crate) fn classify_default(text: Option<&str>, column_type: &ColumnType) -> ColumnDefault {
    let Some(text) = text.map(str::trim).filter(|text| !text.is_empty()) else {
        return ColumnDefault::None;
    };
    let expression = || ColumnDefault::Expression(SqlExpression::from_catalog_text(text));
    let Ok(parsed) = parse_expression(SqlGrammar::PostgreSql, text, MAX_EXPRESSION_LEN) else {
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
    use tablepro_core::column::{ColumnKind, IntegerKind, IntegerWidth, ReadForm, TextLength};

    use super::*;

    fn column_type(kind: ColumnKind) -> ColumnType {
        ColumnType {
            name: String::new(),
            dynamic_storage: false,
            kind,
            catalog: None,
            read_form: ReadForm::Native,
        }
    }

    #[test]
    fn classify_default_table() {
        let integer = column_type(ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed: true,
        }));
        let text = column_type(ColumnKind::Text {
            length: TextLength::Unbounded,
        });
        let date = column_type(ColumnKind::Date);

        assert_eq!(
            classify_default(Some("42"), &integer),
            ColumnDefault::Literal(Value::Int(42))
        );
        assert_eq!(
            classify_default(Some("'-1'::integer"), &integer),
            ColumnDefault::Literal(Value::Int(-1))
        );
        assert_eq!(
            classify_default(Some("'it''s'::text"), &text),
            ColumnDefault::Literal(Value::Text("it's".to_owned()))
        );
        assert!(matches!(
            classify_default(Some("'2024-01-01'::date"), &date),
            ColumnDefault::Literal(Value::Date(_))
        ));
        assert!(matches!(
            classify_default(Some("now()"), &date),
            ColumnDefault::Expression(expression) if expression.as_sql() == "now()"
        ));
        assert_eq!(classify_default(Some("NULL::text"), &text), ColumnDefault::None);
        assert_eq!(classify_default(None, &text), ColumnDefault::None);
    }
}
