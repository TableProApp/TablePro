use relm4::gtk::prelude::*;
use relm4::{ComponentSender, gtk};

use super::{ExecutionContext, SqlEditor, SqlEditorInput, StatementOutcome, StatementOutcomeKind};

#[derive(Clone, Copy, Debug)]
pub(crate) struct SourceAnchor {
    pub(super) revision: u64,
    pub(super) start: usize,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct ErrorTarget {
    generation: u64,
    revision: u64,
    offset: i32,
}

impl ErrorTarget {
    pub(super) fn variant(self) -> gtk::glib::Variant {
        (self.generation, self.revision, self.offset).to_variant()
    }
}

#[derive(Debug)]
pub(super) struct ExecutionSource {
    anchor: SourceAnchor,
    statements: Vec<Option<std::ops::Range<usize>>>,
}

impl ExecutionSource {
    pub(super) fn new(anchor: SourceAnchor, sql: &str, planned: &super::PlannedStatements) -> Self {
        if planned.statements.len() != planned.source_ranges.len() {
            return Self {
                anchor,
                statements: Vec::new(),
            };
        }
        let mut cursor = Some((0, 0));
        let statements = planned
            .statements
            .iter()
            .zip(&planned.source_ranges)
            .map(|(statement, range)| {
                let (from, chars) = cursor.take()?;
                if sql.get(range.clone())? != statement {
                    return None;
                }
                let start = chars + sql.get(from..range.start)?.chars().count();
                let end = start + statement.chars().count();
                cursor = Some((range.end, end));
                Some(start..end)
            })
            .collect();
        Self { anchor, statements }
    }

    fn target(&self, generation: u64, statement: usize, position: usize) -> Option<ErrorTarget> {
        let range = self.statements.get(statement)?.as_ref()?;
        let local = position.checked_sub(1).filter(|local| *local <= range.len())?;
        let offset = self.anchor.start.checked_add(range.start)?.checked_add(local)?;
        Some(ErrorTarget {
            generation,
            revision: self.anchor.revision,
            offset: i32::try_from(offset).ok()?,
        })
    }
}

pub(super) fn install(root: &impl IsA<gtk::Widget>, sender: &ComponentSender<SqlEditor>) {
    let group = gtk::gio::SimpleActionGroup::new();
    let action = gtk::gio::SimpleAction::new("jump", Some(&<(u64, u64, i32)>::static_variant_type()));
    let sender = sender.clone();
    action.connect_activate(move |_, value| {
        if let Some((generation, revision, offset)) = value.and_then(|value| value.get::<(u64, u64, i32)>()) {
            sender.input(SqlEditorInput::NavigateError(ErrorTarget {
                generation,
                revision,
                offset,
            }));
        }
    });
    group.add_action(&action);
    root.insert_action_group("editor-error", Some(&group));
}

pub(super) fn locate(generation: u64, context: &ExecutionContext, outcomes: &mut [StatementOutcome]) {
    for outcome in outcomes {
        let failure = match &mut outcome.kind {
            StatementOutcomeKind::Error(failure) => Some(failure),
            StatementOutcomeKind::Streamed(result) => match &mut result.terminal {
                super::StreamTerminal::Failed(failure) => Some(failure),
                _ => None,
            },
            _ => None,
        };
        if let Some(failure) = failure {
            failure.target = context
                .source
                .as_ref()
                .and_then(|source| source.target(generation, outcome.identity.statement_index, failure.position?));
        }
    }
}

impl SqlEditor {
    pub(super) fn navigate_error(&self, target: ErrorTarget) {
        let buffer = self.source_view.buffer();
        if !self.run_generation.is_current(target.generation)
            || self.drop_generation.revision() != target.revision
            || !self
                .navigation_origin
                .as_ref()
                .is_some_and(|origin| origin.owns_window(self.connection_id, &self.database))
            || target.offset < 0
            || target.offset > buffer.char_count()
        {
            self.status.set_label(&crate::tr!(
                "The query or connection changed. Run it again to locate the error."
            ));
            return;
        }
        self.panel.reveal_editor();
        buffer.place_cursor(&buffer.iter_at_offset(target.offset));
        if self.source_view.is_mapped() {
            self.source_view.scroll_mark_onscreen(&buffer.get_insert());
            self.source_view.grab_focus();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source(sql: &str, start: usize) -> ExecutionSource {
        let planned = super::super::script_statements(sql, "postgres").unwrap();
        ExecutionSource::new(SourceAnchor { revision: 9, start }, sql, &planned)
    }

    #[test]
    fn repeated_statements_are_mapped_in_order_after_a_unicode_prefix() {
        let source = source("SELECT 'é';\nSELECT broken;\nSELECT broken;", 3);
        let second = source.target(4, 1, 8).unwrap();
        let third = source.target(4, 2, 8).unwrap();
        assert_eq!(second.offset, 3 + "SELECT 'é';\nSELECT ".chars().count() as i32);
        assert_eq!(
            third.offset,
            3 + "SELECT 'é';\nSELECT broken;\nSELECT ".chars().count() as i32
        );
        assert_eq!(third.revision, 9);
    }

    #[test]
    fn end_of_statement_is_valid_but_outside_positions_are_not() {
        let source = source("SELECT é", 5);
        assert_eq!(source.target(1, 0, 9).unwrap().offset, 13);
        assert!(source.target(1, 0, 0).is_none());
        assert!(source.target(1, 0, 10).is_none());
        assert!(source.target(1, 1, 1).is_none());
    }

    #[test]
    fn an_unmatched_statement_disables_subsequent_source_mapping() {
        let sql = "SELECT broken;SELECT broken";
        let mut planned = super::super::script_statements(sql, "postgres").unwrap();
        planned.statements[0] = "SELECT absent".into();
        let source = ExecutionSource::new(SourceAnchor { revision: 1, start: 0 }, sql, &planned);
        assert!(source.target(1, 0, 8).is_none());
        assert!(source.target(1, 1, 8).is_none());
    }

    #[test]
    fn comments_with_identical_sql_are_not_statement_origins() {
        let sql = "-- SELECT broken\nSELECT broken; /* SELECT broken */\nSELECT broken;";
        let source = source(sql, 0);
        assert_eq!(
            source.target(1, 0, 8).unwrap().offset,
            "-- SELECT broken\nSELECT ".chars().count() as i32
        );
        assert_eq!(
            source.target(1, 1, 8).unwrap().offset,
            sql.rfind("broken").unwrap() as i32
        );
    }
}
