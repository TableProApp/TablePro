//! SQL Server's catalogue, classified into the app's column model.

mod cells;
mod mssql_column_row;
mod sql_server_type;
mod table_definition;

use tablepro_core::column::{
    BoolStorage, ColumnDefault, ColumnInfo, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm,
    ResultColumn, SqlExpression, TemporalZone, TextLength, TimeRange,
};
use tablepro_core::ddl::{
    CollationName, ColumnAttributes, ColumnDefinition, GeneratedColumn, GeneratedStorage, IdentityStyle,
};
use tablepro_core::edit::parse_literal_text;
use tablepro_core::sql_syntax::{LiteralToken, MAX_EXPRESSION_LEN, SqlGrammar, parse_expression};
use tablepro_core::value::Value;
use tiberius::{Column, ColumnType as TdsType};

pub(crate) use cells::Cells;
pub(crate) use mssql_column_row::{COLUMNS_SQL, MssqlColumnRow};
pub(crate) use sql_server_type::SqlServerType;
pub(crate) use table_definition::{INBOUND_FOREIGN_KEYS_SQL, PRIMARY_KEY_SQL, inbound_foreign_keys, primary_key};

/// A column as browse and the insert form see it.
pub(crate) fn column_info(row: &MssqlColumnRow) -> ColumnInfo {
    let (column_type, server_written) = row.sql_type.column_type();
    // An IDENTITY column has a seed and an increment, not a DEFAULT, so
    // the insert form leaves it to the server.
    let default = match row.identity {
        true => ColumnDefault::None,
        false => classify_default(row.default_definition.as_deref(), &column_type),
    };
    ColumnInfo {
        name: row.name.clone(),
        column_type,
        nullable: row.nullable,
        primary_key: row.primary_key,
        is_auto_increment: row.identity,
        is_generated: row.computed || server_written,
        default,
        comment: row.comment.clone(),
    }
}

/// A column as a structure change has to restate it.
pub(crate) fn column_definition(row: &MssqlColumnRow) -> ColumnDefinition {
    let generated = match (&row.computed_definition, row.computed) {
        (Some(expression), true) => Some(GeneratedColumn {
            expression: SqlExpression::from_catalog_text(expression.as_str()),
            storage: match row.persisted {
                true => GeneratedStorage::Stored,
                false => GeneratedStorage::Virtual,
            },
        }),
        _ => None,
    };
    let attributes = ColumnAttributes {
        collation: row.collation.as_deref().map(|name| CollationName::new(None, name)),
        generated,
        sparse: row.sparse,
        // The catalogue prints a quote in a padding string doubled, as it
        // would sit inside a literal, so `"X's"` reads back as `"X''s"`.
        masking_function: row
            .masking_function
            .as_deref()
            .map(|function| function.replace("''", "'")),
        identity: match row.identity {
            true => IdentityStyle::MssqlIdentity,
            false => IdentityStyle::None,
        },
        default_constraint_name: row.default_constraint.clone(),
        ..ColumnAttributes::default()
    };
    ColumnDefinition::new(column_info(row), attributes)
}

/// A DEFAULT as a value the insert path can bind where it is a literal,
/// and as the server's expression otherwise. The catalogue wraps every
/// definition in parentheses, `((0))` and `(N'x')` included, and the
/// parser peels them.
pub(crate) fn classify_default(text: Option<&str>, column_type: &ColumnType) -> ColumnDefault {
    let Some(text) = text.map(str::trim).filter(|text| !text.is_empty()) else {
        return ColumnDefault::None;
    };
    let expression = || ColumnDefault::Expression(SqlExpression::from_catalog_text(text));
    let Ok(parsed) = parse_expression(SqlGrammar::MsSql, text, MAX_EXPRESSION_LEN) else {
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

/// A result column, which TDS describes by its wire type alone.
pub(crate) fn result_column(column: &Column) -> ResultColumn {
    let tds = column.column_type();
    let integer = |width, signed| ColumnKind::Integer(IntegerKind { width, signed });
    let unbounded_text = ColumnKind::Text {
        length: TextLength::Unbounded,
    };
    let kind = match tds {
        TdsType::Bit | TdsType::Bitn => ColumnKind::Bool(BoolStorage::Native),
        TdsType::Int1 => integer(IntegerWidth::W8, false),
        TdsType::Int2 => integer(IntegerWidth::W16, true),
        TdsType::Int4 | TdsType::Intn => integer(IntegerWidth::W32, true),
        TdsType::Int8 => integer(IntegerWidth::W64, true),
        TdsType::Float4 => ColumnKind::Float(FloatWidth::F32),
        TdsType::Float8 | TdsType::Floatn => ColumnKind::Float(FloatWidth::F64),
        TdsType::Money | TdsType::Money4 => ColumnKind::Money { scale: Some(4) },
        TdsType::Decimaln | TdsType::Numericn => ColumnKind::Decimal {
            precision: None,
            scale: None,
        },
        TdsType::Daten => ColumnKind::Date,
        TdsType::Timen => ColumnKind::Time {
            fractional_digits: None,
            with_offset: false,
            range: TimeRange::TimeOfDay,
        },
        TdsType::Datetime | TdsType::Datetimen | TdsType::Datetime4 | TdsType::Datetime2 => ColumnKind::Timestamp {
            fractional_digits: None,
            zone: TemporalZone::Naive,
        },
        TdsType::DatetimeOffsetn => ColumnKind::Timestamp {
            fractional_digits: None,
            zone: TemporalZone::Offset,
        },
        TdsType::Guid => ColumnKind::Uuid,
        TdsType::BigChar
        | TdsType::BigVarChar
        | TdsType::NChar
        | TdsType::NVarchar
        | TdsType::Text
        | TdsType::NText => unbounded_text,
        // A CLR value such as geography arrives as its serialised bytes.
        TdsType::BigBinary | TdsType::BigVarBin | TdsType::Image | TdsType::Udt => ColumnKind::Bytes {
            length: TextLength::Unbounded,
        },
        TdsType::Xml => ColumnKind::Xml,
        TdsType::SSVariant => ColumnKind::Variant,
        TdsType::Null => ColumnKind::Other,
    };
    ResultColumn::new(
        column.name(),
        ColumnType {
            name: type_label(tds).to_owned(),
            kind,
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        },
    )
}

/// The SQL name of a wire type.
pub(crate) fn type_label(tds: TdsType) -> &'static str {
    match tds {
        TdsType::Null => "null",
        TdsType::Bit | TdsType::Bitn => "bit",
        TdsType::Int1 => "tinyint",
        TdsType::Int2 => "smallint",
        TdsType::Int4 | TdsType::Intn => "int",
        TdsType::Int8 => "bigint",
        TdsType::Float4 => "real",
        TdsType::Float8 | TdsType::Floatn => "float",
        TdsType::Decimaln => "decimal",
        TdsType::Numericn => "numeric",
        TdsType::Money => "money",
        TdsType::Money4 => "smallmoney",
        TdsType::Datetime | TdsType::Datetimen => "datetime",
        TdsType::Datetime4 => "smalldatetime",
        TdsType::Datetime2 => "datetime2",
        TdsType::DatetimeOffsetn => "datetimeoffset",
        TdsType::Daten => "date",
        TdsType::Timen => "time",
        TdsType::Guid => "uniqueidentifier",
        TdsType::BigChar => "char",
        TdsType::BigVarChar => "varchar",
        TdsType::NChar => "nchar",
        TdsType::NVarchar => "nvarchar",
        TdsType::Text => "text",
        TdsType::NText => "ntext",
        TdsType::BigBinary => "binary",
        TdsType::BigVarBin => "varbinary",
        TdsType::Image => "image",
        TdsType::Xml => "xml",
        TdsType::Udt => "udt",
        TdsType::SSVariant => "sql_variant",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn integer() -> ColumnType {
        SqlServerType::parse("int").column_type().0
    }

    #[test]
    fn classify_default_table() {
        let text = SqlServerType::parse("nvarchar(20)").column_type().0;
        let flag = SqlServerType::parse("bit").column_type().0;

        assert_eq!(
            classify_default(Some("((0))"), &integer()),
            ColumnDefault::Literal(Value::Int(0))
        );
        assert_eq!(
            classify_default(Some("((-1))"), &integer()),
            ColumnDefault::Literal(Value::Int(-1))
        );
        assert_eq!(
            classify_default(Some("(N'it''s')"), &text),
            ColumnDefault::Literal(Value::Text("it's".to_owned()))
        );
        assert_eq!(
            classify_default(Some("('pending')"), &text),
            ColumnDefault::Literal(Value::Text("pending".to_owned()))
        );
        assert!(matches!(
            classify_default(Some("(getdate())"), &integer()),
            ColumnDefault::Expression(expression) if expression.as_sql() == "(getdate())"
        ));
        assert!(matches!(
            classify_default(Some("((1))"), &flag),
            ColumnDefault::Literal(_) | ColumnDefault::Expression(_)
        ));
        assert_eq!(classify_default(Some("(NULL)"), &text), ColumnDefault::None);
        assert_eq!(classify_default(None, &text), ColumnDefault::None);
    }

    #[test]
    fn a_mask_reads_back_as_its_function_was_written() {
        let mut values = vec![Value::Null; 23];
        values[0] = Value::Text("email".to_owned());
        values[1] = Value::Text("varchar".to_owned());
        values[22] = Value::Text(r#"partial(1, "X''s", 2)"#.to_owned());

        let row = MssqlColumnRow::from_values(&values).expect("a row");

        assert_eq!(
            column_definition(&row).attributes.masking_function.as_deref(),
            Some(r#"partial(1, "X's", 2)"#)
        );
    }

    #[test]
    fn an_unbalanced_definition_stays_the_servers_expression() {
        assert!(matches!(
            classify_default(Some("(a)+(b)"), &integer()),
            ColumnDefault::Expression(expression) if expression.as_sql() == "(a)+(b)"
        ));
    }

    #[test]
    fn column_type_names_are_human_readable() {
        assert_eq!(type_label(TdsType::Int4), "int");
        assert_eq!(type_label(TdsType::NVarchar), "nvarchar");
        assert_eq!(type_label(TdsType::Datetime2), "datetime2");
        assert_eq!(type_label(TdsType::Guid), "uniqueidentifier");
        assert_eq!(type_label(TdsType::Bit), "bit");
    }

    #[test]
    fn editor_money_is_money_of_scale_4() {
        let money = result_column(&Column::new("price".to_owned(), TdsType::Money));

        assert_eq!(money.column_type.name, "money");
        assert_eq!(money.column_type.kind, ColumnKind::Money { scale: Some(4) });
        assert_eq!(
            result_column(&Column::new("v".to_owned(), TdsType::SSVariant))
                .column_type
                .kind,
            ColumnKind::Variant
        );
    }
}
