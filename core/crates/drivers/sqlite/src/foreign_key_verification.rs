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
use tablepro_core::{CatalogBudget, DriverError, ServerCode, ServerDiagnostics};

use crate::errors::{SQLITE_CONSTRAINT, SQLITE_CONSTRAINT_FOREIGNKEY};

// The rows of `foreign_key_check` for each child table checked, in its order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Violations {
    tables: Vec<TableViolations>,
}

// A crafted file can break thousands of keys of a long-named table in millions of rows, so names are held once and
// every row and key is charged to the save's budget: past it the save stops rather than compare less.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TableViolations {
    table: String,
    keys: Vec<BrokenKey>,
    rows: Vec<(usize, Option<i64>)>,
}

const ROW_BYTES: usize = size_of::<(usize, Option<i64>)>();

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BrokenKey {
    pub parent: String,
    pub key: ViolatedKey,
}

impl TableViolations {
    pub(crate) fn new(table: String, budget: &mut CatalogBudget) -> Result<Self, DriverError> {
        Ok(Self {
            table: budget.keep(table)?,
            keys: Vec::new(),
            rows: Vec::new(),
        })
    }

    pub(crate) fn add_key(&mut self, key: BrokenKey, budget: &mut CatalogBudget) -> Result<usize, DriverError> {
        budget.charge_text(&key.parent)?;
        budget.charge_texts(key.key.columns.iter().chain(&key.key.parent_columns))?;
        self.keys.push(key);
        Ok(self.keys.len() - 1)
    }

    pub(crate) fn add_row(
        &mut self,
        key: usize,
        rowid: Option<i64>,
        budget: &mut CatalogBudget,
    ) -> Result<(), DriverError> {
        budget.charge(ROW_BYTES)?;
        self.rows.push((key, rowid));
        Ok(())
    }
}

impl Violations {
    pub(crate) fn push(&mut self, table: TableViolations) {
        if !table.rows.is_empty() {
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
pub(crate) fn introduced(
    before: &Violations,
    after: &Violations,
    budget: &mut CatalogBudget,
) -> Result<Vec<IntroducedViolations>, DriverError> {
    let mut ids = KeyIds::default();
    let mut remaining: HashMap<(usize, Option<i64>), usize> = HashMap::new();
    for checked in &before.tables {
        let (_, keys) = ids.of(checked);
        for (key, rowid) in &checked.rows {
            if let Some(id) = keys.get(*key) {
                *remaining.entry((*id, *rowid)).or_default() += 1;
            }
        }
    }
    let mut found = Introduced::default();
    for checked in &after.tables {
        let (table, keys) = ids.of(checked);
        let mut groups: Vec<Option<usize>> = vec![None; checked.keys.len()];
        for (key, rowid) in &checked.rows {
            let Some(id) = keys.get(*key) else {
                continue;
            };
            if let Some(left) = remaining.get_mut(&(*id, *rowid))
                && *left > 0
            {
                *left -= 1;
                continue;
            }
            if let Some(group) = groups.get_mut(*key) {
                let group = match group {
                    Some(group) => *group,
                    None => *group.insert(found.group_of(table, checked, *key, budget)?),
                };
                found.add(group);
            }
        }
    }
    Ok(found.groups)
}

// The groups by child and parent, in the order their first row came. Each key's group is looked up once, not on
// each of millions of rows, since a parent's name can be long.
#[derive(Default)]
struct Introduced {
    groups: Vec<IntroducedViolations>,
    positions: HashMap<(usize, String), usize>,
}

impl Introduced {
    // Each group holds the child's and the parent's names, which a crafted file makes long and many.
    fn group_of(
        &mut self,
        table: usize,
        checked: &TableViolations,
        key: usize,
        budget: &mut CatalogBudget,
    ) -> Result<usize, DriverError> {
        let Some(broken) = checked.keys.get(key) else {
            return Ok(usize::MAX);
        };
        let next = self.groups.len();
        let group = *self
            .positions
            .entry((table, broken.parent.to_lowercase()))
            .or_insert(next);
        if group == next {
            self.groups.push(IntroducedViolations {
                table: budget.keep(checked.table.clone())?,
                parent: budget.keep(broken.parent.clone())?,
                count: 0,
            });
        }
        Ok(group)
    }

    fn add(&mut self, group: usize) {
        if let Some(found) = self.groups.get_mut(group) {
            found.count += 1;
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
    // The first few say where to look; a crafted file can make thousands, each with long names.
    const LISTED: usize = 10;
    let mut listed: Vec<String> = introduced
        .iter()
        .take(LISTED)
        .map(|group| {
            format!(
                "{} rows of {} point at missing rows of {}",
                group.count, group.table, group.parent
            )
        })
        .collect();
    if introduced.len() > LISTED {
        listed.push(format!("and {} more", introduced.len() - LISTED));
    }
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
                    tables.push(TableViolations::new((*table).to_owned(), &mut CatalogBudget::default()).unwrap());
                    tables.len() - 1
                }
            };
            let checked = &mut tables[position];
            let budget = &mut CatalogBudget::default();
            let key = checked
                .add_key(
                    BrokenKey {
                        parent: (*parent).to_owned(),
                        key: ViolatedKey {
                            columns: owned(columns),
                            parent_columns: owned(parent_columns),
                        },
                    },
                    budget,
                )
                .unwrap();
            checked.add_row(key, *rowid, budget).unwrap();
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

        let introduced = introduced(
            &renames.apply(found(&before)),
            &found(&after),
            &mut CatalogBudget::default(),
        )
        .unwrap();

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
            introduced(&found(&before), &found(&after), &mut CatalogBudget::default()).unwrap(),
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

        assert!(
            introduced(
                &renames.apply(found(&before)),
                &found(&after),
                &mut CatalogBudget::default()
            )
            .unwrap()
            .is_empty()
        );
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

        assert!(
            introduced(&found(&before), &found(&same), &mut CatalogBudget::default())
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            introduced(&found(&before), &found(&more), &mut CatalogBudget::default())
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            introduced(&found(&before), &found(&more), &mut CatalogBudget::default()).unwrap()[0].count,
            1
        );
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
        let mut checked = TableViolations::new("t".to_owned(), budget).unwrap();
        let key = checked.add_key(broken("p"), budget).unwrap();
        for rowid in 0..1_000 {
            checked.add_row(key, Some(rowid), budget).unwrap();
        }
        let mut before = Violations::default();
        before.push(checked.clone());
        let other = checked.add_key(broken("q"), budget).unwrap();
        checked.add_row(other, Some(5), budget).unwrap();
        checked.add_row(key, Some(1_000), budget).unwrap();
        checked.add_row(other, Some(6), budget).unwrap();
        let mut after = Violations::default();
        after.push(checked);

        assert_eq!(
            introduced(&before, &after, budget).unwrap(),
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
    fn rows_past_the_budget_stop_the_check() {
        let budget = &mut CatalogBudget::new(tablepro_core::ByteLimit::new(4_096).unwrap());
        let mut checked = TableViolations::new("t".to_owned(), budget).unwrap();
        let key = checked
            .add_key(
                BrokenKey {
                    parent: "p".to_owned(),
                    key: ViolatedKey::default(),
                },
                budget,
            )
            .unwrap();

        let stopped = (0..1_000).try_for_each(|rowid| checked.add_row(key, Some(rowid), budget));

        assert_eq!(stopped, Err(DriverError::CatalogTooLarge { limit_bytes: 4_096 }));
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
