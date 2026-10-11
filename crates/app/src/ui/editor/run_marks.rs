use relm4::gtk::prelude::*;
use sourceview5::prelude::*;

use super::{ExecutionContext, SqlEditor, StatementOutcome, StatementOutcomeKind, statement_cursor::script_statements};

const OK_CATEGORY: &str = "tp-run-ok";
const ERROR_CATEGORY: &str = "tp-run-error";
const MARK_PRIORITY: i32 = 10;

pub(super) fn statement_start_lines(text: &str, statements: &[String]) -> Vec<Option<u32>> {
    let mut from = 0;
    statements
        .iter()
        .map(|statement| {
            let found = text.get(from..)?.find(statement.as_str())?;
            let start = from + found;
            from = start + statement.len();
            Some(text[..start].matches('\n').count() as u32)
        })
        .collect()
}

fn category_of(outcome: &StatementOutcome) -> Option<&'static str> {
    match outcome.kind {
        StatementOutcomeKind::Rows(_) => Some(OK_CATEGORY),
        StatementOutcomeKind::Error(_) => Some(ERROR_CATEGORY),
        StatementOutcomeKind::NotRun => None,
    }
}

pub(super) fn install(view: &sourceview5::View) {
    view.set_show_line_marks(true);
    if let Ok(buffer) = view.buffer().downcast::<sourceview5::Buffer>() {
        buffer.connect_changed(clear);
    }
    for (category, icon) in [
        (OK_CATEGORY, "emblem-ok-symbolic"),
        (ERROR_CATEGORY, "dialog-error-symbolic"),
    ] {
        let attributes = sourceview5::MarkAttributes::new();
        attributes.set_icon_name(icon);
        view.set_mark_attributes(category, &attributes, MARK_PRIORITY);
    }
}

pub(super) fn clear(buffer: &sourceview5::Buffer) {
    let (start, end) = buffer.bounds();
    for category in [OK_CATEGORY, ERROR_CATEGORY] {
        buffer.remove_source_marks(&start, &end, Some(category));
    }
}

impl SqlEditor {
    pub(super) fn clear_run_marks(&self) {
        if let Ok(buffer) = self.source_view.buffer().downcast::<sourceview5::Buffer>() {
            clear(&buffer);
        }
    }

    pub(super) fn mark_statements(&self, context: &ExecutionContext, current: bool, outcomes: &[StatementOutcome]) {
        if !current {
            return;
        }
        if let Ok(buffer) = self.source_view.buffer().downcast::<sourceview5::Buffer>() {
            mark_outcomes(&buffer, &context.sql, &context.metadata.driver_id, outcomes);
        }
    }
}

fn mark_outcomes(buffer: &sourceview5::Buffer, sql: &str, driver: &str, outcomes: &[StatementOutcome]) {
    let (start, end) = buffer.bounds();
    let text = buffer.text(&start, &end, false).to_string();
    let Ok(planned) = script_statements(sql, driver) else {
        return;
    };
    if text.trim() != sql || planned.statements.len() != outcomes.len() {
        return;
    }
    let leading_lines = text[..text.len() - text.trim_start().len()].matches('\n').count() as u32;
    clear(buffer);
    for (line, outcome) in statement_start_lines(sql, &planned.statements).iter().zip(outcomes) {
        let (Some(line), Some(category)) = (line, category_of(outcome)) else {
            continue;
        };
        let Some(at) = buffer.iter_at_line((line + leading_lines) as i32) else {
            continue;
        };
        buffer.create_source_mark(None, category, &at);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_statement_is_placed_on_the_line_where_it_starts() {
        let text = "SELECT 1;\nSELECT 2;\n\nSELECT 3;";
        let statements = vec!["SELECT 1".to_string(), "SELECT 2".to_string(), "SELECT 3".to_string()];
        assert_eq!(
            statement_start_lines(text, &statements),
            vec![Some(0), Some(1), Some(3)]
        );
    }

    #[test]
    fn a_repeated_statement_is_matched_in_order() {
        let statements = vec!["SELECT 1".to_string(), "SELECT 1".to_string()];
        assert_eq!(
            statement_start_lines("SELECT 1;\nSELECT 1;", &statements),
            vec![Some(0), Some(1)]
        );
    }

    #[test]
    fn a_statement_missing_from_the_text_has_no_line() {
        let statements = vec!["SELECT 1".to_string(), "DROP x".to_string()];
        assert_eq!(statement_start_lines("SELECT 1;", &statements), vec![Some(0), None]);
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn each_statement_gets_a_gutter_mark_for_its_outcome() {
        relm4::adw::init().unwrap();
        let buffer = sourceview5::Buffer::new(None::<&relm4::gtk::TextTagTable>);
        buffer.set_text("SELECT 1;\nSELECT x;\nSELECT 3;");
        let outcome = |kind| StatementOutcome {
            sql_preview: String::new(),
            elapsed_ms: 0,
            kind,
            pinned: false,
        };
        let outcomes = [
            outcome(StatementOutcomeKind::Rows(Vec::new())),
            outcome(StatementOutcomeKind::Error("boom".into())),
            outcome(StatementOutcomeKind::NotRun),
        ];

        mark_outcomes(&buffer, "SELECT 1;\nSELECT x;\nSELECT 3;", "sqlite", &outcomes);

        assert_eq!(buffer.source_marks_at_line(0, Some(OK_CATEGORY)).len(), 1);
        assert_eq!(buffer.source_marks_at_line(1, Some(ERROR_CATEGORY)).len(), 1);
        assert!(buffer.source_marks_at_line(2, None).is_empty());

        let view = sourceview5::View::with_buffer(&buffer);
        install(&view);
        buffer.insert_at_cursor("-- edit");
        assert!(
            buffer.source_marks_at_line(0, None).is_empty(),
            "an edit drops the marks"
        );

        clear(&buffer);
        buffer.set_text("SELECT 1;\nSELECT x;\nSELECT 3;\n-- edited");
        mark_outcomes(&buffer, "SELECT 1;\nSELECT x;\nSELECT 3;", "sqlite", &outcomes);
        assert!(
            buffer.source_marks_at_line(0, None).is_empty(),
            "a script edited since the run gets no marks"
        );
    }
}
