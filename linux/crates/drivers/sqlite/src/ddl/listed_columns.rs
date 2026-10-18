//! The columns a trigger lists by name. When an ALTER TABLE checks the
//! schema, SQLite resolves every expression of a trigger but not its
//! UPDATE OF list, an INSERT's column list or the columns an UPDATE or
//! an upsert sets (alter.c, `renameResolveTrigger`), so a trigger that
//! lists a dropped column only fails once it fires. RENAME COLUMN
//! rewrites those same lists (`renameColumnFunc`): they are uses.

use std::collections::HashSet;

use tablepro_core::ddl::{
    BuildDdlError, DdlOperation, RefusalReason, SchemaObjectKind, SchemaObjectSource, TableChanges, TableDefinition,
};
use tablepro_core::sql_syntax::script::ScriptTokenKind;

use super::create_table_source::{Token, tokens, unquote};

/// The names of the triggers among `objects` that list `column` of
/// `table`, or whose text does not read and so might.
pub(super) fn listing_triggers<'o>(
    objects: impl Iterator<Item = &'o SchemaObjectSource>,
    table: &str,
    column: &str,
) -> Vec<String> {
    let column = column.to_ascii_lowercase();
    triggers_where(objects, table, |listed| listed.columns.contains(&column))
}

/// An INSERT without a column list takes one value per column, generated
/// ones apart (insert.c, `sqlite3Insert`), and SQLite does not check it
/// when it alters the table, so a trigger with one fails or fills the
/// wrong columns once a column is added or dropped.
pub(super) fn check_positional_inserts(
    original: &TableDefinition,
    changes: &TableChanges,
) -> Result<(), BuildDdlError> {
    let dropped = changes
        .dropped_columns
        .iter()
        .find(|column| !column.info.is_generated)
        .map(|column| (column.name(), DdlOperation::DropColumn));
    let added = changes
        .added_columns
        .first()
        .map(|column| (column.name.as_str(), DdlOperation::AddColumn));
    let Some((column, operation)) = dropped.or(added) else {
        return Ok(());
    };
    let dependents = original
        .source
        .as_ref()
        .map_or(&[][..], |source| source.dependents.as_slice());
    let triggers = triggers_where(dependents.iter(), &original.table.name, |listed| listed.by_position);
    if triggers.is_empty() {
        return Ok(());
    }
    Err(BuildDdlError::Refused {
        column: column.to_owned(),
        operation,
        reason: RefusalReason::InsertedByPosition(triggers),
    })
}

fn triggers_where<'o>(
    objects: impl Iterator<Item = &'o SchemaObjectSource>,
    table: &str,
    uses: impl Fn(&Listed) -> bool,
) -> Vec<String> {
    objects
        .filter(|object| object.kind == SchemaObjectKind::Trigger)
        .filter(|object| {
            let on_table = object.table.eq_ignore_ascii_case(table);
            listed_columns(&object.sql, table, on_table).is_none_or(|listed| uses(&listed))
        })
        .map(|object| object.name.clone())
        .collect()
}

/// What a trigger names of one table where SQLite does not resolve it.
#[derive(Debug, Default, PartialEq, Eq)]
struct Listed {
    /// Folded to ASCII lowercase.
    columns: HashSet<String>,
    /// An INSERT into the table without a column list.
    by_position: bool,
}

/// What `trigger` lists of `table`: its UPDATE OF columns when it is
/// `on_table`, the columns its steps insert into or set in `table`, and
/// whether one inserts into it without naming columns. SQLite refuses a
/// qualified table in a trigger step, so the step's bare name says
/// which table it writes. `None` when the text does not read.
fn listed_columns(trigger: &str, table: &str, on_table: bool) -> Option<Listed> {
    let tokens = tokens(trigger).ok()?;
    let text = Text {
        sql: trigger,
        tokens: &tokens,
    };
    let is_table = |index: usize| text.name(index).is_some_and(|name| name.eq_ignore_ascii_case(table));
    let mut listed = Listed::default();
    // DELETE, INSERT and UPDATE are reserved words, never names, so the
    // first of them is the trigger's event.
    let event =
        (0..tokens.len()).find(|&index| ["DELETE", "INSERT", "UPDATE"].iter().any(|word| text.word(index, word)))?;
    if on_table && text.word(event, "UPDATE") && text.word(event + 1, "OF") {
        text.names_until(event + 2, |index| text.word(index, "ON"), &mut listed.columns);
    }
    // The table of the step's INSERT, whose upsert sets its columns.
    let mut inserting = None;
    for index in event + 1..tokens.len() {
        if text.kind(index) == Some(ScriptTokenKind::Semicolon) {
            inserting = None;
        } else if text.word(index, "INTO") {
            let target = index + 1;
            inserting = Some(target);
            if !is_table(target) {
                continue;
            }
            if text.kind(target + 1) == Some(ScriptTokenKind::OpenParen) {
                text.names_until(
                    target + 2,
                    |index| text.kind(index) == Some(ScriptTokenKind::CloseParen),
                    &mut listed.columns,
                );
            } else {
                listed.by_position = true;
            }
        } else if text.word(index, "UPDATE") {
            let (target, set) = if text.word(index + 1, "SET") {
                (inserting, index + 1)
            } else if text.word(index + 1, "OR") {
                (Some(index + 3), index + 4)
            } else {
                (Some(index + 1), index + 2)
            };
            if target.is_some_and(is_table) && text.word(set, "SET") {
                text.assigned(set + 1, &mut listed.columns);
            }
        }
    }
    Some(listed)
}

struct Text<'s> {
    sql: &'s str,
    tokens: &'s [Token],
}

impl Text<'_> {
    fn kind(&self, index: usize) -> Option<ScriptTokenKind> {
        self.tokens.get(index).map(|token| token.kind)
    }

    fn text(&self, index: usize) -> &str {
        self.tokens
            .get(index)
            .and_then(|token| self.sql.get(token.range.clone()))
            .unwrap_or_default()
    }

    fn word(&self, index: usize, word: &str) -> bool {
        self.kind(index) == Some(ScriptTokenKind::Word) && self.text(index).eq_ignore_ascii_case(word)
    }

    fn name(&self, index: usize) -> Option<String> {
        match self.kind(index)? {
            ScriptTokenKind::Word => Some(self.text(index).to_ascii_lowercase()),
            // SQLite reads a string where it expects a name.
            ScriptTokenKind::QuotedIdentifier | ScriptTokenKind::StringLiteral => {
                Some(unquote(self.text(index)).to_ascii_lowercase())
            }
            _ => None,
        }
    }

    fn names_until(&self, mut index: usize, end: impl Fn(usize) -> bool, into: &mut HashSet<String>) {
        while index < self.tokens.len() && !end(index) {
            into.extend(self.name(index));
            index += 1;
        }
    }

    /// The columns a list of assignments sets, from `index`: `a = 1` or
    /// `(a, b) = (1, 2)`, each the first thing after SET or a comma.
    fn assigned(&self, mut index: usize, into: &mut HashSet<String>) {
        loop {
            if self.kind(index) == Some(ScriptTokenKind::OpenParen) {
                self.names_until(
                    index + 1,
                    |index| self.kind(index) == Some(ScriptTokenKind::CloseParen),
                    into,
                );
            } else {
                into.extend(self.name(index));
            }
            match self.next_assignment(index) {
                Some(next) => index = next,
                None => return,
            }
        }
    }

    /// Where the assignment after the one at `index` starts: past the
    /// next comma outside parentheses, unless the list ends first.
    fn next_assignment(&self, mut index: usize) -> Option<usize> {
        let mut depth = 0usize;
        while let Some(kind) = self.kind(index) {
            match kind {
                ScriptTokenKind::OpenParen => depth += 1,
                ScriptTokenKind::CloseParen => depth = depth.checked_sub(1)?,
                ScriptTokenKind::Semicolon => return None,
                _ if depth > 0 => {}
                ScriptTokenKind::Punct if self.text(index) == "," => return Some(index + 1),
                ScriptTokenKind::Word if self.ends_assignments(index) => return None,
                _ => {}
            }
            index += 1;
        }
        None
    }

    /// An UPDATE's FROM or WHERE, or an upsert's WHERE or next ON
    /// CONFLICT. The FROM of `IS [NOT] DISTINCT FROM` compares.
    fn ends_assignments(&self, index: usize) -> bool {
        let distinct = index.checked_sub(1).is_some_and(|before| self.word(before, "DISTINCT"));
        (self.word(index, "FROM") && !distinct) || self.word(index, "WHERE") || self.word(index, "ON")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted(listed: Option<Listed>) -> Vec<String> {
        let mut columns: Vec<String> = listed.expect("the trigger reads").columns.into_iter().collect();
        columns.sort();
        columns
    }

    #[test]
    fn a_trigger_lists_what_it_watches_inserts_and_sets_in_its_table() {
        let trigger = "CREATE TRIGGER t AFTER UPDATE OF a, \"B\" ON kept BEGIN INSERT OR REPLACE INTO kept (c, [d]) \
                       VALUES (new.z, 1); INSERT INTO log (e) SELECT f FROM kept; UPDATE OR IGNORE Kept SET g = \
                       (SELECT x FROM y WHERE w = 1), (h, `i`) = (2, 3), j == coalesce(k, 0), 'l' = new.a IS NOT \
                       DISTINCT FROM old.a, m = CASE WHEN n THEN 1 END FROM other WHERE o = 2; UPDATE log SET p = 1; \
                       REPLACE INTO 'kept' (q) VALUES (1); INSERT INTO kept (r) VALUES (1) ON CONFLICT (s) DO UPDATE \
                       SET t = excluded.t WHERE u = 1 ON CONFLICT DO NOTHING; INSERT INTO log (v) VALUES (1) ON \
                       CONFLICT DO UPDATE SET w = 1; END";

        assert_eq!(
            sorted(listed_columns(trigger, "KEPT", true)),
            ["a", "b", "c", "d", "g", "h", "i", "j", "l", "m", "q", "r", "t"]
        );
        assert_eq!(
            sorted(listed_columns(trigger, "kept", false)),
            ["c", "d", "g", "h", "i", "j", "l", "m", "q", "r", "t"]
        );
    }

    #[test]
    fn the_triggers_event_and_its_reads_list_nothing() {
        for trigger in [
            "CREATE TRIGGER t AFTER INSERT ON kept BEGIN SELECT new.a; END",
            "CREATE TRIGGER t AFTER UPDATE ON kept WHEN new.a > 0 BEGIN DELETE FROM kept WHERE b = old.b; END",
            "CREATE TRIGGER t INSTEAD OF UPDATE ON kept BEGIN SELECT 'UPDATE kept SET a = 1'; END",
            "CREATE TRIGGER t AFTER INSERT ON kept BEGIN INSERT INTO kept SELECT * FROM other; END",
        ] {
            assert_eq!(
                sorted(listed_columns(trigger, "kept", true)),
                Vec::<String>::new(),
                "{trigger}"
            );
        }
    }

    #[test]
    fn an_insert_without_a_column_list_into_the_table_takes_values_by_position() {
        let by_position = |trigger: &str| listed_columns(trigger, "kept", false).map(|listed| listed.by_position);

        for trigger in [
            "CREATE TRIGGER t AFTER INSERT ON log BEGIN INSERT INTO kept VALUES (new.a, 1); END",
            "CREATE TRIGGER t AFTER INSERT ON log BEGIN INSERT OR IGNORE INTO \"Kept\" SELECT * FROM log; END",
            "CREATE TRIGGER t AFTER INSERT ON log BEGIN SELECT 1; REPLACE INTO kept VALUES (1); END",
        ] {
            assert_eq!(by_position(trigger), Some(true), "{trigger}");
        }
        for trigger in [
            "CREATE TRIGGER t AFTER INSERT ON log BEGIN INSERT INTO kept (a) VALUES (new.a); END",
            "CREATE TRIGGER t AFTER INSERT ON kept BEGIN INSERT INTO log VALUES (new.a); END",
            "CREATE TRIGGER t AFTER INSERT ON log BEGIN SELECT 'INSERT INTO kept VALUES (1)'; END",
        ] {
            assert_eq!(by_position(trigger), Some(false), "{trigger}");
        }
    }

    #[test]
    fn a_trigger_that_does_not_read_lists_nothing_it_can_name() {
        assert_eq!(
            listed_columns(
                "CREATE TRIGGER t AFTER INSERT ON kept BEGIN SELECT 'a; END",
                "kept",
                true
            ),
            None
        );
    }
}
