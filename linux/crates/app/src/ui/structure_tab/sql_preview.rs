use super::context::StructureContext;
use crate::i18n::gettext;
use crate::services::pending_structure::PendingStructure;
use crate::ui::error_text::build_error_text;

/// The SQL page's text for `pending`: the statements Save would run,
/// or a comment that says why there are none.
pub(super) fn preview_text(context: &StructureContext, pending: &PendingStructure) -> String {
    match (&context.dialect, context.ddl()) {
        (None, _) => gettext("-- Connect to a database to see the SQL."),
        (Some(_), None) => gettext("-- This database's structure can't be edited here."),
        (Some(_), Some(_)) if !pending.unparsed_defaults.is_empty() => {
            gettext("-- Fix the highlighted fields to see the SQL.")
        }
        (Some(_), Some(_)) if !pending.has_changes() => no_pending_changes(),
        (Some(_), Some(ddl)) => match pending.plan(ddl) {
            Ok(plan) => plan.preview(),
            Err(error) => format!("-- {}", build_error_text(&error)),
        },
    }
}

pub(super) fn no_pending_changes() -> String {
    gettext("-- No pending changes.")
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use gtk4::prelude::*;
    use gtk4::subclass::prelude::ObjectSubclassIsExt;
    use tablepro_core::ServerInfo;
    use tablepro_core::ddl::{DraftColumn, DraftType, TableChanges, TableDraft};
    use tablepro_core::dialect::SqlDialect;
    use tablepro_core::meta::TableRef;
    use tablepro_test_support::ConnectionScript;

    use super::*;
    use crate::services::structure_tracker_handle::StructureTrackerHandle;
    use crate::test_support::{FakeSession, drain_main_context};
    use crate::ui::structure_tab::{ColumnsInput, StructureMode, StructureModel, StructureTab, StructureTabInit};

    fn postgres() -> Arc<dyn SqlDialect> {
        Arc::new(drivers_postgres::PgDialect::new(&ServerInfo::new(
            "PostgreSQL",
            "18.0",
            18,
            0,
            0,
        )))
    }

    fn new_table(dialect: Option<Arc<dyn SqlDialect>>) -> StructureContext {
        StructureContext {
            mode: StructureMode::New,
            dialect,
            definition: None,
        }
    }

    fn created(columns: &[&str]) -> PendingStructure {
        let mut draft = TableDraft::new(TableRef::new(None, "users"));
        draft.columns = columns
            .iter()
            .map(|name| DraftColumn::new(*name, DraftType::Typed("integer".to_owned())))
            .collect();
        PendingStructure {
            original: None,
            draft,
            changes: TableChanges::default(),
            unparsed_defaults: Vec::new(),
        }
    }

    #[test]
    fn a_draft_without_a_connection_asks_for_one() {
        assert_eq!(
            preview_text(&new_table(None), &created(&["id"])),
            "-- Connect to a database to see the SQL."
        );
    }

    #[test]
    fn an_unparsed_default_holds_the_preview() {
        let pending = PendingStructure {
            unparsed_defaults: vec!["id".to_owned()],
            ..created(&["id"])
        };

        assert_eq!(
            preview_text(&new_table(Some(postgres())), &pending),
            "-- Fix the highlighted fields to see the SQL."
        );
    }

    #[test]
    fn a_plan_that_cannot_be_written_says_why() {
        let preview = preview_text(&new_table(Some(postgres())), &created(&["id", "id"]));

        assert!(preview.starts_with("-- "), "{preview}");
        assert!(!preview.contains("CREATE TABLE"), "{preview}");
    }

    #[gtk4::test]
    fn sql_preview_page_shows_the_plan_preview() {
        libadwaita::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let runtime = crate::test_support::test_runtime();
        let script = ConnectionScript {
            dialect: postgres(),
            ..ConnectionScript::default()
        };
        let fake = FakeSession::start(script, [], runtime.tasks());
        let tab = StructureTab::new(StructureTabInit {
            tracker: StructureTrackerHandle::default(),
            schema: None,
            table: "users".to_owned(),
            mode: StructureMode::New,
            session: fake.session.clone(),
            tasks: runtime.tasks(),
        });
        tab.send(ColumnsInput::AddColumn);
        drain_main_context();

        let pending = tab
            .imp()
            .model
            .borrow()
            .as_ref()
            .map(StructureModel::pending)
            .expect("the tab has a model");
        let dialect = postgres();
        let plan = pending
            .plan(dialect.ddl().expect("PostgreSQL edits structure"))
            .expect("the draft plans");
        let buffer = tab.imp().sql_view.buffer();
        let shown = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false);

        assert!(plan.preview().starts_with("CREATE TABLE"), "{}", plan.preview());
        assert_eq!(shown, plan.preview());

        drop(tab);
        drain_main_context();
        runtime.shutdown();
    }
}
