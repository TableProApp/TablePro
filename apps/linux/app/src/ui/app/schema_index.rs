use relm4::{ComponentController, ComponentSender};

use super::{App, AppMsg};
use crate::ui::editor::{catalog_reference, split_table_reference, table_key};

impl App {
    pub(super) fn set_completion_tables(
        &mut self,
        tables: &[tablepro_core::TableInfo],
        views: &[tablepro_core::TableInfo],
    ) {
        let driver = self.current_driver_id.as_deref().unwrap_or("postgres");
        self.table_names = tables
            .iter()
            .chain(views)
            .map(|table| catalog_reference(driver, table.schema.as_deref(), &table.name))
            .collect();
    }

    pub(super) fn on_editor_needs_columns(&self, tables: Vec<String>, sender: ComponentSender<Self>) {
        let Some((conn, identity)) = self.connection_id.and_then(|id| self.database.get_with_identity(id)) else {
            return;
        };
        let pending: Vec<crate::ui::editor::SchemaRequest> = {
            let mut index = self.schema_index.borrow_mut();
            if index.sync_connection(&identity) {
                self.reset_schema_fetches();
            }
            let mut requested = self.requested_columns.borrow_mut();
            tables
                .into_iter()
                .filter(|table| !index.knows_columns(table))
                .filter(|table| table_key(table, index.grammar).is_some_and(|key| requested.insert(key)))
                .map(|table| index.request(table))
                .collect()
        };
        if pending.is_empty() {
            return;
        };
        let timeout_secs =
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id);
        let sender_clone = sender.clone();
        let token = self.schema_fetch_cancel.borrow().clone();
        let grammar = self.schema_index.borrow().grammar;
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    for request in pending {
                        if token.is_cancelled() {
                            break;
                        }
                        let Some((schema, table)) = split_table_reference(&request.table, grammar) else {
                            sender_clone.input(AppMsg::SchemaColumnsFetched(request, Err(())));
                            continue;
                        };
                        let control = crate::services::operation_control::bounded_with(timeout_secs, token.clone());
                        let result = conn
                            .fetch_columns_controlled(schema.as_deref(), &table, &control)
                            .await
                            .map(|columns| columns.into_iter().map(|column| column.name).collect())
                            .map_err(|_| ());
                        sender_clone.input(AppMsg::SchemaColumnsFetched(request, result));
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn reset_schema_fetches(&self) {
        self.requested_columns.borrow_mut().clear();
        crate::services::request_generation::replace_in_flight(&self.schema_fetch_cancel);
    }

    pub(super) fn on_schema_columns_fetched(
        &self,
        request: crate::ui::editor::SchemaRequest,
        columns: Result<Vec<String>, ()>,
    ) {
        let Some(identity) = self.connection_id.and_then(|id| self.database.identity(id)) else {
            return;
        };
        let Some(key) = table_key(&request.table, self.schema_index.borrow().grammar) else {
            return;
        };
        let mut index = self.schema_index.borrow_mut();
        if index.sync_connection(&identity) {
            self.reset_schema_fetches();
        }
        if !index.accepts(&request) {
            return;
        }
        match columns {
            Ok(columns) => index.set_columns(&request.table, columns),
            Err(()) => {
                self.requested_columns.borrow_mut().remove(&key);
            }
        }
    }

    pub(super) fn refresh_schema_index(&self) {
        if let Some(identity) = self.connection_id.and_then(|id| self.database.identity(id))
            && self.schema_index.borrow_mut().sync_connection(&identity)
        {
            self.reset_schema_fetches();
        }
        self.schema_index.borrow_mut().grammar = self
            .current_driver_id
            .as_deref()
            .and_then(crate::ui::editor::grammar_for);
        let tabs = self.workspace_tabs.borrow();
        let mut index = self.schema_index.borrow_mut();
        index.tables = self.table_names.clone();
        for tab in tabs.values() {
            if let Some(controller) = tab.browse_controller() {
                let model = controller.model();
                let columns: Vec<String> = model.columns().iter().map(|column| column.name.clone()).collect();
                if columns.is_empty() {
                    continue;
                }
                let reference = catalog_reference(
                    self.current_driver_id.as_deref().unwrap_or("postgres"),
                    model.schema(),
                    model.table(),
                );
                index.set_columns(&reference, columns);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::split_table_reference;
    use tablepro_core::sql_syntax::SqlGrammar;

    #[test]
    fn quoted_names_reach_metadata_without_losing_identity() {
        for (sql, schema, table) in [
            (r#""odd.schema"."a.b""#, Some("odd.schema"), "a.b"),
            (r#"public."a""b""#, Some("public"), "a\"b"),
            (r#""public"."Users""#, Some("public"), "Users"),
            (r#"public."select""#, Some("public"), "select"),
            (r#""東京"."with space""#, Some("東京"), "with space"),
            ("PUBLIC.Users", Some("public"), "users"),
            ("users", None, "users"),
        ] {
            assert_eq!(
                split_table_reference(sql, Some(SqlGrammar::PostgreSql)),
                Some((schema.map(str::to_string), table.into()))
            );
        }
    }

    #[test]
    fn invalid_references_do_not_route_metadata() {
        for sql in [
            "users.",
            ".users",
            "a.b.c",
            r#"public."open"#,
            "public..users",
            "'users'",
            r#"public."""#,
            "users; DROP TABLE users",
        ] {
            assert!(
                split_table_reference(sql, Some(SqlGrammar::PostgreSql)).is_none(),
                "{sql}"
            );
        }
    }

    #[test]
    fn other_engines_keep_their_identifier_delimiters() {
        assert_eq!(
            split_table_reference("`orders`", Some(SqlGrammar::MySql)),
            Some((None, "orders".into()))
        );
        assert_eq!(
            split_table_reference("[dbo].[a]]b]", Some(SqlGrammar::MsSql)),
            Some((Some("dbo".into()), "a]b".into()))
        );
    }
}
