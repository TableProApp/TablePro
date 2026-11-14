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

// The rows of `foreign_key_check`, in its order. A file can hold millions of rows that break one key, so each row
// is the key's index and its rowid rather than its own copy of the names. A rowid is None for a WITHOUT ROWID child
// table, which has no rowid to name the row by, and for one whose rows the batch renumbers.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Violations {
    keys: Vec<BrokenKey>,
    rows: Vec<(usize, Option<i64>)>,
}

// A foreign key of one child table that some row breaks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BrokenKey {
    pub table: String,
    pub parent: String,
    pub key: ViolatedKey,
}

impl Violations {
    pub(crate) fn add_key(&mut self, key: BrokenKey) -> usize {
        self.keys.push(key);
        self.keys.len() - 1
    }

    pub(crate) fn add_row(&mut self, key: usize, rowid: Option<i64>) {
        self.rows.push((key, rowid));
    }

    pub(crate) fn extend(&mut self, other: Violations) {
        let offset = self.keys.len();
        self.keys.extend(other.keys);
        self.rows
            .extend(other.rows.into_iter().map(|(key, rowid)| (key + offset, rowid)));
    }
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
    pub(crate) fn apply(&self, baseline: Violations) -> Violations {
        Violations {
            keys: baseline
                .keys
                .into_iter()
                .map(|broken| BrokenKey {
                    key: ViolatedKey {
                        columns: self.column_names(&broken.table, broken.key.columns),
                        parent_columns: self.column_names(&broken.parent, broken.key.parent_columns),
                    },
                    table: self.table_name(broken.table),
                    parent: self.table_name(broken.parent),
                })
                .collect(),
            rows: baseline.rows,
        }
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
pub(crate) fn introduced(before: &Violations, after: &Violations) -> Vec<IntroducedViolations> {
    let mut ids: HashMap<ViolationKey, usize> = HashMap::new();
    let mut id_of = |broken: &BrokenKey| {
        let next = ids.len();
        *ids.entry(key(broken)).or_insert(next)
    };
    let before_ids: Vec<usize> = before.keys.iter().map(&mut id_of).collect();
    let after_ids: Vec<usize> = after.keys.iter().map(&mut id_of).collect();
    let mut remaining: HashMap<(usize, Option<i64>), usize> = HashMap::new();
    for (key, rowid) in &before.rows {
        if let Some(id) = before_ids.get(*key) {
            *remaining.entry((*id, *rowid)).or_default() += 1;
        }
    }
    let mut introduced: Vec<IntroducedViolations> = Vec::new();
    let mut groups: HashMap<(String, String), usize> = HashMap::new();
    for (key, rowid) in &after.rows {
        let (Some(id), Some(broken)) = (after_ids.get(*key), after.keys.get(*key)) else {
            continue;
        };
        if let Some(left) = remaining.get_mut(&(*id, *rowid))
            && *left > 0
        {
            *left -= 1;
            continue;
        }
        let group = (broken.table.to_lowercase(), broken.parent.to_lowercase());
        match groups.get(&group).and_then(|index| introduced.get_mut(*index)) {
            Some(group) => group.count += 1,
            None => {
                groups.insert(group, introduced.len());
                introduced.push(IntroducedViolations {
                    table: broken.table.clone(),
                    parent: broken.parent.clone(),
                    count: 1,
                });
            }
        }
    }
    introduced
}

type ViolationKey = (String, String, Vec<String>, Vec<String>);

/// SQLite names tables and columns case-insensitively, and so does the
/// comparison.
fn key(broken: &BrokenKey) -> ViolationKey {
    let folded = |names: &[String]| names.iter().map(|name| name.to_lowercase()).collect();
    (
        broken.table.to_lowercase(),
        broken.parent.to_lowercase(),
        folded(&broken.key.columns),
        folded(&broken.key.parent_columns),
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

    type Row<'a> = (&'a str, Option<i64>, &'a str, &'a [&'a str], &'a [&'a str]);

    fn violation<'a>(table: &'a str, rowid: Option<i64>, parent: &'a str) -> Row<'a> {
        (table, rowid, parent, &["parent"], &["id"])
    }

    fn keyed<'a>(
        table: &'a str,
        rowid: Option<i64>,
        parent: &'a str,
        columns: &'a [&'a str],
        parent_columns: &'a [&'a str],
    ) -> Row<'a> {
        (table, rowid, parent, columns, parent_columns)
    }

    // One key per row, as two keys of the same columns compare alike.
    fn found(rows: &[Row<'_>]) -> Violations {
        let owned = |names: &[&str]| names.iter().map(|name| (*name).to_owned()).collect();
        let mut violations = Violations::default();
        for (table, rowid, parent, columns, parent_columns) in rows {
            let key = violations.add_key(BrokenKey {
                table: (*table).to_owned(),
                parent: (*parent).to_owned(),
                key: ViolatedKey {
                    columns: owned(columns),
                    parent_columns: owned(parent_columns),
                },
            });
            violations.add_row(key, *rowid);
        }
        violations
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

        let introduced = introduced(&renames.apply(found(&before)), &found(&after));

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
            introduced(&found(&before), &found(&after)),
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

        assert!(introduced(&renames.apply(found(&before)), &found(&after)).is_empty());
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

        assert!(introduced(&found(&before), &found(&same)).is_empty());
        assert_eq!(introduced(&found(&before), &found(&more)).len(), 1);
        assert_eq!(introduced(&found(&before), &found(&more))[0].count, 1);
    }

    #[test]
    fn rows_of_one_key_compare_one_for_one_and_name_their_group_in_order() {
        let mut before = Violations::default();
        let broken = |table: &str, parent: &str| BrokenKey {
            table: table.to_owned(),
            parent: parent.to_owned(),
            key: ViolatedKey {
                columns: vec!["a".to_owned()],
                parent_columns: Vec::new(),
            },
        };
        let key = before.add_key(broken("t", "p"));
        for rowid in 0..1_000 {
            before.add_row(key, Some(rowid));
        }
        let mut after = before.clone();
        let other = after.add_key(broken("t", "q"));
        after.add_row(other, Some(5));
        after.add_row(key, Some(1_000));
        after.add_row(other, Some(6));

        assert_eq!(
            introduced(&before, &after),
            [
                IntroducedViolations {
                    table: "t".to_owned(),
                    parent: "q".to_owned(),
                    count: 2
                },
                IntroducedViolations {
                    table: "t".to_owned(),
                    parent: "p".to_owned(),
                    count: 1
                },
            ]
        );
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
