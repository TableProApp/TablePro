use super::*;
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

#[test]
fn column_requests_require_a_complete_catalog_name() {
    let mut index = super::SchemaIndex {
        grammar: Some(tablepro_core::sql_syntax::SqlGrammar::PostgreSql),
        ..Default::default()
    };
    index.set_tables(vec![
        "public.customers".into(),
        "archive.customers".into(),
        "public.\"Users\"".into(),
    ]);
    for partial in ["c", "cu", "customer", "public.customer", "missing.customers", "users"] {
        assert!(
            !index.needs_columns(partial),
            "unexpected catalog request for {partial}"
        );
    }
    for known in [
        "customers",
        "public.customers",
        "archive.customers",
        "\"Users\"",
        "public.\"Users\"",
    ] {
        assert!(index.needs_columns(known), "missing catalog request for {known}");
    }
    index.set_columns("public.customers", vec!["id".into()]);
    assert!(!index.needs_columns("public.customers"));
    assert!(index.needs_columns("archive.customers"));
}

#[test]
fn column_membership_tracks_catalog_grammar_and_clear_changes() {
    let mut index = SchemaIndex::default();
    index.set_tables(vec!["public.customers".into()]);
    assert!(index.needs_columns("customers"));
    index.set_tables(vec!["public.orders".into(), "public.\"Users\"".into()]);
    assert!(!index.needs_columns("customers"));
    assert!(index.needs_columns("orders"));
    assert!(!index.needs_columns("users"));
    index.grammar = Some(SqlGrammar::Sqlite);
    assert!(index.needs_columns("users"));
    index.set_tables(vec!["public.\"Users\"".into()]);
    assert!(index.needs_columns("users"));
    index.clear();
    assert!(!index.needs_columns("users"));
    index.set_tables(vec!["public.next".into()]);
    assert!(index.needs_columns("next"));
}

#[test]
fn catalog_membership_lookup_work_does_not_grow_with_catalog_size() {
    let mut index = SchemaIndex::default();
    index.set_tables(
        (0..10_000)
            .map(|i| format!("tenant_{:03}.table_{i:05}", i / 500))
            .collect(),
    );
    let before = crate::completion_identifiers::table_key_calls();
    for (name, expected) in [
        ("missing", false),
        ("tenant_000.missing", false),
        ("table_09999", true),
        ("tenant_019.table_09999", true),
    ] {
        assert_eq!(index.needs_columns(name), expected);
    }
    let normalizations = crate::completion_identifiers::table_key_calls() - before;
    assert!(
        normalizations <= 16,
        "four lookups normalized {normalizations} identifiers"
    );
}

#[test]
fn typing_prefixes_admit_only_catalogued_names_and_skip_cached_columns() {
    let mut index = SchemaIndex::default();
    index.set_tables(vec!["public.customers".into()]);
    let requests: Vec<_> = (1..="customers".len())
        .map(|end| &"customers"[..end])
        .filter(|name| index.needs_columns(name))
        .collect();
    assert_eq!(requests, vec!["customers"]);
    index.set_columns("customers", vec!["id".into()]);
    assert!(!index.needs_columns("customers"));
    assert!(!index.needs_columns("public.missing"));
}

fn index() -> SchemaIndex {
    let mut index = SchemaIndex::default();
    index.set_tables(vec!["public.users".into(), "public.orders".into()]);
    index.set_columns("public.users", vec!["id".into(), "email".into(), "created_at".into()]);
    index.set_columns("public.orders", vec!["id".into(), "user_id".into(), "total".into()]);
    index.grammar = Some(SqlGrammar::PostgreSql);
    index
}

#[test]
fn a_semicolon_inside_a_line_comment_does_not_split_the_statement() {
    let words = candidates("SELECT * FROM public.users -- one; two\nWHERE |");
    assert!(words.contains(&"email".to_string()));
    assert!(!words.contains(&"total".to_string()));
}

#[test]
fn a_semicolon_inside_a_block_comment_does_not_split_the_statement() {
    let words = candidates("SELECT * FROM public.users /* one; two */ WHERE |");
    assert!(words.contains(&"email".to_string()));
    assert!(!words.contains(&"total".to_string()));
}

#[test]
fn a_semicolon_inside_a_dollar_quoted_body_does_not_split_the_statement() {
    let words = candidates("SELECT * FROM public.users WHERE email = $$a;b$$ AND |");
    assert!(words.contains(&"created_at".to_string()));
    assert!(!words.contains(&"total".to_string()));
}

#[test]
fn a_cursor_after_the_last_semicolon_starts_a_new_statement() {
    let words = candidates("SELECT * FROM public.orders; SELECT * FROM |");
    assert!(words.contains(&"public.users".to_string()));
    assert!(!words.contains(&"total".to_string()));
}

#[test]
fn schema_requests_are_accepted_only_by_their_generation() {
    let mut index = SchemaIndex::default();
    let current = index.request("users".into());
    index.generation = index.generation.wrapping_add(1);

    assert!(!index.accepts(&current));
    assert!(index.accepts(&index.request("users".into())));
}

#[test]
fn a_shared_completion_fetch_survives_one_editor_closing_and_cancels_with_its_owner() {
    let window = Rc::new(RefCell::new(completion_index()));
    let requesting_editor = window.clone();
    let remaining_editor = window.clone();
    let request = request_one(&mut requesting_editor.borrow_mut());
    let token = window.borrow().column_request_token();

    drop(requesting_editor);

    assert!(!token.is_cancelled());
    assert!(
        remaining_editor
            .borrow_mut()
            .request_missing_columns(vec!["public.users".into()])
            .is_empty()
    );
    assert!(
        remaining_editor
            .borrow_mut()
            .complete_column_request(&request, Ok(vec!["id".into()]))
    );
    assert_eq!(
        remaining_editor.borrow().columns_for("public.users"),
        Some(&vec!["id".into()])
    );
    drop(remaining_editor);
    assert!(!token.is_cancelled());

    drop(window);

    assert!(token.is_cancelled());
}

#[tokio::test]
async fn a_pending_shared_fetch_survives_the_requesting_editor_closing() {
    let (started, started_rx) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    let connection: Arc<dyn tablepro_core::Connection> = Arc::new(IdentityConnection::held(started, release_rx));
    let identity = crate::connection_identity::ConnectionIdentity::from_connection(&connection);
    let mut index = completion_index();
    index.sync_connection(&identity);
    index.set_tables(vec!["public.users".into()]);
    let shared = Rc::new(RefCell::new(index));
    let requesting_editor = shared.clone();
    let remaining_editor = shared.clone();
    let request = request_one(&mut requesting_editor.borrow_mut());
    let token = shared.borrow().column_request_token();
    let fetch = tokio::spawn(fetch_column_names(
        connection.clone(),
        request,
        Some(SqlGrammar::PostgreSql),
        0,
        token.clone(),
    ));

    assert!(started_rx.await.is_ok());
    drop(requesting_editor);
    assert!(!token.is_cancelled());
    assert!(release.send(()).is_ok());
    let Ok((request, columns)) = fetch.await else {
        panic!("the shared completion read task failed");
    };
    assert!(
        remaining_editor
            .borrow_mut()
            .complete_column_request_for_connection(&identity, &request, columns)
    );
    assert!(remaining_editor.borrow().knows_columns("public.users"));
}

#[tokio::test]
async fn completion_column_reads_obey_the_configured_timeout() {
    let (started, started_rx) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    let connection: Arc<dyn tablepro_core::Connection> = Arc::new(IdentityConnection::held(started, release_rx));
    let task = tokio::spawn(fetch_column_names(
        connection,
        SchemaRequest {
            generation: 0,
            table: "public.users".into(),
        },
        Some(SqlGrammar::PostgreSql),
        1,
        CancellationToken::new(),
    ));

    assert!(started_rx.await.is_ok());
    let Ok((_, result)) = task.await else {
        panic!("the timed completion read task failed");
    };
    assert_eq!(result, Err(()));
    assert!(release.send(()).is_err());
}

#[test]
fn a_failed_completion_fetch_can_be_admitted_again() {
    let mut index = completion_index();
    let request = request_one(&mut index);

    assert!(index.complete_column_request(&request, Err(())));
    let retry = request_one(&mut index);
    assert!(index.complete_column_request(&retry, Ok(Vec::new())));
    assert!(index.request_missing_columns(vec!["public.users".into()]).is_empty());
}

#[test]
fn refreshing_table_names_keeps_in_flight_column_fetches() {
    let mut index = completion_index();
    let request = request_one(&mut index);
    let token = index.column_request_token();

    index.set_tables(vec!["public.users".into(), "public.orders".into()]);

    assert!(!token.is_cancelled());
    assert!(index.complete_column_request(&request, Ok(vec!["id".into()])));
    assert_eq!(index.columns_for("public.users"), Some(&vec!["id".into()]));
}

#[test]
fn schema_invalidation_cancels_pending_reads_and_rejects_late_results() {
    let mut index = completion_index();
    let request = request_one(&mut index);
    let token = index.column_request_token();

    index.invalidate_columns();

    assert!(token.is_cancelled());
    assert_eq!(index.request(String::new()).generation, request.generation + 1);
    assert!(!index.complete_column_request(&request, Ok(vec!["stale".into()])));
}

#[test]
fn clearing_connection_metadata_cancels_pending_reads_and_retires_the_generation() {
    let mut index = completion_index();
    let request = request_one(&mut index);
    let token = index.column_request_token();

    index.clear();

    assert!(token.is_cancelled());
    assert_eq!(index.request(String::new()).generation, request.generation + 1);
    assert!(!index.complete_column_request(&request, Ok(vec!["stale".into()])));
}

#[test]
fn connection_replacement_cancels_old_fetches_and_rejects_late_results() {
    let first: Arc<dyn tablepro_core::Connection> = Arc::new(IdentityConnection::ready());
    let replacement: Arc<dyn tablepro_core::Connection> = Arc::new(IdentityConnection::ready());
    let mut index = completion_index();
    let first_identity = crate::connection_identity::ConnectionIdentity::from_connection(&first);
    let replacement_identity = crate::connection_identity::ConnectionIdentity::from_connection(&replacement);

    assert!(index.sync_connection(&first_identity));
    index.set_tables(vec!["public.users".into()]);
    let request = request_one(&mut index);
    let token = index.column_request_token();
    let old_generation = request.generation;
    assert!(!index.sync_connection(&first_identity));

    assert!(!index.complete_column_request_for_connection(&replacement_identity, &request, Err(())));

    assert!(token.is_cancelled());
    assert_eq!(index.request(String::new()).generation, old_generation + 1);
    index.set_tables(vec!["public.users".into()]);
    let next = request_one(&mut index);
    assert!(!index.complete_column_request(&request, Ok(vec!["stale".into()])));
    assert!(index.request_missing_columns(vec!["public.users".into()]).is_empty());
    assert!(index.complete_column_request(&next, Ok(vec!["id".into()])));
    assert_eq!(index.columns_for("public.users"), Some(&vec!["id".into()]));
    assert!(!index.column_request_token().is_cancelled());
}

fn completion_index() -> SchemaIndex {
    let mut index = SchemaIndex {
        grammar: Some(SqlGrammar::PostgreSql),
        ..SchemaIndex::default()
    };
    index.set_tables(vec!["public.users".into()]);
    index
}

fn request_one(index: &mut SchemaIndex) -> SchemaRequest {
    let mut requests = index.request_missing_columns(vec!["public.users".into()]);
    assert_eq!(requests.len(), 1);
    requests.remove(0)
}

struct IdentityConnection {
    started: tokio::sync::Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    release: tokio::sync::Mutex<Option<tokio::sync::oneshot::Receiver<()>>>,
}

impl IdentityConnection {
    fn ready() -> Self {
        Self {
            started: tokio::sync::Mutex::new(None),
            release: tokio::sync::Mutex::new(None),
        }
    }

    fn held(started: tokio::sync::oneshot::Sender<()>, release: tokio::sync::oneshot::Receiver<()>) -> Self {
        Self {
            started: tokio::sync::Mutex::new(Some(started)),
            release: tokio::sync::Mutex::new(Some(release)),
        }
    }
}

#[async_trait::async_trait]
impl tablepro_core::Connection for IdentityConnection {
    async fn list_tables(&self) -> Result<Vec<tablepro_core::TableInfo>, tablepro_core::DriverError> {
        Ok(Vec::new())
    }

    async fn fetch_columns(
        &self,
        _schema: Option<&str>,
        _table: &str,
    ) -> Result<Vec<tablepro_core::ColumnInfo>, tablepro_core::DriverError> {
        if let Some(started) = self.started.lock().await.take() {
            let _ = started.send(());
        }
        if let Some(release) = self.release.lock().await.take() {
            let _ = release.await;
        }
        Ok(Vec::new())
    }

    async fn fetch_rows(
        &self,
        _schema: Option<&str>,
        _table: &str,
        _offset: u64,
        _limit: u64,
    ) -> Result<tablepro_core::QueryResult, tablepro_core::DriverError> {
        Err(tablepro_core::DriverError::Unsupported("unused".into()))
    }

    async fn query(&self, _sql: &str) -> Result<tablepro_core::QueryResult, tablepro_core::DriverError> {
        Err(tablepro_core::DriverError::Unsupported("unused".into()))
    }

    async fn execute(&self, _sql: &str) -> Result<tablepro_core::ExecResult, tablepro_core::DriverError> {
        Err(tablepro_core::DriverError::Unsupported("unused".into()))
    }

    async fn execute_params(
        &self,
        _sql: &str,
        _params: &[tablepro_core::Value],
    ) -> Result<tablepro_core::ExecResult, tablepro_core::DriverError> {
        Err(tablepro_core::DriverError::Unsupported("unused".into()))
    }

    async fn execute_in_transaction(
        &self,
        _statements: &[(String, Vec<tablepro_core::Value>)],
    ) -> Result<Vec<u64>, tablepro_core::DriverError> {
        Err(tablepro_core::DriverError::Unsupported("unused".into()))
    }

    async fn ping(&self) -> Result<(), tablepro_core::DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), tablepro_core::DriverError> {
        Ok(())
    }
}

fn candidates(sql: &str) -> Vec<String> {
    let cursor = sql.find('|').expect("cursor marker");
    let cleaned = sql.replace('|', "");
    candidate_words(&cleaned, cursor, &index())
}

#[test]
fn after_from_only_tables_are_offered() {
    let words = candidates("SELECT * FROM |");
    assert!(words.contains(&"public.users".to_string()));
    assert!(words.contains(&"users".to_string()));
    assert!(!words.contains(&"email".to_string()));
}

#[test]
fn after_a_table_alias_only_that_table_columns_are_offered() {
    let words = candidates("SELECT u.| FROM public.users AS u");
    assert_eq!(words, vec!["created_at".to_string(), "email".into(), "id".into()]);
}

#[test]
fn an_alias_without_as_still_resolves() {
    let words = candidates("SELECT o.| FROM public.orders o");
    assert!(words.contains(&"total".to_string()));
    assert!(!words.contains(&"email".to_string()));
}

#[test]
fn a_table_name_qualifier_resolves_without_an_alias() {
    let words = candidates("SELECT users.| FROM public.users");
    assert!(words.contains(&"email".to_string()));
    assert!(!words.contains(&"total".to_string()));
}

#[test]
fn select_list_offers_columns_of_tables_named_later_in_the_statement() {
    let words = candidates("SELECT | FROM public.orders");
    assert!(words.contains(&"user_id".to_string()));
    assert!(!words.contains(&"email".to_string()));
}

#[test]
fn where_clause_offers_columns_from_every_joined_table() {
    let words = candidates("SELECT * FROM public.users u JOIN public.orders o ON o.user_id = u.id WHERE |");
    assert!(words.contains(&"email".to_string()));
    assert!(words.contains(&"total".to_string()));
}

#[test]
fn an_unknown_qualifier_offers_nothing_rather_than_every_column() {
    let words = candidates("SELECT nope.| FROM public.users");
    assert!(words.is_empty());
}

#[test]
fn the_statement_under_the_cursor_decides_the_scope() {
    let words = candidates("SELECT * FROM public.users; SELECT | FROM public.orders");
    assert!(words.contains(&"total".to_string()));
    assert!(!words.contains(&"email".to_string()));
}

#[test]
fn a_semicolon_inside_a_literal_does_not_split_the_statement() {
    let words = candidates("SELECT ';' , | FROM public.orders");
    assert!(words.contains(&"total".to_string()));
}

#[test]
fn update_offers_tables_then_columns_for_set() {
    let tables = candidates("UPDATE |");
    assert!(tables.contains(&"public.orders".to_string()));
    let columns = candidates("UPDATE public.orders SET |");
    assert!(columns.contains(&"total".to_string()));
}

#[test]
fn referenced_tables_reports_what_needs_columns() {
    let sql = "SELECT * FROM public.users u JOIN orders o ON o.user_id = u.id";
    assert_eq!(
        referenced_tables(sql, sql.len(), Some(SqlGrammar::PostgreSql)),
        vec!["public.users".to_string(), "orders".into()]
    );
}

#[test]
fn a_schema_qualifier_in_table_position_offers_tables() {
    let words = candidates("SELECT * FROM public.|");
    assert!(words.contains(&"public.users".to_string()));
    assert!(!words.contains(&"email".to_string()));
}

#[test]
fn a_cursor_past_the_end_is_clamped() {
    let sql = "SELECT * FROM public.users";
    let words = candidate_words(sql, sql.len() + 50, &index());
    assert!(words.contains(&"public.users".to_string()));
}

#[test]
fn multibyte_text_before_the_cursor_does_not_panic() {
    let sql = "SELECT 'héllo→', ";
    let words = candidate_words(sql, sql.len(), &index());
    assert!(!words.is_empty());
}

#[test]
fn quoted_aliases_and_whitespace_around_dots_keep_identity() {
    let mut index = index();
    index.set_columns(r#""odd.schema"."a.b""#, vec!["exact_column".into()]);
    for (prefix, tail) in [
        (r#"SELECT "Case Alias"."#, r#" FROM "odd.schema"."a.b" AS "Case Alias""#),
        ("SELECT x.", r#" FROM "odd.schema" . "a.b" AS x"#),
        (r#"SELECT "odd.schema"."a.b"."#, r#" FROM "odd.schema"."a.b""#),
    ] {
        let sql = format!("{prefix}{tail}");
        assert_eq!(candidate_words(&sql, prefix.len(), &index), vec!["exact_column"]);
    }
}

#[test]
fn postgres_quoted_relations_keep_distinct_columns_and_aliases() {
    let mut index = index();
    index.set_columns("public.\"Users\"", vec!["quoted_only".into()]);
    assert_eq!(
        index.columns_for("public.users").unwrap(),
        &vec!["id", "email", "created_at"]
    );
    assert_eq!(index.columns_for("public.\"Users\"").unwrap(), &vec!["quoted_only"]);
    let sql = "SELECT u. FROM public.\"Users\" AS u";
    assert_eq!(candidate_words(sql, "SELECT u.".len(), &index), vec!["quoted_only"]);
}

#[test]
fn postgres_quoted_dots_and_spaces_keep_complete_table_references() {
    let mut index = index();
    for name in [r#""odd.schema"."a.b""#, r#"public."a""b""#, r#"public."with space""#] {
        index.set_columns(name, vec!["exact_column".into()]);
        let sql = format!("SELECT x. FROM {name} AS x");
        assert_eq!(referenced_tables(&sql, sql.len(), index.grammar), vec![name]);
        assert_eq!(candidate_words(&sql, "SELECT x.".len(), &index), vec!["exact_column"]);
    }
}

#[test]
fn table_key_keeps_the_schema_and_ignores_quoting_and_case() {
    assert_eq!(
        table_key("public.\"Users\"", Some(SqlGrammar::Sqlite)).as_deref(),
        Some("public\0users")
    );
    assert_eq!(
        table_key("`orders`", Some(SqlGrammar::MySql)).as_deref(),
        Some("orders")
    );
    assert_eq!(
        table_key("[dbo].[Items]", Some(SqlGrammar::MsSql)).as_deref(),
        Some("dbo\0items")
    );
}

#[test]
fn a_double_quoted_name_keeps_its_case_and_stays_distinct() {
    let grammar = Some(SqlGrammar::PostgreSql);
    assert_ne!(
        table_key("public.\"Users\"", grammar),
        table_key("public.users", grammar)
    );
    assert_eq!(
        table_key("public.\"users\"", grammar),
        table_key("public.users", grammar)
    );
    assert_ne!(table_key("\"a.b\"", grammar), table_key("a.b", grammar));
    assert_ne!(table_key("public.\"a\"\"b\"", grammar), table_key("public.ab", grammar));
}

#[test]
fn two_spellings_keep_their_own_columns() {
    let mut index = SchemaIndex {
        grammar: Some(SqlGrammar::PostgreSql),
        ..SchemaIndex::default()
    };
    index.set_columns("public.users", vec!["id".into()]);
    index.set_columns("public.\"Users\"", vec!["Id".into(), "name".into()]);
    assert_eq!(index.columns_for("public.users"), Some(&vec!["id".to_string()]));
    assert_eq!(
        index.columns_for("public.\"Users\""),
        Some(&vec!["Id".to_string(), "name".to_string()])
    );
}

#[test]
fn a_reference_splits_on_dots_outside_quotes() {
    use super::super::completion_identifiers::split_table_reference;
    let grammar = Some(SqlGrammar::PostgreSql);
    assert_eq!(
        split_table_reference(r#""odd.schema"."a.b""#, grammar),
        Some((Some("odd.schema".into()), "a.b".into()))
    );
    assert_eq!(
        split_table_reference(r#"public."a""b""#, grammar),
        Some((Some("public".into()), "a\"b".into()))
    );
}

#[test]
fn quoted_names_with_spaces_unicode_and_reserved_words_keep_their_identity() {
    use super::super::completion_identifiers::split_table_reference;
    let grammar = Some(SqlGrammar::PostgreSql);
    for (reference, schema, table) in [
        (r#""my schema"."order items""#, "my schema", "order items"),
        (r#""café"."Таблица""#, "café", "Таблица"),
        (r#"public."select""#, "public", "select"),
    ] {
        assert_eq!(
            split_table_reference(reference, grammar),
            Some((Some(schema.into()), table.into()))
        );
    }
    assert_ne!(
        table_key(r#"public."Select""#, grammar),
        table_key("public.select", grammar)
    );
    assert_eq!(
        table_key(r#"public."select""#, grammar),
        table_key("PUBLIC.SELECT", grammar)
    );
    assert_ne!(table_key(r#""Café""#, grammar), table_key("café", grammar));
}

#[test]
fn invalid_neighbours_of_quoted_names_do_not_panic_or_merge() {
    let grammar = Some(SqlGrammar::PostgreSql);
    for invalid in [r#""unterminated"#, r#""a"""#, "", "."] {
        assert!(table_key(invalid, grammar).is_none());
    }
    assert_ne!(table_key(r#""a".b"#, grammar), table_key(r#""a.b""#, grammar));
}

fn index_with(tables: &[(&str, &[&str])]) -> SchemaIndex {
    let mut index = SchemaIndex::default();
    for (table, columns) in tables {
        index.set_columns(table, columns.iter().map(|column| column.to_string()).collect());
    }
    index
}

#[test]
fn clearing_connection_metadata_removes_cached_candidates_and_retires_requests() {
    let mut index = SchemaIndex {
        grammar: Some(SqlGrammar::PostgreSql),
        ..SchemaIndex::default()
    };
    index.set_tables(vec!["public.safety_items".into()]);
    index.set_columns("public.safety_items", vec!["note".into()]);
    let request = index.request("public.safety_items".into());
    assert!(
        super::candidates("SELECT * FROM ", 14, &index, None, false, str::to_string)
            .iter()
            .any(|candidate| candidate == "public.safety_items")
    );

    index.clear();

    assert!(index.tables.is_empty());
    assert!(index.columns.is_empty());
    assert_eq!(index.grammar, None);
    assert!(!index.accepts(&request));
    let keyword_candidates = super::super::completion_proposals::candidates("SEL", 3, &index);
    assert!(
        keyword_candidates
            .values
            .iter()
            .any(|(label, value)| label == "SELECT" && value == "SELECT")
    );
    assert!(
        !super::candidates("SELECT * FROM ", 14, &index, None, false, str::to_string)
            .iter()
            .any(|candidate| candidate == "public.safety_items")
    );
}

#[test]
fn same_named_tables_in_two_schemas_keep_separate_columns() {
    let index = index_with(&[("a.items", &["a_id"]), ("b.items", &["b_id"])]);
    assert_eq!(index.columns_for("a.items"), Some(&vec!["a_id".to_string()]));
    assert_eq!(index.columns_for("B.Items"), Some(&vec!["b_id".to_string()]));
}

#[test]
fn an_unqualified_name_that_matches_two_schemas_offers_no_columns() {
    let index = index_with(&[("a.items", &["a_id"]), ("b.items", &["b_id"])]);
    assert_eq!(index.columns_for("items"), None);
    assert!(!index.knows_columns("items"));
}

#[test]
fn an_unqualified_name_resolves_when_only_one_schema_has_it() {
    let index = index_with(&[("a.items", &["a_id"]), ("a.orders", &["o_id"])]);
    assert_eq!(index.columns_for("items"), Some(&vec!["a_id".to_string()]));
    assert!(index.knows_columns("Items"));
}
