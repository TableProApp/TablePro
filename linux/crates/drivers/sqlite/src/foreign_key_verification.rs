//! Telling the foreign key violations a batch introduced from the ones
//! that were already there.
//!
//! A rebuild has to run with foreign keys off, and the file may hold
//! violations from long before: SQLite does not check rows that were
//! written while foreign keys were off. So the check before the batch
//! and the check after it are compared, and only the difference fails
//! the batch.

use std::collections::HashMap;

use tablepro_core::{DriverError, ServerCode, ServerDiagnostics};

use crate::errors::{SQLITE_CONSTRAINT, SQLITE_CONSTRAINT_FOREIGNKEY};

/// One row of `foreign_key_check`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct Violation {
    pub table: String,
    /// `None` for a WITHOUT ROWID child table, which has no rowid to
    /// name the row by.
    pub rowid: Option<i64>,
    pub parent: String,
}

/// Violations in one child table against one parent, that the batch
/// left behind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct IntroducedViolations {
    pub table: String,
    pub parent: String,
    pub count: usize,
}

/// Name `baseline` rows by the names the tables have after the batch,
/// so a table the batch renamed compares with itself.
pub(crate) fn renamed(baseline: Vec<Violation>, renames: &HashMap<String, String>) -> Vec<Violation> {
    let rename = |name: String| renames.get(&name.to_lowercase()).cloned().unwrap_or(name);
    baseline
        .into_iter()
        .map(|violation| Violation {
            table: rename(violation.table),
            rowid: violation.rowid,
            parent: rename(violation.parent),
        })
        .collect()
}

/// The rows of `after` that `before` does not account for, compared as
/// multisets. Rows without a rowid are all alike, so for a WITHOUT
/// ROWID table it is the count per child and parent that compares.
pub(crate) fn introduced(before: &[Violation], after: &[Violation]) -> Vec<IntroducedViolations> {
    let mut remaining: HashMap<(String, Option<i64>, String), usize> = HashMap::new();
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

/// SQLite names tables case-insensitively, and so does the comparison.
fn key(violation: &Violation) -> (String, Option<i64>, String) {
    (
        violation.table.to_lowercase(),
        violation.rowid,
        violation.parent.to_lowercase(),
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
        Violation {
            table: table.to_owned(),
            rowid,
            parent: parent.to_owned(),
        }
    }

    #[test]
    fn introduced_violations_ignore_baseline_rows_across_rename() {
        let before = vec![
            violation("orders_old", Some(7), "people"),
            violation("lines", Some(1), "orders_old"),
        ];
        let renames = HashMap::from([("orders_old".to_owned(), "orders".to_owned())]);
        let after = vec![
            violation("orders", Some(7), "people"),
            violation("lines", Some(1), "orders"),
            violation("lines", Some(2), "orders"),
        ];

        let introduced = introduced(&renamed(before, &renames), &after);

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
