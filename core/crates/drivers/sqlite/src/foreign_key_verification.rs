//! Telling the foreign key violations a batch introduced from the ones
//! that were already there.
//!
//! A rebuild has to run with foreign keys off, and the file may hold
//! violations from long before: SQLite does not check rows that were
//! written while foreign keys were off. So the check before the batch
//! and the check after it are compared, and only the difference fails
//! the batch.

use std::collections::HashMap;

use tablepro_core::ddl::ColumnRename;
use tablepro_core::{DriverError, ServerCode, ServerDiagnostics};

use crate::errors::{SQLITE_CONSTRAINT, SQLITE_CONSTRAINT_FOREIGNKEY};

/// One row of `foreign_key_check`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct Violation {
    pub table: String,
    /// `None` for a WITHOUT ROWID child table, which has no rowid to
    /// name the row by, and for one whose rows the batch renumbers.
    pub rowid: Option<i64>,
    pub parent: String,
    pub key: ViolatedKey,
}

/// The foreign key a row breaks, by its columns rather than its number:
/// a rebuild numbers the keys again, and can trade one key for another
/// to the same parent.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub(crate) struct ViolatedKey {
    pub columns: Vec<String>,
    /// Empty for one that names no columns and so points at the parent's
    /// primary key.
    pub parent_columns: Vec<String>,
}

/// Violations in one child table against one parent, that the batch
/// left behind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct IntroducedViolations {
    pub table: String,
    pub parent: String,
    pub count: usize,
}

/// The names a batch gives tables and their columns, keyed by the
/// table's name before it, folded.
#[derive(Debug, Default)]
pub(crate) struct Renames {
    tables: HashMap<String, String>,
    columns: HashMap<String, HashMap<String, String>>,
}

impl Renames {
    pub(crate) fn add(&mut self, before: &str, after: &str, columns: &[ColumnRename]) {
        let before = before.to_lowercase();
        self.tables.insert(before.clone(), after.to_owned());
        if !columns.is_empty() {
            let renamed = columns
                .iter()
                .map(|rename| (rename.from.to_lowercase(), rename.to.clone()))
                .collect();
            self.columns.insert(before, renamed);
        }
    }

    /// Name `baseline` rows by the names their tables and key columns
    /// have after the batch, so a renamed table or key compares with
    /// itself.
    pub(crate) fn apply(&self, baseline: Vec<Violation>) -> Vec<Violation> {
        baseline
            .into_iter()
            .map(|violation| Violation {
                key: ViolatedKey {
                    columns: self.column_names(&violation.table, violation.key.columns),
                    parent_columns: self.column_names(&violation.parent, violation.key.parent_columns),
                },
                table: self.table_name(violation.table),
                rowid: violation.rowid,
                parent: self.table_name(violation.parent),
            })
            .collect()
    }

    fn table_name(&self, name: String) -> String {
        self.tables.get(&name.to_lowercase()).cloned().unwrap_or(name)
    }

    fn column_names(&self, table: &str, columns: Vec<String>) -> Vec<String> {
        let Some(renamed) = self.columns.get(&table.to_lowercase()) else {
            return columns;
        };
        columns
            .into_iter()
            .map(|column| renamed.get(&column.to_lowercase()).cloned().unwrap_or(column))
            .collect()
    }
}

/// The rows of `after` that `before` does not account for, compared as
/// multisets. Rows without a rowid are all alike, so for them it is the
/// count per child, parent and key that compares.
pub(crate) fn introduced(before: &[Violation], after: &[Violation]) -> Vec<IntroducedViolations> {
    let mut remaining: HashMap<ViolationKey, usize> = HashMap::new();
    for violation in before {
        *remaining.entry(key(violation)).or_default() += 1;
    }
    let mut introduced: Vec<IntroducedViolations> = Vec::new();
    for violation in after {
        if let Some(left) = remaining.get_mut(&key(violation))
            && *left > 0
        {
            *left -= 1;
            continue;
        }
        let table = violation.table.to_lowercase();
        let parent = violation.parent.to_lowercase();
        match introduced
            .iter_mut()
            .find(|group| group.table.to_lowercase() == table && group.parent.to_lowercase() == parent)
        {
            Some(group) => group.count += 1,
            None => introduced.push(IntroducedViolations {
                table: violation.table.clone(),
                parent: violation.parent.clone(),
                count: 1,
            }),
        }
    }
    introduced
}

type ViolationKey = (String, Option<i64>, String, Vec<String>, Vec<String>);

/// SQLite names tables and columns case-insensitively, and so does the
/// comparison.
fn key(violation: &Violation) -> ViolationKey {
    let folded = |names: &[String]| names.iter().map(|name| name.to_lowercase()).collect();
    (
        violation.table.to_lowercase(),
        violation.rowid,
        violation.parent.to_lowercase(),
        folded(&violation.key.columns),
        folded(&violation.key.parent_columns),
    )
}

/// The error a batch that introduced violations is rolled back with,
/// in the form SQLite reports a foreign key failure itself.
pub(crate) fn violation_error(introduced: &[IntroducedViolations]) -> DriverError {
    let listed: Vec<String> = introduced
        .iter()
        .map(|group| {
            format!(
                "{} rows of {} point at missing rows of {}",
                group.count, group.table, group.parent
            )
        })
        .collect();
    DriverError::reported(ServerDiagnostics::new(
        Some(ServerCode::Sqlite {
            primary: SQLITE_CONSTRAINT,
            extended: SQLITE_CONSTRAINT_FOREIGNKEY,
        }),
        format!("FOREIGN KEY constraint failed: {}", listed.join("; ")),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn violation(table: &str, rowid: Option<i64>, parent: &str) -> Violation {
        keyed(table, rowid, parent, &["parent"], &["id"])
    }

    fn keyed(table: &str, rowid: Option<i64>, parent: &str, columns: &[&str], parent_columns: &[&str]) -> Violation {
        let owned = |names: &[&str]| names.iter().map(|name| (*name).to_owned()).collect();
        Violation {
            table: table.to_owned(),
            rowid,
            parent: parent.to_owned(),
            key: ViolatedKey {
                columns: owned(columns),
                parent_columns: owned(parent_columns),
            },
        }
    }

    fn renames(before: &str, after: &str, columns: &[(&str, &str)]) -> Renames {
        let mut renames = Renames::default();
        let columns: Vec<ColumnRename> = columns
            .iter()
            .map(|(from, to)| ColumnRename {
                from: (*from).to_owned(),
                to: (*to).to_owned(),
            })
            .collect();
        renames.add(before, after, &columns);
        renames
    }

    #[test]
    fn introduced_violations_ignore_baseline_rows_across_rename() {
        let before = vec![
            violation("orders_old", Some(7), "people"),
            violation("lines", Some(1), "orders_old"),
        ];
        let renames = renames("orders_old", "orders", &[]);
        let after = vec![
            violation("orders", Some(7), "people"),
            violation("lines", Some(1), "orders"),
            violation("lines", Some(2), "orders"),
        ];

        let introduced = introduced(&renames.apply(before), &after);

        assert_eq!(
            introduced,
            [IntroducedViolations {
                table: "lines".to_owned(),
                parent: "orders".to_owned(),
                count: 1
            }]
        );
    }

    #[test]
    fn a_row_breaking_another_key_to_the_same_parent_is_introduced() {
        let before = vec![keyed("children", Some(1), "parents", &["a"], &["id"])];
        let after = vec![keyed("children", Some(1), "parents", &["b"], &["id"])];

        assert_eq!(
            introduced(&before, &after),
            [IntroducedViolations {
                table: "children".to_owned(),
                parent: "parents".to_owned(),
                count: 1
            }]
        );
    }

    #[test]
    fn a_renamed_key_column_keeps_its_violation_on_either_side() {
        let before = vec![
            keyed("children", Some(1), "parents", &["parent"], &["id"]),
            keyed("grandchildren", Some(4), "children", &["child"], &["Parent"]),
        ];
        let renames = renames("children", "children", &[("parent", "parent_id")]);
        let after = vec![
            keyed("children", Some(1), "parents", &["parent_id"], &["id"]),
            keyed("grandchildren", Some(4), "children", &["child"], &["parent_id"]),
        ];

        assert!(introduced(&renames.apply(before), &after).is_empty());
    }

    #[test]
    fn without_rowid_violations_compare_by_count() {
        let before = vec![violation("tags", None, "posts"), violation("tags", None, "posts")];
        let same = before.clone();
        let more = vec![
            violation("tags", None, "posts"),
            violation("Tags", None, "Posts"),
            violation("tags", None, "posts"),
        ];

        assert!(introduced(&before, &same).is_empty());
        assert_eq!(introduced(&before, &more).len(), 1);
        assert_eq!(introduced(&before, &more)[0].count, 1);
    }

    #[test]
    fn the_error_reads_as_a_sqlite_foreign_key_failure() {
        let error = violation_error(&[IntroducedViolations {
            table: "lines".to_owned(),
            parent: "orders".to_owned(),
            count: 2,
        }]);

        let DriverError::Server(diagnostics) = &error else {
            panic!("not a server error: {error:?}");
        };
        assert_eq!(
            diagnostics.code,
            Some(ServerCode::Sqlite {
                primary: 19,
                extended: 787
            })
        );
        assert!(
            diagnostics.message.contains("2 rows of lines"),
            "{}",
            diagnostics.message
        );
    }
}
