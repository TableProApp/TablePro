//! Telling the foreign key violations a batch introduced from the ones
//! that were already there.
//!
//! A rebuild has to run with foreign keys off, and the file may hold
//! violations from long before: SQLite does not check rows that were
//! written while foreign keys were off. So the check before the batch
//! and the check after it are compared, and only the difference fails
//! the batch.

use std::collections::{HashMap, HashSet};

use tablepro_core::ddl::ColumnRename;
use tablepro_core::{CatalogBudget, DriverError, ServerCode, ServerDiagnostics};

use crate::errors::{SQLITE_CONSTRAINT, SQLITE_CONSTRAINT_FOREIGNKEY};

// The rows of `foreign_key_check` for each child table checked, in its order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Violations {
    tables: Vec<TableViolations>,
}

// A crafted file can break thousands of keys of a long-named table in millions of rows, so names are held once and
// rows only up to the budget, past which the table compares by count per key, as renumbered rows do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TableViolations {
    table: String,
    keys: Vec<BrokenKey>,
    counts: Vec<usize>,
    rows: Option<Vec<(usize, Option<i64>)>>,
}

const ROW_BYTES: usize = size_of::<(usize, Option<i64>)>();

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BrokenKey {
    pub parent: String,
    pub key: ViolatedKey,
}

impl TableViolations {
    pub(crate) fn new(table: String) -> Self {
        Self {
            table,
            keys: Vec::new(),
            counts: Vec::new(),
            rows: Some(Vec::new()),
        }
    }

    pub(crate) fn add_key(&mut self, key: BrokenKey) -> usize {
        self.keys.push(key);
        self.counts.push(0);
        self.keys.len() - 1
    }

    pub(crate) fn add_row(&mut self, key: usize, rowid: Option<i64>, budget: &mut CatalogBudget) {
        if let Some(count) = self.counts.get_mut(key) {
            *count += 1;
        }
        let Some(rows) = &mut self.rows else {
            return;
        };
        match budget.charge(ROW_BYTES) {
            Ok(()) => rows.push((key, rowid)),
            Err(_) => {
                budget.release(ROW_BYTES.saturating_mul(rows.len() + 1));
                self.rows = None;
            }
        }
    }
}

impl Violations {
    pub(crate) fn push(&mut self, table: TableViolations) {
        if table.counts.iter().any(|count| *count > 0) {
            self.tables.push(table);
        }
    }

    pub(crate) fn extend(&mut self, other: Violations) {
        self.tables.extend(other.tables);
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
            tables: baseline
                .tables
                .into_iter()
                .map(|checked| TableViolations {
                    keys: checked
                        .keys
                        .into_iter()
                        .map(|broken| BrokenKey {
                            key: ViolatedKey {
                                columns: self.column_names(&checked.table, broken.key.columns),
                                parent_columns: self.column_names(&broken.parent, broken.key.parent_columns),
                            },
                            parent: self.table_name(broken.parent),
                        })
                        .collect(),
                    table: self.table_name(checked.table),
                    counts: checked.counts,
                    rows: checked.rows,
                })
                .collect(),
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
    let mut ids = KeyIds::default();
    let before_ids: Vec<(usize, Vec<usize>)> = before.tables.iter().map(|checked| ids.of(checked)).collect();
    let after_ids: Vec<(usize, Vec<usize>)> = after.tables.iter().map(|checked| ids.of(checked)).collect();
    // A table whose rows were let go on either side compares by count.
    let counted: HashSet<usize> = before
        .tables
        .iter()
        .zip(&before_ids)
        .chain(after.tables.iter().zip(&after_ids))
        .filter(|(checked, _)| checked.rows.is_none())
        .map(|(_, (table, _))| *table)
        .collect();
    let mut remaining: HashMap<(usize, Option<i64>), usize> = HashMap::new();
    let mut counts: HashMap<usize, usize> = HashMap::new();
    for (checked, (table, keys)) in before.tables.iter().zip(&before_ids) {
        match (counted.contains(table), &checked.rows) {
            (false, Some(rows)) => {
                for (key, rowid) in rows {
                    if let Some(id) = keys.get(*key) {
                        *remaining.entry((*id, *rowid)).or_default() += 1;
                    }
                }
            }
            _ => {
                for (id, count) in keys.iter().zip(&checked.counts) {
                    *counts.entry(*id).or_default() += count;
                }
            }
        }
    }
    let mut found = Introduced::default();
    for (checked, (table, keys)) in after.tables.iter().zip(&after_ids) {
        match (counted.contains(table), &checked.rows) {
            (false, Some(rows)) => {
                for (key, rowid) in rows {
                    let Some(id) = keys.get(*key) else {
                        continue;
                    };
                    if let Some(left) = remaining.get_mut(&(*id, *rowid))
                        && *left > 0
                    {
                        *left -= 1;
                        continue;
                    }
                    found.add(*table, checked, *key, 1);
                }
            }
            _ => {
                for (key, (id, count)) in keys.iter().zip(&checked.counts).enumerate() {
                    let before = counts.entry(*id).or_default();
                    let kept = (*before).min(*count);
                    *before -= kept;
                    found.add(*table, checked, key, count - kept);
                }
            }
        }
    }
    found.groups
}

// The groups by child and parent, in the order their first row came.
#[derive(Default)]
struct Introduced {
    groups: Vec<IntroducedViolations>,
    positions: HashMap<(usize, String), usize>,
}

impl Introduced {
    fn add(&mut self, table: usize, checked: &TableViolations, key: usize, count: usize) {
        let Some(broken) = checked.keys.get(key).filter(|_| count > 0) else {
            return;
        };
        let group = (table, broken.parent.to_lowercase());
        match self.positions.get(&group).and_then(|index| self.groups.get_mut(*index)) {
            Some(found) => found.count += count,
            None => {
                self.positions.insert(group, self.groups.len());
                self.groups.push(IntroducedViolations {
                    table: checked.table.clone(),
                    parent: broken.parent.clone(),
                    count,
                });
            }
        }
    }
}

// SQLite names tables and columns case-insensitively, and so does the comparison. A table's name is folded once,
// whatever number of keys it breaks.
#[derive(Default)]
struct KeyIds {
    tables: HashMap<String, usize>,
    keys: HashMap<(usize, String, Vec<String>, Vec<String>), usize>,
}

impl KeyIds {
    fn of(&mut self, checked: &TableViolations) -> (usize, Vec<usize>) {
        let next = self.tables.len();
        let table = *self.tables.entry(checked.table.to_lowercase()).or_insert(next);
        let folded = |names: &[String]| names.iter().map(|name| name.to_lowercase()).collect();
        let keys = checked
            .keys
            .iter()
            .map(|broken| {
                let next = self.keys.len();
                *self
                    .keys
                    .entry((
                        table,
                        broken.parent.to_lowercase(),
                        folded(&broken.key.columns),
                        folded(&broken.key.parent_columns),
                    ))
                    .or_insert(next)
            })
            .collect();
        (table, keys)
    }
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

    // One key per row, as two keys of the same columns compare alike, and one table per name in the order it comes.
    fn found(rows: &[Row<'_>]) -> Violations {
        let owned = |names: &[&str]| names.iter().map(|name| (*name).to_owned()).collect();
        let mut tables: Vec<TableViolations> = Vec::new();
        for (table, rowid, parent, columns, parent_columns) in rows {
            let position = match tables.iter().position(|checked| checked.table == *table) {
                Some(position) => position,
                None => {
                    tables.push(TableViolations::new((*table).to_owned()));
                    tables.len() - 1
                }
            };
            let checked = &mut tables[position];
            let key = checked.add_key(BrokenKey {
                parent: (*parent).to_owned(),
                key: ViolatedKey {
                    columns: owned(columns),
                    parent_columns: owned(parent_columns),
                },
            });
            checked.add_row(key, *rowid, &mut CatalogBudget::default());
        }
        let mut violations = Violations::default();
        for checked in tables {
            violations.push(checked);
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
        let broken = |parent: &str| BrokenKey {
            parent: parent.to_owned(),
            key: ViolatedKey {
                columns: vec!["a".to_owned()],
                parent_columns: Vec::new(),
            },
        };
        let budget = &mut CatalogBudget::default();
        let mut checked = TableViolations::new("t".to_owned());
        let key = checked.add_key(broken("p"));
        for rowid in 0..1_000 {
            checked.add_row(key, Some(rowid), budget);
        }
        let mut before = Violations::default();
        before.push(checked.clone());
        let other = checked.add_key(broken("q"));
        checked.add_row(other, Some(5), budget);
        checked.add_row(key, Some(1_000), budget);
        checked.add_row(other, Some(6), budget);
        let mut after = Violations::default();
        after.push(checked);

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
    fn rows_past_the_budget_compare_by_count_per_key() {
        let broken = |parent: &str| BrokenKey {
            parent: parent.to_owned(),
            key: ViolatedKey {
                columns: vec!["a".to_owned()],
                parent_columns: Vec::new(),
            },
        };
        let rows = |count: i64, budget: &mut CatalogBudget| {
            let mut checked = TableViolations::new("t".to_owned());
            let (p, q) = (checked.add_key(broken("p")), checked.add_key(broken("q")));
            for rowid in 0..count {
                checked.add_row(p, Some(rowid), budget);
                checked.add_row(q, Some(rowid), budget);
            }
            let mut found = Violations::default();
            found.push(checked);
            found
        };
        let budget = &mut CatalogBudget::new(tablepro_core::ByteLimit::new(4_096).unwrap());

        let before = rows(1_000, budget);
        let same = rows(1_000, budget);
        let more = rows(1_001, budget);

        assert!(before.tables[0].rows.is_none(), "the rows passed the budget");
        assert!(introduced(&before, &same).is_empty());
        assert_eq!(
            introduced(&before, &more),
            [
                IntroducedViolations {
                    table: "t".to_owned(),
                    parent: "p".to_owned(),
                    count: 1
                },
                IntroducedViolations {
                    table: "t".to_owned(),
                    parent: "q".to_owned(),
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
