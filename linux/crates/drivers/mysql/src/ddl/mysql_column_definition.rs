//! A MySQL or MariaDB column definition, as CREATE TABLE, ADD COLUMN,
//! MODIFY COLUMN and CHANGE COLUMN write it.

use tablepro_core::column::{ColumnDefault, ColumnKind};
use tablepro_core::ddl::ddl_sql::{default_sql, parenthesized};
use tablepro_core::ddl::{
    BuildDdlError, ColumnAttributes, ColumnCapabilities, ColumnDefinition, ColumnVisibility, DraftColumn, DraftType,
    GeneratedStorage, Permission, RefusalReason,
};
use tablepro_core::dialect::SqlDialect;

use crate::dialect::MySqlDialect;
use crate::flavour::MySqlFlavour;

/// `<name> <type> [REF_SYSTEM_ID=n] [CHARACTER SET cs] [COLLATE coll]
/// [GENERATED ALWAYS AS (expr) VIRTUAL|STORED] [NULL|NOT NULL]
/// [DEFAULT ..] [ON UPDATE expr] [AUTO_INCREMENT] [INVISIBLE] [SRID n]
/// [COMMENT '..'] [CHECK (..)]`.
///
/// MODIFY and CHANGE replace the old definition whole and carry nothing
/// forward, so every attribute the column had that its new type still
/// holds is written again. A column the user added has none.
pub(crate) fn render(dialect: &MySqlDialect, column: &DraftColumn) -> Result<String, BuildDdlError> {
    let resolved = column.column_type.resolve(dialect, &column.name)?;
    let kind = &resolved.column_type.kind;
    let added = ColumnAttributes::default();
    let kept = column.original.as_ref().map_or(&added, |original| &original.attributes);
    let mariadb = dialect.flavour() == MySqlFlavour::MariaDb;
    let srid = kept.spatial_reference.filter(|_| matches!(kind, ColumnKind::Spatial));
    let mut parts = vec![dialect.quote_identifier(&column.name), resolved.sql.clone()];
    // MariaDB reads the SRID only straight after the type.
    if mariadb && let Some(srid) = srid {
        parts.push(format!("REF_SYSTEM_ID={srid}"));
    }
    if holds_text(column, kind) {
        if let Some(character_set) = &kept.character_set {
            parts.push(format!("CHARACTER SET {}", dialect.quote_identifier(character_set)));
        }
        if let Some(collation) = &kept.collation {
            parts.push(format!("COLLATE {}", dialect.quote_identifier(&collation.name)));
        }
    }
    let nullability = if column.nullable { "NULL" } else { "NOT NULL" };
    match &kept.generated {
        Some(generated) => {
            let storage = match generated.storage {
                GeneratedStorage::Virtual => "VIRTUAL",
                GeneratedStorage::Stored => "STORED",
            };
            parts.push(format!(
                "GENERATED ALWAYS AS {} {storage}",
                parenthesized(generated.expression.as_sql())
            ));
            if !mariadb {
                parts.push(nullability.to_owned());
            }
        }
        None => {
            parts.push(nullability.to_owned());
            if !column.auto_increment
                && let Some(default) = default_sql(dialect, &column.name, &column.default, &resolved.column_type)?
            {
                parts.push(format!(
                    "DEFAULT {}",
                    default_clause(&column.default, &default, &resolved.sql)
                ));
            }
            if let Some(expression) = kept
                .on_update
                .as_ref()
                .filter(|_| matches!(kind, ColumnKind::Timestamp { .. }))
            {
                parts.push(format!("ON UPDATE {}", expression.as_sql()));
            }
            if column.auto_increment {
                parts.push("AUTO_INCREMENT".to_owned());
            }
        }
    }
    if kept.visibility == ColumnVisibility::Invisible {
        parts.push("INVISIBLE".to_owned());
    }
    if !mariadb && let Some(srid) = srid {
        parts.push(format!("SRID {srid}"));
    }
    if let Some(comment) = column.comment_text() {
        parts.push(format!("COMMENT {}", comment_literal(comment)));
    }
    // MariaDB reads a column's CHECK only last.
    if let Some(check) = &kept.check {
        parts.push(format!("CHECK {}", parenthesized(check.as_sql())));
    }
    Ok(parts.join(" "))
}

/// Whether `render` writes the column back as it is: every attribute the
/// catalogue reported is modeled, a generated column's expression was
/// read, and each name and expression it splices is one the server
/// itself would print.
pub(crate) fn restatement(column: &ColumnDefinition) -> Permission {
    let attributes = &column.attributes;
    ColumnCapabilities::modeled(column)
        .and(|| {
            Permission::unless(
                !column.info.is_generated || attributes.generated.is_some(),
                RefusalReason::GeneratedColumn,
            )
        })
        .and(|| plain_name("CHARACTER SET", attributes.character_set.as_deref()))
        .and(|| {
            plain_name(
                "COLLATE",
                attributes.collation.as_ref().map(|collation| collation.name.as_str()),
            )
        })
        .and(|| match &attributes.on_update {
            Some(expression) if !is_current_timestamp(expression.as_sql()) => Permission::Refused(
                RefusalReason::UnmodeledAttribute(format!("ON UPDATE {}", expression.as_sql())),
            ),
            _ => Permission::Allowed,
        })
}

/// MariaDB takes no NULL or NOT NULL on a generated column, so its
/// nullability cannot change.
pub(crate) fn nullability_permission(dialect: &MySqlDialect, column: &ColumnDefinition) -> Permission {
    let generated = column.info.is_generated || column.attributes.generated.is_some();
    Permission::unless(
        dialect.flavour() == MySqlFlavour::MySql || !generated,
        RefusalReason::GeneratedColumn,
    )
}

/// Character set and collation names are words, as the server prints
/// them. Anything else is not a name this build knows how to restate.
fn plain_name(clause: &str, name: Option<&str>) -> Permission {
    match name {
        Some(name)
            if name.is_empty()
                || !name
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric() || character == '_') =>
        {
            Permission::Refused(RefusalReason::UnmodeledAttribute(format!("{clause} {name}")))
        }
        _ => Permission::Allowed,
    }
}

/// The catalogue names a character set only for a column that holds
/// text, and a type the user typed may not.
fn holds_text(column: &DraftColumn, kind: &ColumnKind) -> bool {
    matches!(column.column_type, DraftType::Catalog(_))
        || matches!(kind, ColumnKind::Text { .. } | ColumnKind::Enum { .. })
}

/// MySQL takes an expression default only in parentheses, apart from the
/// CURRENT_TIMESTAMP family, and takes a literal on a BLOB, TEXT, JSON or
/// spatial column only as an expression.
fn default_clause(default: &ColumnDefault, sql: &str, declaration: &str) -> String {
    match default {
        ColumnDefault::Expression(_) if is_current_timestamp(sql) => sql.to_owned(),
        ColumnDefault::Expression(_) => parenthesized(sql),
        ColumnDefault::Literal(_) if needs_expression_default(declaration) => format!("({sql})"),
        _ => sql.to_owned(),
    }
}

fn is_current_timestamp(sql: &str) -> bool {
    let compact: String = sql
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect::<String>()
        .to_ascii_lowercase();
    let name = compact.split('(').next().unwrap_or_default();
    let arguments = compact.get(name.len()..).unwrap_or_default();
    let precision_only = arguments.is_empty()
        || (arguments.starts_with('(')
            && arguments.ends_with(')')
            && arguments
                .get(1..arguments.len() - 1)
                .is_some_and(|digits| digits.chars().all(|character| character.is_ascii_digit())));
    matches!(name, "current_timestamp" | "now" | "localtime" | "localtimestamp") && precision_only
}

fn needs_expression_default(declaration: &str) -> bool {
    let name = declaration
        .trim()
        .split(|character: char| character == '(' || character.is_whitespace())
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        name.as_str(),
        "tinytext"
            | "text"
            | "mediumtext"
            | "longtext"
            | "tinyblob"
            | "blob"
            | "mediumblob"
            | "longblob"
            | "json"
            | "geometry"
            | "point"
            | "linestring"
            | "polygon"
            | "multipoint"
            | "multilinestring"
            | "multipolygon"
            | "geometrycollection"
    )
}

/// COMMENT takes a plain string only, with no introducer or hex form.
/// Workspace sessions run with backslash escapes on, so doubling both the
/// quote and the backslash reads back as the text.
fn comment_literal(text: &str) -> String {
    format!("'{}'", text.replace('\\', "\\\\").replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_current_timestamp_family_goes_bare() {
        assert!(is_current_timestamp("CURRENT_TIMESTAMP"));
        assert!(is_current_timestamp("current_timestamp(6)"));
        assert!(is_current_timestamp("now()"));
        assert!(!is_current_timestamp("now() + interval 1 day"));
        assert!(!is_current_timestamp("uuid()"));
        assert!(!is_current_timestamp("current_timestamp(),"));
    }

    #[test]
    fn a_comment_doubles_its_quotes_and_backslashes() {
        assert_eq!(comment_literal(r"it's \ x"), r"'it''s \\ x'");
    }

    #[test]
    fn only_a_word_is_a_name_to_restate() {
        assert_eq!(plain_name("COLLATE", Some("utf8mb4_0900_ai_ci")), Permission::Allowed);
        assert_eq!(plain_name("COLLATE", None), Permission::Allowed);
        assert_eq!(
            plain_name("COLLATE", Some("odd-name")),
            Permission::Refused(RefusalReason::UnmodeledAttribute("COLLATE odd-name".to_owned()))
        );
    }
}
