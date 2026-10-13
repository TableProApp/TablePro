//! Columns classified from MySQL's structured catalogue rather than from
//! type names.

mod catalog_cells;
mod column_type_scan_error;
mod escaped_expression;
mod mysql_column_row;
mod mysql_column_type;
mod mysql_extra;
mod table_definition;

pub(crate) use catalog_cells::CatalogCells;
pub(crate) use mysql_column_row::{MySqlColumnRow, columns_sql};
pub(crate) use mysql_extra::{ExtraGenerated, MySqlExtra};
pub(crate) use table_definition::{
    COLUMN_ENGINE_ATTRIBUTES_SQL, ColumnCheck, INBOUND_FOREIGN_KEYS_SQL, ListedSrid, MARIADB_COLUMN_CHECKS_SQL,
    MARIADB_GEOMETRY_SRIDS_SQL, column_checks, geometry_srids, inbound_foreign_keys, place_column_checks,
    printed_names,
};

use sqlx::mysql::{MySql, MySqlColumn};
use sqlx::{Column as _, Type, TypeInfo as _};
use tablepro_core::column::{
    BoolStorage, CatalogType, ColumnDefault, ColumnInfo, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth,
    ReadForm, ResultColumn, SqlExpression, SqlTypeExpr, TemporalZone, TextLength, TimeRange, has_dynamic_storage,
};
use tablepro_core::ddl::{
    CollationName, ColumnAttributes, ColumnDefinition, ColumnVisibility, GeneratedColumn, GeneratedStorage,
    IdentityStyle, UnmodeledAttribute,
};
use tablepro_core::edit::parse_literal_text;
use tablepro_core::sql_syntax::{
    LiteralToken, MAX_EXPRESSION_LEN, MAX_TYPE_LEN, SqlGrammar, TypeShape, parse_expression, parse_type,
};
use tablepro_core::value::Value;

use crate::flavour::MySqlFlavour;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use escaped_expression::unescape_expression;
use mysql_column_type::scan;

/// The catalogue's facts that decide a kind, apart from the rest of the
/// row so a draft type can be classified the same way.
#[derive(Debug, Clone, Default)]
pub(crate) struct TypeFacts<'a> {
    pub data_type: &'a str,
    pub column_type: &'a str,
    pub numeric_precision: Option<u64>,
    pub numeric_scale: Option<u64>,
    pub datetime_precision: Option<u64>,
    pub character_maximum_length: Option<u64>,
    /// `None` is the `binary` charset, which holds bytes.
    pub has_character_set: bool,
}

impl<'a> TypeFacts<'a> {
    fn of(row: &'a MySqlColumnRow) -> Self {
        Self {
            data_type: &row.data_type,
            column_type: &row.column_type,
            numeric_precision: row.numeric_precision,
            numeric_scale: row.numeric_scale,
            datetime_precision: row.datetime_precision,
            character_maximum_length: row.character_maximum_length,
            has_character_set: row.character_set.is_some(),
        }
    }
}

/// What a column holds. A COLUMN_TYPE that does not scan, or a type this
/// build does not know, is `Other` read as the server's text, never a
/// guess.
pub(crate) fn classify(facts: &TypeFacts<'_>) -> ColumnKind {
    let Ok(scanned) = scan(facts.data_type, facts.column_type) else {
        return ColumnKind::Other;
    };
    let integer = |width| {
        ColumnKind::Integer(IntegerKind {
            width,
            signed: !scanned.unsigned,
        })
    };
    let length = |make: fn(u32) -> TextLength| {
        facts
            .character_maximum_length
            .map_or(TextLength::Unbounded, |length| make(saturating_u32(length)))
    };
    let textual = |length: TextLength| match facts.has_character_set {
        true => ColumnKind::Text { length },
        false => ColumnKind::Bytes { length },
    };
    let fraction = facts
        .datetime_precision
        .map(|digits| u8::try_from(digits).unwrap_or(u8::MAX));
    match facts.data_type.to_ascii_lowercase().as_str() {
        "tinyint" if scanned.args.as_deref() == Some("1") => ColumnKind::Bool(BoolStorage::Integer),
        "tinyint" => integer(IntegerWidth::W8),
        "smallint" => integer(IntegerWidth::W16),
        "mediumint" => integer(IntegerWidth::W24),
        "int" | "integer" => integer(IntegerWidth::W32),
        "bigint" => integer(IntegerWidth::W64),
        // An unsigned DECIMAL keeps the modifier only in its declaration:
        // the server enforces the range.
        "decimal" | "numeric" | "fixed" => ColumnKind::Decimal {
            precision: facts.numeric_precision.map(saturating_u32),
            scale: facts.numeric_scale.map(saturating_u32),
        },
        "float" => ColumnKind::Float(FloatWidth::F32),
        "double" | "real" | "double precision" => ColumnKind::Float(FloatWidth::F64),
        "year" => ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W16,
            signed: false,
        }),
        "bit" => ColumnKind::BitString {
            length: facts.numeric_precision.map(saturating_u32),
            varying: false,
        },
        "geometry" | "point" | "linestring" | "polygon" | "multipoint" | "multilinestring" | "multipolygon"
        | "geometrycollection" | "geomcollection" => ColumnKind::Spatial,
        "char" => textual(length(TextLength::Fixed)),
        "varchar" => textual(length(TextLength::Varying)),
        "tinytext" | "text" | "mediumtext" | "longtext" => textual(TextLength::Unbounded),
        "binary" => ColumnKind::Bytes {
            length: length(TextLength::Fixed),
        },
        "varbinary" => ColumnKind::Bytes {
            length: length(TextLength::Varying),
        },
        "tinyblob" | "blob" | "mediumblob" | "longblob" => ColumnKind::Bytes {
            length: TextLength::Unbounded,
        },
        "enum" | "set" => labels(facts.column_type).unwrap_or(ColumnKind::Other),
        "date" => ColumnKind::Date,
        "time" => ColumnKind::Time {
            fractional_digits: fraction,
            with_offset: false,
            range: TimeRange::Duration,
        },
        "datetime" => ColumnKind::Timestamp {
            fractional_digits: fraction,
            zone: TemporalZone::Naive,
        },
        // Workspace sessions read TIMESTAMP in UTC, so it is an instant.
        "timestamp" => ColumnKind::Timestamp {
            fractional_digits: fraction,
            zone: TemporalZone::Offset,
        },
        // MySQL normalises a document as it stores it, as jsonb does.
        "json" => ColumnKind::Json { binary: true },
        _ => ColumnKind::Other,
    }
}

/// ENUM and SET members through sqlparser's MySQL dialect, which
/// unescapes `''` and backslashes. COLUMN_TYPE never carries modifiers
/// on these.
fn labels(column_type: &str) -> Option<ColumnKind> {
    match parse_type(SqlGrammar::MySql, column_type, MAX_TYPE_LEN).ok()?.shape {
        TypeShape::Enum { members } => Some(ColumnKind::Enum {
            labels: members,
            multiple: false,
        }),
        TypeShape::Set { members } => Some(ColumnKind::Enum {
            labels: members,
            multiple: true,
        }),
        _ => None,
    }
}

fn saturating_u32(value: u64) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

pub(crate) fn column_type(facts: &TypeFacts<'_>) -> ColumnType {
    let kind = classify(facts);
    let read_form = match kind {
        ColumnKind::Other => ReadForm::ServerText,
        _ => ReadForm::Native,
    };
    ColumnType {
        name: facts.column_type.to_owned(),
        dynamic_storage: has_dynamic_storage(&kind),
        kind,
        catalog: Some(CatalogType {
            declaration: SqlTypeExpr::from_catalog_text(facts.column_type),
            cast_target: SqlTypeExpr::from_catalog_text(facts.data_type),
        }),
        read_form,
    }
}

pub(crate) fn column_info(row: &MySqlColumnRow, flavour: MySqlFlavour) -> ColumnInfo {
    let column_type = column_type(&TypeFacts::of(row));
    let extra = MySqlExtra::parse(&row.extra);
    let generated = extra.generated.is_some() || row.generation_expression.is_some();
    let default = match generated {
        true => ColumnDefault::None,
        false => classify_default(row.default.as_deref(), &column_type, &extra, flavour),
    };
    ColumnInfo {
        name: row.name.clone(),
        column_type,
        nullable: row.nullable,
        primary_key: row.column_key == "PRI",
        is_auto_increment: extra.auto_increment,
        is_generated: generated,
        default,
        comment: row.comment.clone(),
    }
}

/// The column with everything the structure tab edits. `unmodeled` adds
/// what the table's own catalogue rows said about it.
pub(crate) fn column_definition(
    row: &MySqlColumnRow,
    flavour: MySqlFlavour,
    unmodeled: Vec<UnmodeledAttribute>,
) -> ColumnDefinition {
    let extra = MySqlExtra::parse(&row.extra);
    let generated = extra.generated.map(|storage| match storage {
        ExtraGenerated::Virtual => GeneratedStorage::Virtual,
        ExtraGenerated::Stored | ExtraGenerated::Persistent => GeneratedStorage::Stored,
    });
    let mut all_unmodeled: Vec<UnmodeledAttribute> = extra.unmodeled.iter().map(UnmodeledAttribute::new).collect();
    all_unmodeled.extend(unmodeled);
    let attributes = ColumnAttributes {
        collation: row
            .collation
            .as_ref()
            .map(|name| CollationName::new(None, name.clone())),
        character_set: row.character_set.clone(),
        on_update: extra
            .on_update
            .as_ref()
            .map(|expression| SqlExpression::from_catalog_text(expression.as_str())),
        generated: generated.and_then(|storage| {
            row.generation_expression.as_deref().map(|expression| GeneratedColumn {
                expression: catalog_expression(expression, flavour),
                storage,
            })
        }),
        visibility: match extra.invisible {
            true => ColumnVisibility::Invisible,
            false => ColumnVisibility::Visible,
        },
        spatial_reference: row.srs_id.and_then(|srid| u32::try_from(srid).ok()),
        identity: match extra.auto_increment {
            true => IdentityStyle::AutoIncrementKeyword,
            false => IdentityStyle::None,
        },
        unmodeled: all_unmodeled,
        ..ColumnAttributes::default()
    };
    ColumnDefinition::new(column_info(row, flavour), attributes)
}

/// An expression from `information_schema.COLUMNS` as SQL a statement
/// can splice.
fn catalog_expression(listed: &str, flavour: MySqlFlavour) -> SqlExpression {
    match flavour {
        MySqlFlavour::MySql => SqlExpression::from_catalog_text(unescape_expression(listed)),
        MySqlFlavour::MariaDb => SqlExpression::from_catalog_text(listed),
    }
}

/// A DEFAULT as a value the insert path can bind where it is a literal,
/// and as the server's expression otherwise.
///
/// MySQL 8 lists a literal default as its bare text and marks an
/// expression with DEFAULT_GENERATED. MariaDB quotes a string literal
/// and writes NULL for no default, so the quoting is what decides.
pub(crate) fn classify_default(
    text: Option<&str>,
    column_type: &ColumnType,
    extra: &MySqlExtra,
    flavour: MySqlFlavour,
) -> ColumnDefault {
    let Some(text) = text else {
        return ColumnDefault::None;
    };
    let expression = || ColumnDefault::Expression(SqlExpression::from_catalog_text(text));
    match flavour {
        MySqlFlavour::MySql if extra.default_generated => ColumnDefault::Expression(catalog_expression(text, flavour)),
        MySqlFlavour::MySql => match &column_type.kind {
            // The text is the value, spaces and all, and an empty one is
            // the empty string rather than no default.
            ColumnKind::Text { .. } | ColumnKind::Enum { .. } => ColumnDefault::Literal(Value::Text(text.to_owned())),
            _ => literal(text.trim(), column_type).unwrap_or_else(expression),
        },
        MySqlFlavour::MariaDb => {
            if text.eq_ignore_ascii_case("NULL") {
                return ColumnDefault::None;
            }
            let Ok(parsed) = parse_expression(SqlGrammar::MySql, text, MAX_EXPRESSION_LEN) else {
                return expression();
            };
            let literal_text = match parsed.literal {
                None => return expression(),
                Some(LiteralToken::Null) => return ColumnDefault::None,
                Some(LiteralToken::Text(text)) => text,
                Some(LiteralToken::Number(number)) => number.to_string(),
                Some(LiteralToken::Boolean(flag)) => flag.to_string(),
            };
            match &column_type.kind {
                ColumnKind::Text { .. } | ColumnKind::Enum { .. } => ColumnDefault::Literal(Value::Text(literal_text)),
                _ => literal(&literal_text, column_type).unwrap_or_else(expression),
            }
        }
    }
}

fn literal(text: &str, column_type: &ColumnType) -> Option<ColumnDefault> {
    match parse_literal_text(text, column_type) {
        Ok(Value::Null) | Err(_) => None,
        Ok(value) => Some(ColumnDefault::Literal(value)),
    }
}

/// A column of a result set, typed from what the server sent with it.
/// It has no catalogue entry, so nothing splices it into SQL.
pub(crate) fn result_column(column: &MySqlColumn, timestamps: MySqlTimestampMode) -> ResultColumn {
    let type_info = column.type_info();
    let name = type_info.name();
    let signed = !<u64 as Type<MySql>>::compatible(type_info);
    let integer = |width| ColumnKind::Integer(IntegerKind { width, signed });
    let kind = match name.trim_end_matches(" UNSIGNED") {
        "BOOLEAN" => ColumnKind::Bool(BoolStorage::Integer),
        "TINYINT" => integer(IntegerWidth::W8),
        "SMALLINT" => integer(IntegerWidth::W16),
        "MEDIUMINT" => integer(IntegerWidth::W24),
        "INT" => integer(IntegerWidth::W32),
        "BIGINT" => integer(IntegerWidth::W64),
        "YEAR" => ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W16,
            signed: false,
        }),
        "FLOAT" => ColumnKind::Float(FloatWidth::F32),
        "DOUBLE" => ColumnKind::Float(FloatWidth::F64),
        "DECIMAL" => ColumnKind::Decimal {
            precision: None,
            scale: None,
        },
        "DATE" => ColumnKind::Date,
        "TIME" => ColumnKind::Time {
            fractional_digits: None,
            with_offset: false,
            range: TimeRange::Duration,
        },
        "DATETIME" => ColumnKind::Timestamp {
            fractional_digits: None,
            zone: TemporalZone::Naive,
        },
        "TIMESTAMP" => ColumnKind::Timestamp {
            fractional_digits: None,
            zone: match timestamps {
                MySqlTimestampMode::WorkspaceUtc => TemporalZone::Offset,
                MySqlTimestampMode::SessionLocal => TemporalZone::Naive,
            },
        },
        "BIT" => ColumnKind::BitString {
            length: None,
            varying: false,
        },
        "JSON" => ColumnKind::Json { binary: true },
        "GEOMETRY" => ColumnKind::Spatial,
        "NULL" => return ResultColumn::new(column.name(), ColumnType::untyped_text("NULL")),
        _ if <str as Type<MySql>>::compatible(type_info) => ColumnKind::Text {
            length: TextLength::Unbounded,
        },
        _ => ColumnKind::Bytes {
            length: TextLength::Unbounded,
        },
    };
    ResultColumn::new(
        column.name(),
        ColumnType {
            name: name.to_ascii_lowercase(),
            dynamic_storage: has_dynamic_storage(&kind),
            kind,
            catalog: None,
            read_form: ReadForm::Native,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts<'a>(data_type: &'a str, column_type: &'a str) -> TypeFacts<'a> {
        TypeFacts {
            data_type,
            column_type,
            has_character_set: true,
            ..TypeFacts::default()
        }
    }

    #[test]
    fn mysql_int10_unsigned_zerofill_is_unsigned_integer() {
        assert_eq!(
            classify(&facts("int", "int(10) unsigned zerofill")),
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W32,
                signed: false
            })
        );
        assert_eq!(
            classify(&facts("bigint", "bigint unsigned")),
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W64,
                signed: false
            })
        );
    }

    #[test]
    fn mysql_decimal_10_2_unsigned_is_decimal() {
        let decimal = TypeFacts {
            numeric_precision: Some(10),
            numeric_scale: Some(2),
            ..facts("decimal", "decimal(10,2) unsigned")
        };
        let column = column_type(&decimal);

        assert_eq!(
            column.kind,
            ColumnKind::Decimal {
                precision: Some(10),
                scale: Some(2)
            }
        );
        assert_eq!(
            column.catalog.map(|catalog| catalog.declaration.as_sql().to_owned()),
            Some("decimal(10,2) unsigned".to_owned())
        );
    }

    #[test]
    fn mysql_tinyint1_is_bool_integer() {
        assert_eq!(
            classify(&facts("tinyint", "tinyint(1)")),
            ColumnKind::Bool(BoolStorage::Integer)
        );
        assert_eq!(
            classify(&facts("tinyint", "tinyint(4)")),
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W8,
                signed: true
            })
        );
    }

    #[test]
    fn mysql_enum_set_members_with_quote_and_backslash() {
        assert_eq!(
            classify(&facts("enum", r"enum('it''s','a\\b')")),
            ColumnKind::Enum {
                labels: vec!["it's".to_owned(), r"a\b".to_owned()],
                multiple: false
            }
        );
        assert_eq!(
            classify(&facts("set", "set('x','y')")),
            ColumnKind::Enum {
                labels: vec!["x".to_owned(), "y".to_owned()],
                multiple: true
            }
        );
    }

    #[test]
    fn mysql_unknown_modifier_is_other_server_text() {
        let column = column_type(&facts("int", "int(11) frobnicated"));

        assert_eq!(column.kind, ColumnKind::Other);
        assert_eq!(column.read_form, ReadForm::ServerText);
        assert_eq!(
            column.catalog.map(|catalog| catalog.declaration.as_sql().to_owned()),
            Some("int(11) frobnicated".to_owned())
        );
        assert_eq!(column_type(&facts("inet6", "inet6")).kind, ColumnKind::Other);
    }

    #[test]
    fn mysql_bit10_year_geometry() {
        let bit = TypeFacts {
            numeric_precision: Some(10),
            ..facts("bit", "bit(10)")
        };
        assert_eq!(
            classify(&bit),
            ColumnKind::BitString {
                length: Some(10),
                varying: false
            }
        );
        assert_eq!(
            classify(&facts("year", "year")),
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W16,
                signed: false
            })
        );
        assert_eq!(classify(&facts("geometry", "geometry")), ColumnKind::Spatial);
        assert_eq!(classify(&facts("point", "point")), ColumnKind::Spatial);
        let binary_text = TypeFacts {
            has_character_set: false,
            ..facts("varchar", "varbinary(4)")
        };
        assert!(
            matches!(classify(&binary_text), ColumnKind::Other),
            "a COLUMN_TYPE that does not start with its DATA_TYPE is not guessed at"
        );
        let blob = TypeFacts {
            has_character_set: false,
            ..facts("text", "text")
        };
        assert!(matches!(classify(&blob), ColumnKind::Bytes { .. }));
    }

    #[test]
    fn classify_default_table() {
        let integer = column_type(&facts("int", "int"));
        let text = column_type(&TypeFacts {
            character_maximum_length: Some(10),
            ..facts("varchar", "varchar(10)")
        });
        let stamp = column_type(&facts("timestamp", "timestamp"));
        let plain = MySqlExtra::default();
        let generated = MySqlExtra::parse("DEFAULT_GENERATED");
        let mysql = MySqlFlavour::MySql;
        let mariadb = MySqlFlavour::MariaDb;

        assert_eq!(
            classify_default(Some("42"), &integer, &plain, mysql),
            ColumnDefault::Literal(Value::Int(42))
        );
        assert_eq!(
            classify_default(Some("it's"), &text, &plain, mysql),
            ColumnDefault::Literal(Value::Text("it's".to_owned()))
        );
        assert_eq!(
            classify_default(Some(""), &text, &plain, mysql),
            ColumnDefault::Literal(Value::Text(String::new()))
        );
        assert!(matches!(
            classify_default(Some("CURRENT_TIMESTAMP"), &stamp, &generated, mysql),
            ColumnDefault::Expression(expression) if expression.as_sql() == "CURRENT_TIMESTAMP"
        ));
        assert!(matches!(
            classify_default(Some(r"concat(_utf8mb4\'it\\\'s\')"), &text, &generated, mysql),
            ColumnDefault::Expression(expression) if expression.as_sql() == r"concat(_utf8mb4'it\'s')"
        ));
        assert_eq!(classify_default(None, &integer, &plain, mysql), ColumnDefault::None);

        assert_eq!(
            classify_default(Some("'it''s'"), &text, &plain, mariadb),
            ColumnDefault::Literal(Value::Text("it's".to_owned()))
        );
        assert_eq!(
            classify_default(Some("7"), &integer, &plain, mariadb),
            ColumnDefault::Literal(Value::Int(7))
        );
        assert_eq!(
            classify_default(Some("NULL"), &integer, &plain, mariadb),
            ColumnDefault::None
        );
        assert!(matches!(
            classify_default(Some("current_timestamp()"), &stamp, &plain, mariadb),
            ColumnDefault::Expression(expression) if expression.as_sql() == "current_timestamp()"
        ));
    }

    #[test]
    fn a_generation_expression_reads_as_the_sql_each_server_runs() {
        let row = |extra: &str, expression: &str| MySqlColumnRow {
            name: "label".to_owned(),
            data_type: "varchar".to_owned(),
            column_type: "varchar(30)".to_owned(),
            nullable: true,
            extra: extra.to_owned(),
            character_maximum_length: Some(30),
            character_set: Some("utf8mb4".to_owned()),
            generation_expression: Some(expression.to_owned()),
            ..MySqlColumnRow::default()
        };
        let generated = |definition: ColumnDefinition| {
            definition
                .attributes
                .generated
                .map(|generated| (generated.expression.as_sql().to_owned(), generated.storage))
        };

        let mysql = column_definition(
            &row("VIRTUAL GENERATED", r"concat(`a`,_utf8mb4\'x\')"),
            MySqlFlavour::MySql,
            Vec::new(),
        );
        let mariadb = column_definition(
            &row("STORED GENERATED, INVISIBLE", "concat(`a`,'x')"),
            MySqlFlavour::MariaDb,
            Vec::new(),
        );

        assert_eq!(
            generated(mysql),
            Some(("concat(`a`,_utf8mb4'x')".to_owned(), GeneratedStorage::Virtual))
        );
        assert_eq!(mariadb.attributes.visibility, ColumnVisibility::Invisible);
        assert!(mariadb.attributes.unmodeled.is_empty());
        assert_eq!(
            generated(mariadb),
            Some(("concat(`a`,'x')".to_owned(), GeneratedStorage::Stored))
        );
    }
}
