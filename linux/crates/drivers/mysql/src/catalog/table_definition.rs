use tablepro_core::DriverError;
use tablepro_core::ddl::InboundForeignKey;
use tablepro_core::meta::TableRef;

use super::catalog_cells::CatalogCells;

/// Foreign keys on other tables that point at this one, one row per
/// column in key order.
pub(crate) const INBOUND_FOREIGN_KEYS_SQL: &str = "\
SELECT CONSTRAINT_NAME, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, REFERENCED_COLUMN_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE REFERENCED_TABLE_SCHEMA = COALESCE(?, DATABASE()) AND REFERENCED_TABLE_NAME = ?
ORDER BY TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION";

/// Engine attributes on columns, which MySQL 8.0.21 and later keep apart
/// from COLUMNS and which this build does not model.
pub(crate) const COLUMN_ENGINE_ATTRIBUTES_SQL: &str = "\
SELECT COLUMN_NAME, ENGINE_ATTRIBUTE, SECONDARY_ENGINE_ATTRIBUTE
FROM information_schema.COLUMNS_EXTENSIONS
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?";

/// MariaDB's SRID of each geometry column. COLUMNS and SHOW CREATE TABLE
/// leave it out, and a MODIFY that does not restate it resets it to 0.
/// The F_ names are the ones the server looks a table up by.
pub(crate) const MARIADB_GEOMETRY_SRIDS_SQL: &str = "\
SELECT G_GEOMETRY_COLUMN, SRID
FROM information_schema.GEOMETRY_COLUMNS
WHERE F_TABLE_SCHEMA = COALESCE(?, DATABASE()) AND F_TABLE_NAME = ?";

/// MariaDB's CHECK constraints written on a column. A MODIFY that does
/// not restate one drops it, the `json_valid` check MariaDB puts on every
/// JSON column included. The constraint keeps the column's name from when
/// it was written through a rename, so it does not tell the column.
pub(crate) const MARIADB_COLUMN_CHECKS_SQL: &str = "\
SELECT CHECK_CLAUSE
FROM information_schema.CHECK_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ? AND LEVEL = 'Column'";

/// GEOMETRY_COLUMNS holds the SRID in a smallint, so a larger one reads
/// as this.
const SATURATED_SRID: u64 = 32767;

/// A geometry column's SRID as MariaDB lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ListedSrid {
    Exact(u64),
    /// 32767 or above, which the catalogue cannot tell apart.
    Saturated,
}

/// Each geometry column that sets an SRID. MariaDB lists 0 for one that
/// sets none.
pub(crate) fn geometry_srids(rows: &[CatalogCells]) -> Result<Vec<(String, ListedSrid)>, DriverError> {
    let mut srids = Vec::new();
    for row in rows {
        let column = row.required_text(0)?;
        match row.number(1)? {
            None | Some(0) => {}
            Some(SATURATED_SRID) => srids.push((column, ListedSrid::Saturated)),
            Some(srid) => srids.push((column, ListedSrid::Exact(srid))),
        }
    }
    Ok(srids)
}

/// Each column-level CHECK clause, as SQL.
pub(crate) fn column_checks(rows: &[CatalogCells]) -> Result<Vec<String>, DriverError> {
    rows.iter().map(|row| row.required_text(0)).collect()
}

/// What a column's own CHECK is, as far as the catalogue tells.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ColumnCheck {
    None,
    Clause(String),
    /// The table has a column-level CHECK no column's line ends with, so
    /// any column without one may be its owner.
    Unplaced,
}

/// Gives each column-level clause to the column whose line in SHOW
/// CREATE TABLE ends with it. MariaDB prints a column's CHECK last on
/// the column's line, and its expression and the catalogue's clause are
/// the same text, which follows a rename as the constraint name does not.
pub(crate) fn place_column_checks(create_statement: &str, columns: &[&str], clauses: Vec<String>) -> Vec<ColumnCheck> {
    let mut unplaced = clauses;
    let placed: Vec<Option<String>> = columns
        .iter()
        .map(|column| {
            let line = column_line(create_statement, column)?;
            let position = unplaced.iter().position(|clause| ends_with_check(line, clause))?;
            Some(unplaced.swap_remove(position))
        })
        .collect();
    placed
        .into_iter()
        .map(|clause| match clause {
            Some(clause) => ColumnCheck::Clause(clause),
            None if unplaced.is_empty() => ColumnCheck::None,
            None => ColumnCheck::Unplaced,
        })
        .collect()
}

/// A name as the server prints it in SHOW CREATE TABLE and in the
/// catalogue's expressions: in backticks, or in double quotes when the
/// session's sql_mode has ANSI_QUOTES.
pub(crate) fn printed_names(name: &str) -> [String; 2] {
    ['`', '"'].map(|quote| {
        let doubled = name.replace(quote, &format!("{quote}{quote}"));
        format!("{quote}{doubled}{quote}")
    })
}

/// SHOW CREATE TABLE prints each column on a line of its own, two spaces
/// in, and escapes a line break inside a string or comment.
fn column_line<'a>(create_statement: &'a str, column: &str) -> Option<&'a str> {
    printed_names(column).iter().find_map(|printed| {
        let head = format!("{printed} ");
        elements(create_statement).find_map(|element| {
            let line = element.strip_prefix("  ")?;
            line.starts_with(&head).then(|| line.strip_suffix(',').unwrap_or(line))
        })
    })
}

// The body's elements, each two spaces in. Matching a whole element keeps a name that spells
// another element's head, in a mode that quotes names differently, from being taken for it.
fn elements(create_statement: &str) -> impl Iterator<Item = &str> {
    let mut rest = create_statement
        .get(entry(create_statement).len() + 1..)
        .unwrap_or_default();
    std::iter::from_fn(move || {
        if !rest.starts_with("  ") {
            return None;
        }
        let element = entry(rest);
        rest = rest.get(element.len() + 1..).unwrap_or_default();
        Some(element)
    })
}

// The server escapes a line break in a string but prints one in a name as it is.
fn entry(text: &str) -> &str {
    let mut quote: Option<char> = None;
    let mut escaped = false;
    for (position, character) in text.char_indices() {
        match quote {
            Some('\'') if escaped => escaped = false,
            Some('\'') if character == '\\' => escaped = true,
            Some(open) if character == open => quote = None,
            Some(_) => {}
            None if character == '\n' => return &text[..position],
            None if matches!(character, '`' | '"' | '\'') => quote = Some(character),
            None => {}
        }
    }
    text
}

// An index's own line keeps options the catalogue tables do not all list: INVISIBLE, COMMENT,
// WITH PARSER, IGNORED, a vector index's M and DISTANCE. CREATE INDEX takes them after the keys.
pub(crate) fn index_statement(create_statement: &str, table: &str, index: &str) -> Option<String> {
    const KINDS: [(&str, &str); 5] = [
        ("KEY", "INDEX"),
        ("UNIQUE KEY", "UNIQUE INDEX"),
        ("FULLTEXT KEY", "FULLTEXT INDEX"),
        ("SPATIAL KEY", "SPATIAL INDEX"),
        ("VECTOR KEY", "VECTOR INDEX"),
    ];
    printed_names(index).iter().find_map(|printed| {
        KINDS.iter().find_map(|(key, kind)| {
            let head = format!("  {key} {printed} ");
            elements(create_statement).find_map(|element| {
                let line = element.strip_prefix(&head)?.trim_end();
                let rest = line.strip_suffix(',').unwrap_or(line).trim_end();
                Some(format!("CREATE {kind} {printed} ON {table} {rest}"))
            })
        })
    })
}

/// The quoted DEFAULT on the column's line of SHOW CREATE TABLE, without
/// its quotes. The server prints a TIMESTAMP default there as wall time
/// in the session's zone, where MySQL's `COLUMN_DEFAULT` keeps the text
/// of whichever session last altered the table, in that session's zone.
pub(crate) fn quoted_default(create_statement: &str, column: &str) -> Option<String> {
    const MARKER: &str = " DEFAULT '";
    let line = column_line(create_statement, column)?;
    let rest = line.get(line.find(MARKER)? + MARKER.len()..)?;
    let end = rest.find('\'')?;
    rest.get(..end).map(str::to_owned)
}

fn ends_with_check(line: &str, clause: &str) -> bool {
    line.strip_suffix(')')
        .and_then(|rest| rest.strip_suffix(clause))
        .is_some_and(|rest| rest.ends_with(" CHECK ("))
}

/// One key per constraint, its columns in order.
pub(crate) fn inbound_foreign_keys(rows: &[CatalogCells]) -> Result<Vec<InboundForeignKey>, DriverError> {
    let mut keys: Vec<InboundForeignKey> = Vec::new();
    for row in rows {
        let name = row.required_text(0)?;
        let schema = row.required_text(1)?;
        let table = row.required_text(2)?;
        let column = row.required_text(3)?;
        let referenced = row.required_text(4)?;
        let same = keys.last_mut().filter(|key| {
            key.name == name && key.table.name == table && key.table.schema.as_deref() == Some(schema.as_str())
        });
        match same {
            Some(key) => {
                key.columns.push(column);
                key.referenced_columns.push(referenced);
            }
            None => keys.push(InboundForeignKey {
                // Read with the columns of both sides by the caller.
                child_compares_alike: true,
                name,
                table: TableRef::new(Some(schema), table),
                columns: vec![column],
                referenced_columns: vec![referenced],
            }),
        }
    }
    Ok(keys)
}

#[cfg(test)]
mod tests {
    use tablepro_core::value::Value;

    use super::*;

    fn row(values: [&str; 5]) -> CatalogCells {
        CatalogCells::new(
            "KEY_COLUMN_USAGE",
            values.iter().map(|text| Value::Text((*text).to_owned())).collect(),
        )
    }

    #[test]
    fn an_index_line_becomes_its_create_index() {
        let create = "CREATE TABLE `t` (\n  `id` int NOT NULL,\n  `KEY x` text,\n  PRIMARY KEY (`id`),\n  \
                      UNIQUE KEY `u` (`id` DESC,`b`(10)) USING HASH,\n  KEY `a``b c` ((lower(`b`))) COMMENT 'x\\ny' \
                      /*!80000 INVISIBLE */,\n  FULLTEXT KEY `f` (`b`) /*!50100 WITH PARSER `ngram` */ ,\n  \
                      SPATIAL KEY `g` (`p`)\n) ENGINE=InnoDB";
        let statement = |index: &str| index_statement(create, "`d`.`t`", index);

        assert_eq!(
            statement("u").as_deref(),
            Some("CREATE UNIQUE INDEX `u` ON `d`.`t` (`id` DESC,`b`(10)) USING HASH")
        );
        assert_eq!(
            statement("a`b c").as_deref(),
            Some("CREATE INDEX `a``b c` ON `d`.`t` ((lower(`b`))) COMMENT 'x\\ny' /*!80000 INVISIBLE */")
        );
        assert_eq!(
            statement("f").as_deref(),
            Some("CREATE FULLTEXT INDEX `f` ON `d`.`t` (`b`) /*!50100 WITH PARSER `ngram` */")
        );
        assert_eq!(
            statement("g").as_deref(),
            Some("CREATE SPATIAL INDEX `g` ON `d`.`t` (`p`)")
        );
        assert_eq!(statement("x"), None);
        assert_eq!(statement("PRIMARY"), None);
    }

    #[test]
    fn a_line_break_in_a_name_stays_in_its_entry() {
        let create = "CREATE TABLE `t` (\n  `a\nb` int DEFAULT '7',\n  KEY `k\n2` (`a\nb`),\n  KEY `next` (`id`)\n)";

        assert_eq!(
            index_statement(create, "`d`.`t`", "k\n2").as_deref(),
            Some("CREATE INDEX `k\n2` ON `d`.`t` (`a\nb`)")
        );
        assert_eq!(quoted_default(create, "a\nb").as_deref(), Some("7"));
    }

    #[test]
    fn a_name_that_spells_an_index_line_is_not_taken_for_it() {
        let create = "CREATE TABLE \"t\" (\n  \"id\" int,\n  \"x\n  KEY `k` (`id`); DROP TABLE users\nz\" int,\n  \
                      KEY \"k\" (\"id\")\n)";

        assert_eq!(
            index_statement(create, "`d`.`t`", "k").as_deref(),
            Some("CREATE INDEX \"k\" ON `d`.`t` (\"id\")")
        );
    }

    #[test]
    fn an_ansi_quoted_index_line_keeps_its_quotes() {
        let create = "CREATE TABLE \"t\" (\n  \"id\" int,\n  KEY \"k\" (\"id\")\n)";

        assert_eq!(
            index_statement(create, "`d`.`t`", "k").as_deref(),
            Some("CREATE INDEX \"k\" ON `d`.`t` (\"id\")")
        );
    }

    #[test]
    fn a_quoted_default_is_read_from_its_own_columns_line() {
        let create = "CREATE TABLE `t` (\n  `id` int NOT NULL,\n  `at` timestamp NULL DEFAULT '1999-12-31 17:00:00' \
                      COMMENT 'x',\n  `made` timestamp NULL DEFAULT CURRENT_TIMESTAMP,\n  PRIMARY KEY (`id`)\n)";

        assert_eq!(quoted_default(create, "at").as_deref(), Some("1999-12-31 17:00:00"));
        assert_eq!(quoted_default(create, "made"), None);
        assert_eq!(quoted_default(create, "missing"), None);
    }

    #[test]
    fn only_a_geometry_column_that_sets_an_srid_keeps_one() {
        let rows = [
            CatalogCells::new(
                "GEOMETRY_COLUMNS",
                vec![Value::Text("shape".to_owned()), Value::UInt(4326)],
            ),
            CatalogCells::new("GEOMETRY_COLUMNS", vec![Value::Text("area".to_owned()), Value::Int(0)]),
        ];

        assert_eq!(
            geometry_srids(&rows).expect("SRIDs"),
            [("shape".to_owned(), ListedSrid::Exact(4326))]
        );
    }

    #[test]
    fn an_srid_the_smallint_cannot_hold_is_not_taken_as_32767() {
        let rows = [CatalogCells::new(
            "GEOMETRY_COLUMNS",
            vec![Value::Text("web".to_owned()), Value::Int(32767)],
        )];

        assert_eq!(
            geometry_srids(&rows).expect("SRIDs"),
            [("web".to_owned(), ListedSrid::Saturated)]
        );
    }

    const RENAMED: &str = "CREATE TABLE `t` (\n  `id` int(11) NOT NULL,\n  `body` longtext CHARACTER SET utf8mb4 \
                           COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`body`)),\n  `b` int(11) DEFAULT NULL \
                           CHECK (`b` > 0),\n  `doc` int(11) DEFAULT NULL COMMENT 'x CHECK (`b` > 0)',\n  PRIMARY \
                           KEY (`id`),\n  CONSTRAINT `tc` CHECK (`b` < 100)\n) ENGINE=InnoDB";

    #[test]
    fn a_check_goes_to_the_column_whose_line_ends_with_it() {
        let placed = place_column_checks(
            RENAMED,
            &["id", "body", "b", "doc"],
            vec!["json_valid(`body`)".to_owned(), "`b` > 0".to_owned()],
        );

        assert_eq!(
            placed,
            [
                ColumnCheck::None,
                ColumnCheck::Clause("json_valid(`body`)".to_owned()),
                ColumnCheck::Clause("`b` > 0".to_owned()),
                ColumnCheck::None,
            ]
        );
    }

    #[test]
    fn a_check_read_under_ansi_quotes_still_finds_its_column() {
        let ansi = RENAMED.replace('`', "\"");

        let placed = place_column_checks(&ansi, &["id", "body"], vec!["json_valid(\"body\")".to_owned()]);

        assert_eq!(
            placed,
            [
                ColumnCheck::None,
                ColumnCheck::Clause("json_valid(\"body\")".to_owned())
            ]
        );
    }

    #[test]
    fn a_check_no_line_ends_with_leaves_every_column_without_one_unplaced() {
        let placed = place_column_checks(
            RENAMED,
            &["id", "body", "b"],
            vec!["json_valid(`body`)".to_owned(), "`gone` > 1".to_owned()],
        );

        assert_eq!(
            placed,
            [
                ColumnCheck::Unplaced,
                ColumnCheck::Clause("json_valid(`body`)".to_owned()),
                ColumnCheck::Unplaced,
            ]
        );
    }

    #[test]
    fn a_printed_name_doubles_its_quote() {
        assert_eq!(printed_names("a`b\"c"), ["`a``b\"c`", "\"a`b\"\"c\""]);
    }

    #[test]
    fn a_composite_key_collects_its_columns_in_order() {
        let rows = [
            row(["fk_line", "shop", "lines", "order_id", "id"]),
            row(["fk_line", "shop", "lines", "order_rev", "rev"]),
            row(["fk_note", "shop", "notes", "order_id", "id"]),
        ];

        let keys = inbound_foreign_keys(&rows).expect("keys");

        assert_eq!(keys.len(), 2);
        assert_eq!(keys[0].columns, ["order_id", "order_rev"]);
        assert_eq!(keys[0].referenced_columns, ["id", "rev"]);
        assert_eq!(keys[1].table, TableRef::new(Some("shop".to_owned()), "notes"));
    }
}
