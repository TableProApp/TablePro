//! A table rebuilt for the changes SQLite's ALTER TABLE cannot make, by
//! the procedure of lang_altertable.html section 7: a new table in the
//! revised shape, the rows copied into it, the old table dropped and the
//! new one renamed into its place, then its indexes, triggers and views
//! made again. The write protocol runs the plan in one transaction with
//! foreign keys off, and checks them before it commits.
//!
//! The new table is the stored CREATE TABLE with only the edited parts
//! replaced, so a CHECK, a COLLATE, a generated expression or a comment
//! the app does not model stays as it was written. Kept columns keep
//! their names through the copy, and renames run natively at the end,
//! where SQLite carries them into every index, trigger and view.

use std::collections::{HashMap, HashSet};
use std::ops::Range;

use tablepro_core::ddl::ddl_sql::{column_list, default_sql};
use tablepro_core::ddl::{
    BuildDdlError, ColumnAlteration, ColumnDefinition, ColumnRename, DdlOperation, DdlPlan, DdlPrecondition,
    DraftColumn, RecreatedObject, RefusalReason, SchemaObjectKind, SchemaObjectSource, TableChanges, TableDefinition,
    TableRebuild, order_renames,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};
use tablepro_core::statement::{Statement, StatementBuilder};
use tablepro_core::{ForeignKeyCheck, ForeignKeyMode};

use super::column_constraint_segment::ColumnConstraintKind;
use super::create_table_source::{CreateTableSource, Token, tokens, unquote};
use super::native_change_rules::names;
use super::source_element::{SourceColumn, SourceElement, TableConstraint, TableConstraintKind};
use super::{default_clause, foreign_key_constraint};
use crate::catalog::{MAIN_SCHEMA, words};
use crate::dialect::SqliteDialect;

/// The new table is built under this prefix and renamed over the old
/// one once the rows are in it.
const REBUILD_PREFIX: &str = "_tablepro_rebuild_";

/// An added column whose name a kept column holds until its own rename
/// runs is created under this prefix and renamed last.
const ADDED_PREFIX: &str = "__tablepro_added_";

pub(super) fn plan(
    dialect: &SqliteDialect,
    original: &TableDefinition,
    source: &CreateTableSource<'_>,
    changes: &TableChanges,
) -> Result<DdlPlan, BuildDdlError> {
    let naming = Naming::new(original, changes);
    let mut rebuild = Rebuild {
        dialect,
        original,
        source,
        changes,
        dependents: original
            .source
            .as_ref()
            .map_or(&[][..], |source| source.dependents.as_slice()),
        naming,
        key: Key::Kept,
        dropped_keys: HashSet::new(),
    };
    rebuild.key = rebuild.written_key()?;
    rebuild.check_numbering()?;
    rebuild.dropped_keys = rebuild.find_dropped_keys()?;
    rebuild.check_dropped_columns()?;
    rebuild.plan()
}

/// The primary key of the new table.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Key {
    /// As the stored text declares it.
    Kept,
    /// Written again: the columns under the names they are created with,
    /// and the one column that takes AUTOINCREMENT on its own definition.
    Written {
        columns: Vec<String>,
        autoincrement: Option<String>,
    },
}

/// Where each column of the finished table is while the rebuild runs.
struct Naming {
    /// The name a column is created under in the new table, by its
    /// final name folded.
    created: HashMap<String, String>,
    /// The added columns, each under the name it is created with.
    added: Vec<DraftColumn>,
    /// The renames left for after the rebuild: the edit's own, and the
    /// added columns stepping out of a temporary name.
    renames: Vec<ColumnRename>,
    /// The columns of the new table as it is created.
    occupied: Vec<String>,
}

impl Naming {
    fn new(original: &TableDefinition, changes: &TableChanges) -> Self {
        let mut created = HashMap::new();
        let mut occupied = Vec::new();
        for column in original
            .columns
            .iter()
            .filter(|column| !dropped(changes, column.name()))
        {
            created.insert(fold(&final_name(changes, column.name())), column.name().to_owned());
            occupied.push(column.name().to_owned());
        }
        let mut taken: HashSet<String> = occupied.iter().map(|name| fold(name)).collect();
        let mut reserved: HashSet<String> = taken.clone();
        reserved.extend(created.keys().cloned());
        reserved.extend(changes.added_columns.iter().map(|column| fold(&column.name)));
        let mut renames = changes.renamed_columns.clone();
        let mut added = Vec::new();
        let mut next = 1usize;
        for column in &changes.added_columns {
            let mut name = column.name.clone();
            if taken.contains(&fold(&name)) {
                let temporary = loop {
                    let candidate = format!("{ADDED_PREFIX}{next}");
                    next += 1;
                    if !reserved.contains(&fold(&candidate)) {
                        break candidate;
                    }
                };
                renames.push(ColumnRename {
                    from: temporary.clone(),
                    to: column.name.clone(),
                });
                name = temporary;
            }
            taken.insert(fold(&name));
            reserved.insert(fold(&name));
            created.insert(fold(&column.name), name.clone());
            occupied.push(name.clone());
            added.push(DraftColumn { name, ..column.clone() });
        }
        Self {
            created,
            added,
            renames,
            occupied,
        }
    }

    fn created<'n>(&'n self, final_name: &'n str) -> &'n str {
        self.created.get(&fold(final_name)).map_or(final_name, String::as_str)
    }

    fn ordered_renames(&self) -> Vec<ColumnRename> {
        order_renames(
            &self.renames,
            self.occupied.iter().map(String::as_str),
            std::iter::empty(),
        )
    }
}

struct Rebuild<'a> {
    dialect: &'a SqliteDialect,
    original: &'a TableDefinition,
    source: &'a CreateTableSource<'a>,
    changes: &'a TableChanges,
    dependents: &'a [SchemaObjectSource],
    naming: Naming,
    key: Key,
    /// The foreign keys the edit drops, by their element and, for an
    /// inline one, their segment.
    dropped_keys: HashSet<(usize, Option<usize>)>,
}

impl Rebuild<'_> {
    fn plan(&self) -> Result<DdlPlan, BuildDdlError> {
        let table = &self.original.table;
        let schema = table.schema.clone();
        let temporary = TableRef::new(schema.clone(), format!("{REBUILD_PREFIX}{}", table.name));
        let qualified = self.dialect.qualify(table);
        let create = self.create_statement(&temporary)?;
        let copy = self.copy_statement(&temporary)?;

        let mut statements = Vec::new();
        // Dropped first, as the native plan does: SQLite refuses to drop an
        // index it made for a constraint, and says so here rather than the
        // rebuild quietly keeping it.
        for index in &self.changes.dropped_indexes {
            let index = TableRef::new(schema.clone(), index.name.clone());
            statements.push(format!("DROP INDEX {}", self.dialect.qualify(&index)));
        }
        // The rename below checks every view and trigger in the schema,
        // and fails on one that names a table that is not there.
        let elsewhere: Vec<&SchemaObjectSource> = self.dependents.iter().filter(|object| !self.owned(object)).collect();
        for kind in [SchemaObjectKind::Trigger, SchemaObjectKind::View] {
            for object in elsewhere.iter().rev().filter(|object| object.kind == kind) {
                let keyword = match kind {
                    SchemaObjectKind::Trigger => "TRIGGER",
                    _ => "VIEW",
                };
                let name = TableRef::new(schema.clone(), object.name.clone());
                statements.push(format!("DROP {keyword} {}", self.dialect.qualify(&name)));
            }
        }
        statements.push(create);
        statements.push(copy);
        if self.carries_sequence() {
            let sequence = self.dialect.qualify(&TableRef::new(schema.clone(), "sqlite_sequence"));
            let new_name = text_literal(&temporary.name);
            statements.push(format!("DELETE FROM {sequence} WHERE name = {new_name}"));
            statements.push(format!(
                "INSERT INTO {sequence} (name, seq) SELECT {new_name}, seq FROM {sequence} WHERE name = {} COLLATE \
                 NOCASE",
                text_literal(&table.name)
            ));
        }
        statements.push(format!("DROP TABLE {qualified}"));
        statements.push(format!(
            "ALTER TABLE {} RENAME TO {}",
            self.dialect.qualify(&temporary),
            self.dialect.quote_identifier(&table.name)
        ));
        for object in self.recreated() {
            let sql = replayable(self.dialect, &object.sql, schema.as_deref())
                .ok_or_else(|| BuildDdlError::UnreplayableDependent(object.name.clone()))?;
            statements.push(sql);
        }
        for rename in self.naming.ordered_renames() {
            statements.push(format!(
                "ALTER TABLE {qualified} RENAME COLUMN {} TO {}",
                self.dialect.quote_identifier(&rename.from),
                self.dialect.quote_identifier(&rename.to)
            ));
        }
        if let Some(name) = &self.changes.renamed_table {
            statements.push(format!(
                "ALTER TABLE {qualified} RENAME TO {}",
                self.dialect.quote_identifier(name)
            ));
        }
        let target = self.changes.target(table);
        statements.extend(
            self.changes
                .added_indexes
                .iter()
                .map(|index| self.dialect.create_index(&target, index)),
        );

        let mut plan = DdlPlan::from_sql(statements);
        plan.foreign_keys = ForeignKeyMode::SuspendedThenVerified {
            checks: self.checks(&target),
        };
        plan.precondition = Some(DdlPrecondition {
            probe: self.unchanged_probe(),
            rows: 0,
        });
        plan.rebuild = Some(TableRebuild {
            recreated: self
                .recreated()
                .map(|object| RecreatedObject {
                    kind: object.kind,
                    name: object.name.clone(),
                })
                .collect(),
            renumbers_rowids: self.rowids_renumbered(),
        });
        Ok(plan)
    }

    /// A count of what differs between the schema the plan was built
    /// from and the one there now: the table's CREATE TABLE, its own
    /// indexes and triggers, the views and triggers elsewhere the rebuild
    /// makes again, and the key columns of other tables that point at it.
    /// A view or trigger that came since and names the table makes the
    /// rename refuse on its own.
    ///
    /// Every name but the table's own was read from the catalogue, so
    /// they compare exactly. The table's is matched without regard to
    /// case, as SQLite matches it, and left out of the comparison.
    fn unchanged_probe(&self) -> Statement {
        let table = &self.original.table;
        let catalogue = self
            .dialect
            .qualify(&TableRef::new(table.schema.clone(), "sqlite_schema"));
        let name = text_literal(&table.name);
        let create = self
            .original
            .source
            .as_ref()
            .map_or("", |source| source.create_statement.as_str());
        let mut objects = vec![format!("('table', '', {})", text_literal(create))];
        objects.extend(self.dependents.iter().map(|object| {
            let kind = match object.kind {
                SchemaObjectKind::Index => "index",
                SchemaObjectKind::Trigger => "trigger",
                SchemaObjectKind::View => "view",
            };
            format!(
                "('{kind}', {}, {})",
                text_literal(&object.name),
                text_literal(&object.sql)
            )
        }));
        let elsewhere: Vec<String> = self
            .dependents
            .iter()
            .filter(|object| !self.owned(object))
            .map(|object| text_literal(&object.name))
            .collect();
        let mut scope = format!(
            "(type = 'table' AND name = {name} COLLATE NOCASE) OR (type IN ('index', 'trigger') AND tbl_name = \
             {name} COLLATE NOCASE AND sql IS NOT NULL)"
        );
        if !elsewhere.is_empty() {
            scope.push_str(&format!(
                " OR (type IN ('view', 'trigger') AND name IN ({}))",
                elsewhere.join(", ")
            ));
        }
        let objects_now =
            format!("SELECT type, CASE type WHEN 'table' THEN '' ELSE name END, sql FROM {catalogue} WHERE {scope}");

        let schema = table
            .schema
            .as_deref()
            .filter(|schema| !schema.is_empty())
            .unwrap_or(MAIN_SCHEMA);
        let children_now = format!(
            "SELECT m.name, f.\"from\" FROM {catalogue} m, pragma_foreign_key_list(m.name, {}) f WHERE m.type = \
             'table' AND f.\"table\" = {name} COLLATE NOCASE",
            text_literal(schema)
        );
        let children: Vec<String> = self
            .original
            .inbound_foreign_keys
            .iter()
            .flat_map(|key| {
                key.columns
                    .iter()
                    .map(|column| format!("({}, {})", text_literal(&key.table.name), text_literal(column)))
            })
            .collect();

        let mut builder = StatementBuilder::new();
        builder.push_sql(&format!(
            "SELECT {} + {}",
            differences(&objects_now, &objects),
            differences(&children_now, &children)
        ));
        builder.finish()
    }

    /// The rebuilt table under both its names, and every table whose
    /// foreign keys point at it, since their rows now point into a new
    /// table.
    fn checks(&self, target: &TableRef) -> Vec<ForeignKeyCheck> {
        let table = &self.original.table;
        let rebuilt = ForeignKeyCheck::new(Some(table.clone()), target.clone());
        let mut checks = vec![match self.rowids_renumbered() {
            true => rebuilt.renumbered(),
            false => rebuilt,
        }];
        for key in &self.original.inbound_foreign_keys {
            let child = &key.table;
            let known = same_table(child, table)
                || checks
                    .iter()
                    .any(|check| check.before.as_ref().is_some_and(|before| same_table(before, child)));
            if !known {
                checks.push(ForeignKeyCheck::same_table(child.clone()));
            }
        }
        checks
    }

    /// An index or trigger on the table goes with it when it is dropped.
    fn owned(&self, object: &SchemaObjectSource) -> bool {
        matches!(object.kind, SchemaObjectKind::Index | SchemaObjectKind::Trigger)
            && object.table.eq_ignore_ascii_case(&self.original.table.name)
    }

    /// The dependents made again after the rename, in the order the
    /// schema first made them.
    fn recreated(&self) -> impl Iterator<Item = &SchemaObjectSource> {
        self.dependents.iter().filter(|object| {
            !(object.kind == SchemaObjectKind::Index
                && self
                    .changes
                    .dropped_indexes
                    .iter()
                    .any(|index| index.name.eq_ignore_ascii_case(&object.name)))
        })
    }

    fn carries_sequence(&self) -> bool {
        let before = self.source.autoincrement_column().is_some();
        let after = match &self.key {
            Key::Kept => before,
            Key::Written { autoincrement, .. } => autoincrement.is_some(),
        };
        before && after
    }

    fn alteration(&self, original: &str) -> Option<&ColumnAlteration> {
        self.changes
            .altered_columns
            .iter()
            .find(|alteration| alteration.original.name() == original)
    }

    fn altered_to(&self, final_name: &str) -> Option<&ColumnAlteration> {
        self.changes
            .altered_columns
            .iter()
            .find(|alteration| alteration.draft.name.eq_ignore_ascii_case(final_name))
    }

    fn added(&self, final_name: &str) -> Option<&DraftColumn> {
        self.changes
            .added_columns
            .iter()
            .find(|column| column.name.eq_ignore_ascii_case(final_name))
    }

    /// The kept column that ends up as `final_name`.
    fn kept(&self, final_name: &str) -> Option<&ColumnDefinition> {
        let created = self.naming.created(final_name);
        self.original
            .columns
            .iter()
            .filter(|column| !dropped(self.changes, column.name()))
            .find(|column| column.name() == created)
    }

    /// The primary key the finished table has, by final names.
    fn final_key(&self) -> Vec<String> {
        if let Some(change) = &self.changes.primary_key {
            return change.to.clone();
        }
        let key: Vec<String> = match &self.original.primary_key {
            Some(key) => key.columns.clone(),
            None => self
                .original
                .columns
                .iter()
                .filter(|column| column.info.primary_key)
                .map(|column| column.name().to_owned())
                .collect(),
        };
        key.iter().map(|name| final_name(self.changes, name)).collect()
    }

    fn declared_type(&self, final_name: &str) -> Result<String, BuildDdlError> {
        if let Some(alteration) = self.altered_to(final_name) {
            let column_type = &alteration.draft.column_type;
            return Ok(column_type.resolve(self.dialect, alteration.original.name())?.sql);
        }
        if let Some(column) = self.added(final_name) {
            return Ok(column.column_type.resolve(self.dialect, &column.name)?.sql);
        }
        Ok(self
            .kept(final_name)
            .and_then(|column| column.info.column_type.catalog.as_ref())
            .map(|catalog| catalog.declaration.as_sql().to_owned())
            .unwrap_or_default())
    }

    /// Whether the key column takes AUTOINCREMENT. One the edit left
    /// alone keeps what it was declared with.
    fn numbers_itself(&self, final_name: &str) -> bool {
        if let Some(alteration) = self.altered_to(final_name) {
            return alteration.draft.auto_increment;
        }
        if let Some(column) = self.added(final_name) {
            return column.auto_increment;
        }
        let declared = self.source.autoincrement_column();
        self.kept(final_name)
            .is_some_and(|column| declared.is_some_and(|name| name.eq_ignore_ascii_case(column.name())))
    }

    fn written_key(&self) -> Result<Key, BuildDdlError> {
        let key = self.final_key();
        let numbering_toggled = self
            .changes
            .altered_columns
            .iter()
            .any(|alteration| alteration.changed.auto_increment && names(&key, &alteration.draft.name));
        if self.changes.primary_key.is_none() && !numbering_toggled {
            return Ok(Key::Kept);
        }
        let autoincrement = match key.as_slice() {
            [only] if self.numbers_itself(only) => {
                if !is_integer(&self.declared_type(only)?) {
                    return Err(BuildDdlError::Refused {
                        column: only.clone(),
                        operation: DdlOperation::AlterAutoIncrement,
                        reason: RefusalReason::NotAnInteger,
                    });
                }
                Some(self.naming.created(only).to_owned())
            }
            _ => None,
        };
        Ok(Key::Written {
            columns: key.iter().map(|name| self.naming.created(name).to_owned()).collect(),
            autoincrement,
        })
    }

    /// The foreign keys the edit drops, found in the text. The catalogue
    /// numbers them from the last one declared, so the n-th key it lists
    /// is the n-th from the end here.
    fn find_dropped_keys(&self) -> Result<HashSet<(usize, Option<usize>)>, BuildDdlError> {
        let declared = self.source.foreign_keys();
        let listed = &self.original.foreign_keys;
        let mut taken = vec![false; listed.len()];
        let mut dropped = HashSet::new();
        for key in &self.changes.dropped_foreign_keys {
            let column = key.columns.first().map_or("", String::as_str);
            let refuse = || unreadable(column, DdlOperation::DropForeignKey);
            let id = listed
                .iter()
                .enumerate()
                .position(|(id, listed)| listed == key && !taken.get(id).copied().unwrap_or(true))
                .ok_or_else(refuse)?;
            if let Some(slot) = taken.get_mut(id) {
                *slot = true;
            }
            let found = listed
                .len()
                .checked_sub(id + 1)
                .and_then(|position| declared.get(position))
                .ok_or_else(refuse)?;
            let matches = found.columns.len() == key.columns.len()
                && found
                    .columns
                    .iter()
                    .zip(&key.columns)
                    .all(|(found, listed)| found.eq_ignore_ascii_case(listed))
                && found.target.table.eq_ignore_ascii_case(&key.ref_table);
            if !matches {
                return Err(refuse());
            }
            dropped.insert((found.element, found.segment));
        }
        Ok(dropped)
    }

    /// Whether a table constraint is left out of the new table.
    fn constraint_removed(&self, index: usize, constraint: &TableConstraint) -> bool {
        match &constraint.kind {
            TableConstraintKind::PrimaryKey { .. } => matches!(self.key, Key::Written { .. }),
            TableConstraintKind::ForeignKey { .. } => self.dropped_keys.contains(&(index, None)),
            // A UNIQUE of the dropped column alone goes with it.
            TableConstraintKind::Unique { columns } => {
                matches!(columns.as_slice(), [only] if dropped(self.changes, only))
            }
            TableConstraintKind::Check | TableConstraintKind::NameOnly => false,
        }
    }

    /// Refuse to drop a column something the rebuild keeps still uses.
    /// SQLite would refuse the new table, or worse, make the trigger or
    /// view again and let it fail on its next use.
    fn check_dropped_columns(&self) -> Result<(), BuildDdlError> {
        for column in &self.changes.dropped_columns {
            let name = column.name();
            // Mentions are lowercased whole, which can only find more.
            let folded = name.to_lowercase();
            let mut users: Vec<String> = self
                .original
                .foreign_keys
                .iter()
                .filter(|key| names(&key.columns, name) && !self.changes.dropped_foreign_keys.contains(key))
                .map(|key| key.name.clone())
                .collect();
            for (index, constraint) in self.source.constraints() {
                let range = self.element(index).range.clone();
                let uses = !matches!(constraint.kind, TableConstraintKind::ForeignKey { .. })
                    && !self.constraint_removed(index, constraint)
                    && self.source.mentions(range.clone()).contains(&folded);
                if uses {
                    users.push(
                        constraint
                            .name
                            .clone()
                            .unwrap_or_else(|| self.source.text(range).to_owned()),
                    );
                }
            }
            for (_, other) in self.source.columns() {
                if other.name.eq_ignore_ascii_case(name) || dropped(self.changes, &other.name) {
                    continue;
                }
                let uses = other.segments.iter().any(|segment| {
                    matches!(
                        segment.kind,
                        ColumnConstraintKind::Check | ColumnConstraintKind::Generated
                    ) && self.source.mentions(segment.range.clone()).contains(&folded)
                });
                if uses {
                    users.push(other.name.clone());
                }
            }
            users.extend(
                self.recreated()
                    .filter(|object| self.mentions(object).contains(&folded))
                    .map(|object| object.name.clone()),
            );
            if !users.is_empty() {
                return Err(BuildDdlError::Refused {
                    column: name.to_owned(),
                    operation: DdlOperation::DropColumn,
                    reason: RefusalReason::ColumnInUse(users),
                });
            }
        }
        Ok(())
    }

    /// The names a recreated object mentions, lowercased and unquoted.
    /// In a trigger on another table, `new.x` and `old.x` are that
    /// table's columns, never this one's.
    fn mentions(&self, object: &SchemaObjectSource) -> HashSet<String> {
        if object.kind != SchemaObjectKind::Trigger || self.owned(object) {
            return words(&object.sql);
        }
        let Ok(scanned) = tokens(&object.sql) else {
            return words(&object.sql);
        };
        let text = |token: &Token| object.sql.get(token.range.clone()).unwrap_or_default();
        let is = |index: Option<usize>, kind: ScriptTokenKind, spellings: &[&str]| {
            index.and_then(|index| scanned.get(index)).is_some_and(|token| {
                token.kind == kind
                    && spellings
                        .iter()
                        .any(|spelling| text(token).eq_ignore_ascii_case(spelling))
            })
        };
        let mut mentions = HashSet::new();
        for (index, token) in scanned.iter().enumerate() {
            let name = match token.kind {
                ScriptTokenKind::Word => text(token).to_lowercase(),
                ScriptTokenKind::QuotedIdentifier => unquote(text(token)).to_lowercase(),
                _ => continue,
            };
            let row_reference = is(index.checked_sub(1), ScriptTokenKind::Punct, &["."])
                && is(index.checked_sub(2), ScriptTokenKind::Word, &["new", "old"]);
            if !row_reference {
                mentions.insert(name);
            }
        }
        mentions
    }

    fn element(&self, index: usize) -> &SourceElement {
        &self.source.elements[index]
    }

    /// The stored CREATE TABLE under the temporary name, with the edited
    /// parts written again: kept columns where they were, added columns
    /// after them, then the table constraints, the new key and the added
    /// foreign keys.
    fn create_statement(&self, temporary: &TableRef) -> Result<String, BuildDdlError> {
        let sql = self.source.sql();
        let mut pieces: Vec<(Option<usize>, String)> = Vec::new();
        for ((index, column), original) in self.source.columns().zip(&self.original.columns) {
            if !dropped(self.changes, original.name()) {
                pieces.push((Some(index), self.column_text(index, column, original)?));
            }
        }
        for column in &self.naming.added {
            let inline = matches!(&self.key, Key::Written { autoincrement: Some(name), .. } if *name == column.name);
            pieces.push((None, self.dialect.column_definition(column, inline)?));
        }
        for (index, constraint) in self.source.constraints() {
            if !self.constraint_removed(index, constraint) {
                pieces.push((
                    Some(index),
                    self.source.text(self.element(index).range.clone()).to_owned(),
                ));
            }
        }
        if let Key::Written {
            columns,
            autoincrement: None,
        } = &self.key
            && !columns.is_empty()
        {
            pieces.push((None, format!("PRIMARY KEY ({})", column_list(self.dialect, columns))));
        }
        for key in &self.changes.added_foreign_keys {
            let columns: Vec<String> = key
                .columns
                .iter()
                .map(|column| self.naming.created(column).to_owned())
                .collect();
            pieces.push((None, foreign_key_constraint(self.dialect, key, &columns)));
        }

        let list = self.source.text(self.source.open + 1..self.source.close);
        let separator = if list.contains('\n') { ",\n  " } else { ", " };
        let first = self
            .source
            .elements
            .first()
            .map_or(self.source.close, |element| element.range.start);
        let last = self
            .source
            .elements
            .last()
            .map_or(self.source.close, |element| element.range.end);
        let mut body = self.source.text(self.source.open + 1..first).to_owned();
        let mut previous: Option<Option<usize>> = None;
        for (index, text) in &pieces {
            match (previous, index) {
                (None, _) => {}
                // Elements that stood side by side keep what was between
                // them, comments included.
                (Some(Some(before)), Some(index)) if *index == before + 1 => {
                    body.push_str(
                        self.source
                            .text(self.element(before).range.end..self.element(*index).range.start),
                    );
                }
                _ => body.push_str(separator),
            }
            body.push_str(text);
            previous = Some(*index);
        }
        body.push_str(self.source.text(last..self.source.close));
        Ok(format!(
            "CREATE TABLE {} ({body}){}",
            self.dialect.qualify(temporary),
            sql.get(self.source.options.clone()).unwrap_or_default()
        ))
    }

    /// A kept column's definition with the edited parts replaced and the
    /// rest as written: a COLLATE, CHECK, GENERATED or REFERENCES the
    /// edit did not touch stays.
    fn column_text(
        &self,
        index: usize,
        column: &SourceColumn,
        original: &ColumnDefinition,
    ) -> Result<String, BuildDdlError> {
        let element = self.element(index);
        let mut splice = Splice::new(element.range.clone());
        let mut removed = vec![false; column.segments.len()];
        let mut appended: Vec<String> = Vec::new();
        let remove = |removed: &mut Vec<bool>, pick: &dyn Fn(&ColumnConstraintKind) -> bool| {
            for (slot, segment) in removed.iter_mut().zip(&column.segments) {
                *slot |= pick(&segment.kind);
            }
        };

        if let Key::Written { autoincrement, .. } = &self.key {
            remove(&mut removed, &|kind| {
                matches!(kind, ColumnConstraintKind::PrimaryKey { .. })
            });
            if autoincrement.as_deref() == Some(original.name()) {
                appended.push("PRIMARY KEY AUTOINCREMENT".to_owned());
            }
        }
        if let Some(alteration) = self.alteration(original.name()) {
            let name = original.name();
            let draft = &alteration.draft;
            if alteration.changed.column_type {
                let resolved = draft.column_type.resolve(self.dialect, name)?;
                match &column.type_range {
                    Some(range) => splice.replace(range.clone(), resolved.sql),
                    None => splice.insert(column.name_range.end, format!(" {}", resolved.sql)),
                }
            }
            if alteration.changed.nullability {
                remove(&mut removed, &|kind| {
                    matches!(kind, ColumnConstraintKind::NotNull | ColumnConstraintKind::Null)
                });
                if !draft.nullable {
                    appended.push("NOT NULL".to_owned());
                }
            }
            if alteration.changed.default {
                remove(&mut removed, &|kind| matches!(kind, ColumnConstraintKind::Default));
                let column_type = draft.column_type.column_type(self.dialect, name)?;
                if let Some(default) = default_sql(self.dialect, name, &draft.default, &column_type)? {
                    appended.push(format!("DEFAULT {}", default_clause(&draft.default, &default)));
                }
            }
        }
        for (position, slot) in removed.iter_mut().enumerate() {
            *slot |= self.dropped_keys.contains(&(index, Some(position)));
        }
        // A CONSTRAINT name goes with the constraint it names.
        for position in 1..removed.len() {
            let named = column
                .segments
                .get(position - 1)
                .is_some_and(|segment| matches!(segment.kind, ColumnConstraintKind::Name(_)));
            if removed[position] && named {
                removed[position - 1] = true;
            }
        }
        for (segment, removed) in column.segments.iter().zip(&removed) {
            if *removed {
                splice.remove(self.with_space_before(segment.range.clone(), element.range.start));
            }
        }
        for text in appended {
            splice.insert(element.range.end, format!(" {text}"));
        }
        Ok(splice.render(self.source.sql()))
    }

    /// `range` with the spaces before it on its own line, so a removed
    /// constraint leaves no gap. The newline stays: it may end a `--`
    /// comment, which would otherwise run on over what follows.
    fn with_space_before(&self, range: Range<usize>, floor: usize) -> Range<usize> {
        let bytes = self.source.sql().as_bytes();
        let mut start = range.start;
        while start > floor
            && bytes
                .get(start - 1)
                .is_some_and(|byte| byte.is_ascii_whitespace() && *byte != b'\n')
        {
            start -= 1;
        }
        start..range.end
    }

    /// The rows into the new table. Kept columns have their old names
    /// there, and a generated column is computed again. The rowid comes
    /// along too, so whatever names a row by it still finds the row,
    /// unless a copied INTEGER PRIMARY KEY column carries it already.
    fn copy_statement(&self, temporary: &TableRef) -> Result<String, BuildDdlError> {
        let mut columns: Vec<String> = self.rowid_name().into_iter().map(str::to_owned).collect();
        columns.extend(
            self.original
                .columns
                .iter()
                .filter(|column| !dropped(self.changes, column.name()))
                .filter(|column| !column.info.is_generated && column.attributes.generated.is_none())
                .map(|column| self.dialect.quote_identifier(column.name())),
        );
        if columns.is_empty() {
            return Err(BuildDdlError::Unsupported(DdlOperation::AlterTable));
        }
        let list = columns.join(", ");
        // OR ABORT overrides an ON CONFLICT IGNORE or REPLACE the kept
        // text declares, which would drop a row the new table refuses
        // rather than fail the save.
        Ok(format!(
            "INSERT OR ABORT INTO {} ({list}) SELECT {list} FROM {}",
            self.dialect.qualify(temporary),
            self.dialect.qualify(&self.original.table)
        ))
    }

    /// A name for the rowid that no column of either table hides, unless
    /// a copied column is the new table's rowid.
    fn rowid_name(&self) -> Option<&'static str> {
        if self.source.without_rowid {
            return None;
        }
        if self
            .rowid_alias_after()
            .is_some_and(|alias| self.kept(&alias).is_some())
        {
            return None;
        }
        let taken: HashSet<String> = self
            .original
            .columns
            .iter()
            .map(|column| fold(column.name()))
            .chain(self.naming.occupied.iter().map(|name| fold(name)))
            .collect();
        ["rowid", "oid", "_rowid_"]
            .into_iter()
            .find(|name| !taken.contains(*name))
    }

    /// The column that is the new table's rowid, by its final name: a
    /// lone INTEGER PRIMARY KEY, unless the kept text declares it
    /// `PRIMARY KEY DESC` on the column itself.
    fn rowid_alias_after(&self) -> Option<String> {
        if self.source.without_rowid {
            return None;
        }
        let [only] = self.final_key().try_into().ok()?;
        if !self.declared_type(&only).is_ok_and(|declared| is_integer(&declared)) {
            return None;
        }
        let descending = self.key == Key::Kept
            && self
                .kept(&only)
                .is_some_and(|column| self.source.declares_descending_key(column.name()));
        (!descending).then_some(only)
    }

    /// The column that is the old table's rowid.
    fn rowid_alias_before(&self) -> Option<&str> {
        if self.source.without_rowid {
            return None;
        }
        let key: Vec<&ColumnDefinition> = match &self.original.primary_key {
            Some(key) => key
                .columns
                .iter()
                .filter_map(|name| self.original.column(name))
                .collect(),
            None => self
                .original
                .columns
                .iter()
                .filter(|column| column.info.primary_key)
                .collect(),
        };
        let [only] = key.as_slice() else {
            return None;
        };
        let declared = only
            .info
            .column_type
            .catalog
            .as_ref()
            .map_or("", |catalog| catalog.declaration.as_sql());
        (is_integer(declared) && !self.source.declares_descending_key(only.name())).then_some(only.name())
    }

    /// Whether the copy gives the rows new rowids: a kept column that
    /// was not the rowid becomes it, or no name reaches the old one.
    fn rowids_renumbered(&self) -> bool {
        if self.source.without_rowid {
            return false;
        }
        let copied_alias = self
            .rowid_alias_after()
            .and_then(|alias| self.kept(&alias))
            .map(ColumnDefinition::name);
        match copied_alias {
            Some(alias) => !self
                .rowid_alias_before()
                .is_some_and(|before| before.eq_ignore_ascii_case(alias)),
            None => self.rowid_name().is_none(),
        }
    }

    /// SQLite numbers the rowid column, and takes AUTOINCREMENT only on
    /// it. So numbering cannot stop on a column that stays the rowid,
    /// and a column that keeps AUTOINCREMENT stays INTEGER.
    fn check_numbering(&self) -> Result<(), BuildDdlError> {
        let alias = self.rowid_alias_after();
        for alteration in &self.changes.altered_columns {
            let stops = alteration.changed.auto_increment && !alteration.draft.auto_increment;
            if stops
                && alias
                    .as_deref()
                    .is_some_and(|alias| alias.eq_ignore_ascii_case(&alteration.draft.name))
            {
                return Err(BuildDdlError::Refused {
                    column: alteration.original.name().to_owned(),
                    operation: DdlOperation::AlterAutoIncrement,
                    reason: RefusalReason::AlwaysNumbered,
                });
            }
        }
        let Some(column) = self
            .source
            .autoincrement_column()
            .filter(|column| self.key == Key::Kept && !dropped(self.changes, column))
        else {
            return Ok(());
        };
        match is_integer(&self.declared_type(&final_name(self.changes, column))?) {
            true => Ok(()),
            false => Err(BuildDdlError::Refused {
                column: column.to_owned(),
                operation: DdlOperation::AlterColumnType,
                reason: RefusalReason::NotAnInteger,
            }),
        }
    }
}

/// The one declared type that makes a lone primary key column the rowid.
fn is_integer(declared: &str) -> bool {
    declared.trim().eq_ignore_ascii_case("INTEGER")
}

/// Edits to one stretch of the source, applied in order.
struct Splice {
    range: Range<usize>,
    edits: Vec<(Range<usize>, String)>,
}

impl Splice {
    fn new(range: Range<usize>) -> Self {
        Self {
            range,
            edits: Vec::new(),
        }
    }

    fn replace(&mut self, range: Range<usize>, text: String) {
        self.edits.push((range, text));
    }

    fn insert(&mut self, at: usize, text: String) {
        self.edits.push((at..at, text));
    }

    fn remove(&mut self, range: Range<usize>) {
        self.edits.push((range, String::new()));
    }

    fn render(mut self, sql: &str) -> String {
        self.edits.sort_by_key(|(range, _)| (range.start, range.end));
        let mut text = String::new();
        let mut cursor = self.range.start;
        for (range, replacement) in self.edits {
            if range.start >= cursor {
                text.push_str(sql.get(cursor..range.start).unwrap_or_default());
            }
            text.push_str(&replacement);
            cursor = cursor.max(range.end);
        }
        text.push_str(sql.get(cursor..self.range.end).unwrap_or_default());
        text
    }
}

/// The stored CREATE of an index, trigger or view, ready to run again:
/// one statement, creating its object in `schema`. `None` when the text
/// is not one such statement.
///
/// SQLite compiles only the first statement of a schema entry when it
/// loads the schema, so text edited through `writable_schema` can carry
/// more that it never ran, and replaying that would run them. It stores
/// the CREATE without its schema, and run as stored it would land in
/// `main`.
fn replayable(dialect: &SqliteDialect, sql: &str, schema: Option<&str>) -> Option<String> {
    let plan = ScriptPlan::build(
        sql,
        SqlGrammar::Sqlite,
        LexicalSettings::default_for(SqlGrammar::Sqlite),
    );
    if plan.statements().len() != 1 {
        return None;
    }
    let Some(schema) = schema.filter(|schema| !schema.eq_ignore_ascii_case(MAIN_SCHEMA)) else {
        return Some(sql.to_owned());
    };
    let tokens = tokens(sql).ok()?;
    let word = |index: usize, word: &str| {
        tokens.get(index).is_some_and(|token| {
            token.kind == ScriptTokenKind::Word
                && sql
                    .get(token.range.clone())
                    .is_some_and(|text| text.eq_ignore_ascii_case(word))
        })
    };
    if !word(0, "CREATE") {
        return None;
    }
    let mut index = 1;
    if word(index, "TEMP") || word(index, "TEMPORARY") {
        index += 1;
    }
    if word(index, "UNIQUE") {
        index += 1;
    }
    if !(word(index, "INDEX") || word(index, "TRIGGER") || word(index, "VIEW")) {
        return None;
    }
    index += 1;
    if word(index, "IF") {
        index += 3;
    }
    let name = tokens.get(index)?;
    let qualified = tokens
        .get(index + 1)
        .is_some_and(|token| token.kind == ScriptTokenKind::Punct && sql.get(token.range.clone()) == Some("."));
    if qualified {
        return Some(sql.to_owned());
    }
    Some(format!(
        "{}{}.{}",
        sql.get(..name.range.start)?,
        dialect.quote_identifier(schema),
        sql.get(name.range.start..)?
    ))
}

/// How many rows `now` and `rows` do not share, each a parenthesised
/// VALUES row. `EXCEPT` compares rows as distinct, which names in a
/// schema are.
fn differences(now: &str, rows: &[String]) -> String {
    if rows.is_empty() {
        return format!("(SELECT count(*) FROM ({now}))");
    }
    let read = format!("VALUES {}", rows.join(", "));
    format!("((SELECT count(*) FROM ({now} EXCEPT {read})) + (SELECT count(*) FROM ({read} EXCEPT {now})))")
}

fn unreadable(column: &str, operation: DdlOperation) -> BuildDdlError {
    BuildDdlError::Refused {
        column: column.to_owned(),
        operation,
        reason: RefusalReason::UnreadableDefinition,
    }
}

fn dropped(changes: &TableChanges, name: &str) -> bool {
    changes
        .dropped_columns
        .iter()
        .any(|column| column.name().eq_ignore_ascii_case(name))
}

/// The name a column has once the edit is done.
fn final_name(changes: &TableChanges, original: &str) -> String {
    changes
        .renamed_columns
        .iter()
        .find(|rename| rename.from == original)
        .map_or(original, |rename| rename.to.as_str())
        .to_owned()
}

fn same_table(left: &TableRef, right: &TableRef) -> bool {
    let schema = |table: &TableRef| {
        table
            .schema
            .as_deref()
            .filter(|schema| !schema.is_empty())
            .unwrap_or(MAIN_SCHEMA)
            .to_lowercase()
    };
    left.name.eq_ignore_ascii_case(&right.name) && schema(left) == schema(right)
}

/// SQLite compares names without regard to ASCII case, and only ASCII.
fn fold(name: &str) -> String {
    name.to_ascii_lowercase()
}

fn text_literal(text: &str) -> String {
    format!("'{}'", text.replace('\'', "''"))
}
