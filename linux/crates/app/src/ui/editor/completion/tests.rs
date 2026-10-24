use std::rc::Rc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use sourceview5::CompletionColumn;
use sourceview5::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectKind, ObjectScope, SchemaInfo};
use tablepro_core::{ColumnInfo, TableRef};
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

use super::proposal_kind::ProposalKind;
use super::sql_completion_provider::{
    CONTEXT_AFTER, CONTEXT_BEFORE, SqlCompletionProvider, column_text, context_bounds, replace_word,
};
use super::sql_proposal::SqlProposal;
use crate::services::active_session::ActiveSession;
use crate::services::snippet_library::{SnippetLibrary, SnippetOrigin};
use crate::test_support::{FakeSession, MemorySettings, descendants, finish_on_main, test_runtime, wait_until};
use crate::ui::editor::{SqlEditor, SqlEditorInit};

const WAIT: Duration = Duration::from_secs(10);

struct Harness {
    provider: SqlCompletionProvider,
    session: Option<FakeSession>,
    _runtime: crate::runtime::AppRuntime,
}

impl Harness {
    fn fetched_columns(&self) -> usize {
        self.session
            .as_ref()
            .map_or(0, |fake| CallCounters::get(&fake.connection.counters().fetch_columns))
    }

    fn listed_objects(&self) -> usize {
        self.session
            .as_ref()
            .map_or(0, |fake| CallCounters::get(&fake.connection.counters().list_objects))
    }
}

fn object(name: &str, kind: ObjectKind) -> ObjectInfo {
    ObjectInfo {
        schema: Some("public".to_owned()),
        name: name.to_owned(),
        kind,
    }
}

fn column(name: &str, data_type: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: tablepro_core::column::ColumnType::untyped_text(data_type),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: tablepro_core::column::ColumnDefault::None,
        comment: None,
    }
}

fn schema(name: &str, is_default: bool) -> SchemaInfo {
    SchemaInfo {
        name: name.to_owned(),
        is_default,
        is_system: false,
    }
}

/// A provider on a session whose default schema holds `objects`.
fn connected(script: ConnectionScript, objects: Vec<ObjectInfo>) -> Harness {
    connected_with(script, Vec::new(), objects)
}

/// A provider on a session that has `schemas`, and whose default
/// schema holds `objects`.
fn connected_with(script: ConnectionScript, schemas: Vec<SchemaInfo>, objects: Vec<ObjectInfo>) -> Harness {
    let runtime = test_runtime();
    let fake = FakeSession::start(script, [], runtime.tasks());
    fake.session.catalog().commit(schemas, objects);
    let active = ActiveSession::new();
    active.replace(fake.session.clone());
    Harness {
        provider: SqlCompletionProvider::new(active, runtime.tasks(), crate::test_support::builtin_snippets_only()),
        session: Some(fake),
        _runtime: runtime,
    }
}

fn unconnected() -> Harness {
    let runtime = test_runtime();
    Harness {
        provider: SqlCompletionProvider::new(
            ActiveSession::new(),
            runtime.tasks(),
            crate::test_support::builtin_snippets_only(),
        ),
        session: None,
        _runtime: runtime,
    }
}

/// The word before the `|` in `marked`, and where it starts.
fn word_before(marked: &str) -> (String, i32, String) {
    let cursor = marked.find('|').expect("a cursor mark");
    let text = marked.replacen('|', "", 1);
    let word: String = marked[..cursor]
        .chars()
        .rev()
        .take_while(|c| c.is_alphanumeric() || *c == '_')
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    let start = marked[..cursor].chars().count() - word.chars().count();
    (text, i32::try_from(start).expect("a short text"), word)
}

fn proposals(harness: &Harness, marked: &str) -> Vec<SqlProposal> {
    let (text, start, word) = word_before(marked);
    let buffer = gtk4::TextBuffer::new(None);
    buffer.set_text(&text);
    let provider = harness.provider.clone();
    let model =
        finish_on_main(WAIT, async move { provider.proposals(&buffer, start, &word).await }).expect("the proposals");
    (0..model.n_items())
        .filter_map(|index| model.item(index).and_downcast::<SqlProposal>())
        .collect()
}

fn labels(proposals: &[SqlProposal]) -> Vec<&str> {
    proposals.iter().map(SqlProposal::label).collect()
}

fn find<'a>(proposals: &'a [SqlProposal], label: &str) -> &'a SqlProposal {
    proposals
        .iter()
        .find(|proposal| proposal.label() == label)
        .unwrap_or_else(|| panic!("no proposal {label} in {:?}", labels(proposals)))
}

#[gtk4::test]
fn populate_after_from_contains_users() {
    let harness = connected(
        ConnectionScript::default(),
        vec![
            object("users", ObjectKind::Table),
            object("active_users", ObjectKind::View),
            object("users_seq", ObjectKind::Sequence),
            object("refresh_users", ObjectKind::Function),
            object("orders", ObjectKind::Table),
        ],
    );

    let found = proposals(&harness, "SELECT * FROM us|");

    assert_eq!(labels(&found), ["users", "active_users"]);
    assert_eq!(find(&found, "active_users").kind(), &ProposalKind::View);
}

#[gtk4::test]
fn populate_alias_dot_lists_columns_with_types() {
    let mut script = ConnectionScript::default();
    script.fetch_columns.when_sql_contains(
        "users",
        FakeReply::ok(vec![column("id", "integer"), column("email", "text")]),
    );
    let harness = connected(script, vec![object("users", ObjectKind::Table)]);

    let found = proposals(&harness, "SELECT u.| FROM users u");

    assert_eq!(labels(&found), ["id", "email"]);
    let id = find(&found, "id");
    assert_eq!(
        id.kind(),
        &ProposalKind::Column {
            data_type: "integer".to_owned(),
            table: TableRef::new(Some("public".to_owned()), "users"),
        },
        "the column was read under a name the catalog does not share"
    );
    assert_eq!(column_text(id, CompletionColumn::After).as_deref(), Some("integer"));
    assert_eq!(
        column_text(id, CompletionColumn::Comment).as_deref(),
        Some("public.users")
    );
}

#[gtk4::test]
fn general_scope_offers_the_statements_columns_and_keywords() {
    let mut script = ConnectionScript::default();
    script
        .fetch_columns
        .when_sql_contains("users", FakeReply::ok(vec![column("name", "text")]));
    let harness = connected(script, vec![object("users", ObjectKind::Table)]);

    let found = proposals(&harness, "SELECT | FROM users");

    assert!(labels(&found).contains(&"name"));
    assert!(labels(&found).contains(&"users"));
    assert!(labels(&found).contains(&"WHERE"));
    assert_eq!(labels(&found).first(), Some(&"name"), "a column is not first");
}

#[gtk4::test]
fn keyword_case_follows_prefix() {
    let harness = unconnected();

    for (typed, expected) in [("sel", "select"), ("SEL", "SELECT")] {
        let found = proposals(&harness, &format!("{typed}|"));
        let select = find(&found, "SELECT");
        let buffer = gtk4::TextBuffer::new(None);
        buffer.set_text(typed);

        replace_word(
            &buffer,
            buffer.start_iter(),
            buffer.end_iter(),
            &select.insert_text(typed),
        );

        let (start, end) = buffer.bounds();
        assert_eq!(buffer.text(&start, &end, false), expected);
        assert_eq!(select.shown_text(typed), expected);
    }
}

#[gtk4::test]
fn activate_replaces_word_as_one_undo_step() {
    let buffer = sourceview5::Buffer::new(None);
    buffer.begin_irreversible_action();
    buffer.set_text("SELECT * FROM us WHERE true");
    buffer.end_irreversible_action();
    let text = |buffer: &sourceview5::Buffer| {
        let (start, end) = buffer.bounds();
        buffer.text(&start, &end, false).to_string()
    };

    replace_word(
        buffer.upcast_ref(),
        buffer.iter_at_offset(14),
        buffer.iter_at_offset(16),
        "users",
    );
    assert_eq!(text(&buffer), "SELECT * FROM users WHERE true");

    buffer.undo();
    assert_eq!(text(&buffer), "SELECT * FROM us WHERE true");
    assert!(!buffer.can_undo(), "the completion took more than one undo step");
}

#[gtk4::test]
fn a_cursor_inside_a_word_replaces_all_of_it() {
    let buffer = gtk4::TextBuffer::new(None);
    buffer.set_text("SELECT * FROM usrs");

    replace_word(&buffer, buffer.iter_at_offset(14), buffer.iter_at_offset(16), "users");

    let (start, end) = buffer.bounds();
    assert_eq!(buffer.text(&start, &end, false), "SELECT * FROM users");
}

#[gtk4::test]
fn identifier_needing_quotes_is_quoted_by_dialect() {
    let harness = connected(
        ConnectionScript::default(),
        vec![
            object("Order Items", ObjectKind::Table),
            object("users", ObjectKind::Table),
            object("to", ObjectKind::Table),
        ],
    );

    let found = proposals(&harness, "SELECT * FROM |");

    assert_eq!(find(&found, "Order Items").insert_text(""), "\"Order Items\"");
    assert_eq!(find(&found, "users").insert_text(""), "users");
    assert_eq!(
        find(&found, "to").insert_text(""),
        "\"to\"",
        "a reserved word the editor does not complete went in bare"
    );
}

#[gtk4::test]
fn a_dot_in_a_number_proposes_nothing() {
    let harness = connected(ConnectionScript::default(), vec![object("users", ObjectKind::Table)]);

    assert!(proposals(&harness, "SELECT * FROM users WHERE price > 0.|").is_empty());
}

#[gtk4::test]
fn a_schema_prefix_is_matched_without_case() {
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(vec![ObjectInfo {
        schema: Some("sales".to_owned()),
        name: "orders".to_owned(),
        kind: ObjectKind::Table,
    }]));
    let harness = connected_with(
        script,
        vec![schema("public", true), schema("sales", false)],
        vec![object("users", ObjectKind::Table)],
    );

    let found = proposals(&harness, "SELECT * FROM Sales.|");

    assert_eq!(labels(&found), ["orders"]);
    let session = &harness.session.as_ref().expect("a session").session;
    let listed = session.subscribe_objects(ObjectScope::Schema("sales".to_owned()));
    assert_eq!(
        listed.borrow().objects.len(),
        1,
        "the schema was read under the name as typed"
    );
}

#[gtk4::test]
fn a_prefix_that_names_no_schema_reads_nothing() {
    let harness = connected_with(
        ConnectionScript::default(),
        vec![schema("public", true)],
        vec![object("users", ObjectKind::Table)],
    );

    let listed = harness.listed_objects();

    let found = proposals(&harness, "SELECT * FROM hr.|");

    assert!(found.is_empty());
    assert_eq!(harness.listed_objects(), listed);
}

#[gtk4::test]
fn names_the_catalog_does_not_hold_are_not_read() {
    let mut script = ConnectionScript::default();
    script
        .fetch_columns
        .always(FakeReply::ok(vec![column("id", "integer")]));
    let harness = connected(script, vec![object("users", ObjectKind::Table)]);
    let fetched = harness.fetched_columns();

    let found = proposals(
        &harness,
        "WITH recent AS (SELECT * FROM users) SELECT | FROM recent r, (SELECT 1) s WHERE EXTRACT(YEAR FROM r.at) > 0",
    );

    assert!(labels(&found).contains(&"id"));
    assert_eq!(
        harness.fetched_columns() - fetched,
        1,
        "a name the catalog does not hold was read"
    );
}

#[gtk4::test]
fn a_database_prefix_lists_the_schemas_objects() {
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(vec![ObjectInfo {
        schema: Some("sales".to_owned()),
        name: "invoices".to_owned(),
        kind: ObjectKind::Table,
    }]));
    let harness = connected_with(
        script,
        vec![schema("dbo", true), schema("sales", false)],
        vec![object("users", ObjectKind::Table)],
    );
    let fetched = harness.fetched_columns();

    let found = proposals(&harness, "SELECT * FROM shop.sales.|");

    assert_eq!(labels(&found), ["invoices"]);
    assert_eq!(harness.fetched_columns(), fetched, "the schema was read as a table");
}

#[gtk4::test]
fn a_schema_and_table_prefix_lists_the_tables_columns() {
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(vec![ObjectInfo {
        schema: Some("sales".to_owned()),
        name: "invoices".to_owned(),
        kind: ObjectKind::Table,
    }]));
    script
        .fetch_columns
        .when_sql_contains("invoices", FakeReply::ok(vec![column("total", "numeric")]));
    let harness = connected_with(
        script,
        vec![schema("public", true), schema("sales", false)],
        vec![object("users", ObjectKind::Table)],
    );

    let found = proposals(&harness, "SELECT sales.invoices.| FROM x");

    assert_eq!(labels(&found), ["total"]);
}

#[gtk4::test]
fn a_large_buffer_is_read_only_near_the_cursor() {
    let buffer = gtk4::TextBuffer::new(None);
    buffer.set_text(&format!("{}SELECT * FROM us", "SELECT 1;\n".repeat(30_000)));
    let word_start = buffer.char_count() - 2;

    let (start, end) = context_bounds(&buffer, word_start);

    assert!(start.starts_line(), "the window opened mid-line");
    assert!(word_start - start.offset() <= CONTEXT_BEFORE);
    assert!(end.is_end());
    let (start, end) = context_bounds(&buffer, 5);
    assert!(start.is_start());
    assert_eq!(end.offset(), 5 + CONTEXT_AFTER);
    let small = gtk4::TextBuffer::new(None);
    small.set_text("SELECT * FROM us");
    let (start, end) = context_bounds(&small, 14);
    assert!(start.is_start() && end.is_end(), "a small buffer was not read whole");
}

#[gtk4::test]
fn a_completion_at_the_end_of_a_large_buffer_still_finds_tables() {
    let harness = connected(ConnectionScript::default(), vec![object("users", ObjectKind::Table)]);
    let marked = format!("{}SELECT * FROM us|", "SELECT 1;\n".repeat(30_000));

    let found = proposals(&harness, &marked);

    assert_eq!(labels(&found), ["users"]);
}

#[gtk4::test]
fn nothing_is_proposed_inside_a_string() {
    let harness = connected(ConnectionScript::default(), vec![object("users", ObjectKind::Table)]);

    assert!(proposals(&harness, "SELECT 'us|").is_empty());
}

#[gtk4::test]
fn refilter_narrows_the_list_without_reading_again() {
    let harness = connected(
        ConnectionScript::default(),
        vec![object("users", ObjectKind::Table), object("orders", ObjectKind::Table)],
    );
    let (text, start, word) = word_before("SELECT * FROM |");
    let buffer = gtk4::TextBuffer::new(None);
    buffer.set_text(&text);
    let provider = harness.provider.clone();
    let model =
        finish_on_main(WAIT, async move { provider.proposals(&buffer, start, &word).await }).expect("the proposals");
    assert_eq!(model.n_items(), 2);
    let listed = harness.listed_objects();

    harness.provider.refilter("ord", &model);

    wait_until(WAIT, || model.n_items() == 1).expect("the list narrowed");
    assert_eq!(
        model
            .item(0)
            .and_downcast::<SqlProposal>()
            .map(|proposal| proposal.label().to_owned()),
        Some("orders".to_owned())
    );
    harness.provider.refilter("", &model);
    wait_until(WAIT, || model.n_items() == 2).expect("the list widened");
    assert_eq!(harness.listed_objects(), listed, "a refilter read the catalog again");
}

/// Accept the built-in snippet for `trigger` over the word before the
/// cursor, as the provider does when its row is chosen. GtkSourceView's
/// list is left out: under the test harness it can close between two
/// keys, which no user sees in the running app.
pub(crate) fn accept_builtin_snippet(view: &sourceview5::View, trigger: &str) {
    let library = crate::test_support::builtin_snippets_only();
    let offered = library
        .offered(None, tablepro_core::sql_syntax::SqlGrammar::PostgreSql)
        .into_iter()
        .find(|snippet| snippet.trigger == trigger)
        .unwrap_or_else(|| panic!("no built-in {trigger}"));
    let snippet = library.snippet(&offered).expect("the built-in parses");
    let buffer = view.buffer();
    let end = buffer.iter_at_offset(buffer.cursor_position());
    let mut begin = end;
    begin.backward_word_start();
    super::sql_completion_provider::replace_word_with_snippet(view, &snippet, begin, end);
}

/// The texts of the completion list GtkSourceView shows for `view`.
fn shown(view: &sourceview5::View) -> Vec<String> {
    descendants(view)
        .into_iter()
        .filter_map(|widget| widget.downcast::<sourceview5::CompletionCell>().ok())
        .filter_map(|cell| cell.text())
        .map(|text| text.to_string())
        .collect()
}

/// An editor in a window on screen, with the focus in its text.
struct OnScreen {
    editor: SqlEditor,
    window: gtk4::Window,
    _session: FakeSession,
    _settings: MemorySettings,
    _runtime: crate::runtime::AppRuntime,
}

impl OnScreen {
    fn new(script: ConnectionScript, objects: Vec<ObjectInfo>, text: &str) -> Self {
        Self::with_snippets(script, objects, text, crate::test_support::builtin_snippets_only())
    }

    fn with_snippets(
        script: ConnectionScript,
        objects: Vec<ObjectInfo>,
        text: &str,
        snippets: Rc<SnippetLibrary>,
    ) -> Self {
        crate::register_test_resources();
        let runtime = test_runtime();
        let settings = MemorySettings::new();
        let fake = FakeSession::start(script, [], runtime.tasks());
        fake.session.catalog().commit(Vec::new(), objects);
        let active = ActiveSession::new();
        active.replace(fake.session.clone());
        let editor = SqlEditor::new(SqlEditorInit {
            initial_query: Some(text.to_owned()),
            settings: settings.get().clone(),
            history: None,
            tasks: runtime.tasks(),
            session: active,
            hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
            close_timeout: Duration::from_secs(5),
            snippets,
        });
        let window = gtk4::Window::new();
        window.set_child(Some(&editor));
        window.present();
        let view = editor.imp().source_view.get();
        view.grab_focus();
        // GtkSourceView starts no completion in a view that is not on
        // screen with the focus.
        wait_until(WAIT, || view.is_mapped() && view.has_focus()).expect("the view on screen with the focus");
        Self {
            editor,
            window,
            _session: fake,
            _settings: settings,
            _runtime: runtime,
        }
    }

    fn view(&self) -> sourceview5::View {
        self.editor.imp().source_view.get().upcast()
    }

    /// Wait for the completion list to show `text`, and say what it
    /// showed when it did not.
    fn wait_for(&self, text: &str) -> Result<(), Vec<String>> {
        let view = self.view();
        wait_until(WAIT, || shown(&view).iter().any(|shown| shown == text)).map_err(|_| shown(&view))
    }
}

impl Drop for OnScreen {
    fn drop(&mut self) {
        crate::test_support::drop_focus(&self.window);
        self.window.destroy();
    }
}

#[gtk4::test]
fn the_editor_shows_catalog_tables_in_its_completion() {
    let screen = OnScreen::new(
        ConnectionScript::default(),
        vec![object("users", ObjectKind::Table)],
        "SELECT * FROM us",
    );
    let buffer = screen.view().buffer();
    buffer.place_cursor(&buffer.end_iter());

    screen.view().completion().show();

    screen.wait_for("users").expect("users in the list");
}

#[gtk4::test]
fn typing_a_dot_after_an_alias_lists_its_columns_with_types() {
    let mut script = ConnectionScript::default();
    script
        .fetch_columns
        .when_sql_contains("users", FakeReply::ok(vec![column("id", "integer")]));
    let screen = OnScreen::new(script, vec![object("users", ObjectKind::Table)], "SELECT  FROM users u");
    let buffer = screen.view().buffer();
    buffer.place_cursor(&buffer.iter_at_offset(7));

    buffer.insert_interactive_at_cursor("u", true);
    buffer.insert_interactive_at_cursor(".", true);

    screen.wait_for("id").expect("the alias's column in the list");
    screen.wait_for("integer").expect("the column's type beside it");
}

/// The app starts GtkSourceView, whose stylesheet gives the list its
/// width while its rows are hidden. Without it GDK refused the list after
/// a word with no match, and it never came back.
#[gtk4::test]
fn the_list_comes_back_after_a_word_with_no_match() {
    let test = crate::ui::session_window::tests::TestWindow::connected("CompletionComesBack");
    WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
    let editors = || crate::ui::session_window::tests::editors(&test.window);
    wait_until(WAIT, || editors().len() == 1).expect("an editor tab");
    let view: sourceview5::View = editors()[0].imp().source_view.get().upcast();
    wait_until(WAIT, || view.is_mapped() && view.has_focus()).expect("the editor's text with the focus");
    assert!(comes_back(&view), "the list stayed off screen");
}

/// Types as keys do, one character at a time, since GtkSourceView starts a
/// completion only for a single character typed.
fn comes_back(view: &sourceview5::View) -> bool {
    let buffer = view.buffer();
    // The document's words complete whatever the catalog holds.
    buffer.set_text("SELECT unit_price, units_sold FROM sales;\n");
    buffer.place_cursor(&buffer.end_iter());
    let list = || {
        descendants(view)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk4::Popover>().ok())
            .find(|popover| popover.type_().name() == "GtkSourceCompletionList")
    };
    let shown = || list().is_some_and(|list| list.is_mapped());
    let type_text = |text: &str| {
        for character in text.chars() {
            buffer.insert_interactive_at_cursor(&character.to_string(), true);
            crate::test_support::drain_main_context();
        }
    };

    type_text("un");
    wait_until(WAIT, shown).expect("the list on screen");
    type_text("zq");
    wait_until(WAIT, || list().is_none_or(|list| !list.is_visible())).expect("no match hides the list");
    type_text(" un");
    wait_until(WAIT, shown).is_ok()
}

/// A provider on a session to the engine `driver`, speaking `dialect`,
/// with its snippets from `folder`.
fn on_engine(
    driver: &str,
    dialect: std::sync::Arc<dyn tablepro_core::dialect::SqlDialect>,
    folder: &std::path::Path,
) -> Harness {
    let runtime = test_runtime();
    let mut request = tablepro_session::fakes::FakeConnector::request().expect("a request");
    request.metadata.driver_id = driver.to_owned();
    let script = ConnectionScript {
        dialect,
        ..ConnectionScript::default()
    };
    let fake = FakeSession::start_for(request, script, [], runtime.tasks());
    fake.session.catalog().commit(Vec::new(), Vec::new());
    let active = ActiveSession::new();
    active.replace(fake.session.clone());
    Harness {
        provider: SqlCompletionProvider::new(active, runtime.tasks(), SnippetLibrary::new(folder.to_owned())),
        session: Some(fake),
        _runtime: runtime,
    }
}

fn snippets(proposals: &[SqlProposal]) -> Vec<&str> {
    proposals
        .iter()
        .filter(|proposal| matches!(proposal.kind(), ProposalKind::Snippet(_)))
        .map(SqlProposal::label)
        .collect()
}

#[gtk4::test]
fn typing_ins_offers_the_insert_snippet_first() {
    let harness = unconnected();

    let found = proposals(&harness, "ins|");

    let first = found.first().expect("a proposal");
    assert_eq!(first.label(), "ins");
    assert!(
        matches!(first.kind(), ProposalKind::Snippet(snippet) if matches!(snippet.origin, SnippetOrigin::BuiltIn(_)))
    );
    assert_eq!(
        column_text(first, CompletionColumn::After).as_deref(),
        Some("INSERT INTO … VALUES")
    );
    assert_eq!(column_text(first, CompletionColumn::Comment), None);
    assert!(labels(&found).contains(&"INSERT"), "the keyword is still offered");
}

#[gtk4::test]
fn snippets_are_offered_only_where_a_statement_can_go() {
    let harness = connected(ConnectionScript::default(), vec![object("inserts", ObjectKind::Table)]);

    let after_from = proposals(&harness, "SELECT * FROM ins|");
    let after_dot = proposals(&harness, "SELECT inserts.ins| FROM inserts");

    assert_eq!(snippets(&after_from), Vec::<&str>::new());
    assert_eq!(snippets(&after_dot), Vec::<&str>::new());
    assert_eq!(snippets(&proposals(&harness, "SELECT 1; del|")), ["del"]);
}

#[gtk4::test]
fn a_folder_snippet_is_offered_on_its_engines_connections_only() {
    let folder = tempfile::tempdir().expect("a temporary folder");
    crate::test_support::write_text_file(
        &folder.path().join("postgres.snippets"),
        "<snippets>\n  <snippet _name=\"Vacuum\" trigger=\"vac\">\n    <text languages=\"postgres\">VACUUM ${1:table_name};$0</text>\n  </snippet>\n</snippets>\n",
    );
    let dialect = || -> std::sync::Arc<dyn tablepro_core::dialect::SqlDialect> {
        std::sync::Arc::new(tablepro_test_support::FakeDialect)
    };
    let postgres = on_engine("postgres", dialect(), folder.path());
    let mysql = on_engine("mysql", dialect(), folder.path());

    assert_eq!(snippets(&proposals(&postgres, "vac|")), ["vac"]);
    assert_eq!(snippets(&proposals(&mysql, "vac|")), Vec::<&str>::new());
}

#[gtk4::test]
fn a_redis_connection_is_offered_its_own_snippets_and_nothing_of_sql() {
    let folder = tempfile::tempdir().expect("a temporary folder");
    crate::test_support::write_text_file(
        &folder.path().join("redis.snippets"),
        "<snippets>\n  <snippet trigger=\"scan\">\n    <text languages=\"redis\">SCAN ${1:0} MATCH ${2:pattern}$0</text>\n  </snippet>\n  <snippet trigger=\"cnt\">\n    <text languages=\"sql\">SELECT COUNT(*) FROM ${1:table_name};$0</text>\n  </snippet>\n</snippets>\n",
    );
    let redis = on_engine(
        "redis",
        std::sync::Arc::new(tablepro_driver_redis::RedisDialect),
        folder.path(),
    );

    assert_eq!(labels(&proposals(&redis, "sc|")), ["scan"]);
    assert_eq!(labels(&proposals(&redis, "GET key\nsc|")), ["scan"]);
    for word in ["cnt|", "ins|", "sel|"] {
        assert_eq!(labels(&proposals(&redis, word)), Vec::<&str>::new(), "{word}");
    }
    assert_eq!(redis.listed_objects(), 0, "a Redis completion read the catalog");
}

#[gtk4::test]
fn a_snippet_file_added_while_the_editor_is_open_is_offered() {
    let folder = tempfile::tempdir().expect("a temporary folder");
    let library = SnippetLibrary::new(folder.path().to_owned());
    let screen = OnScreen::with_snippets(ConnectionScript::default(), Vec::new(), "c", library.clone());
    let view = screen.view();
    let buffer = view.buffer();
    buffer.place_cursor(&buffer.end_iter());
    view.completion().show();
    screen.wait_for("ctab").expect("the built-ins in the list");
    assert!(!shown(&view).iter().any(|text| text == "cnt"));
    view.completion().hide();

    crate::test_support::write_text_file(
        &folder.path().join("count.snippets"),
        "<snippets>\n  <snippet trigger=\"cnt\">\n    <text languages=\"sql\">SELECT COUNT(*) FROM ${1:table_name};$0</text>\n  </snippet>\n</snippets>\n",
    );
    wait_until(WAIT, || {
        library
            .offered(Some("fake"), tablepro_core::sql_syntax::SqlGrammar::PostgreSql)
            .iter()
            .any(|snippet| snippet.trigger == "cnt")
    })
    .expect("the library to read the new file");
    view.completion().show();

    screen.wait_for("cnt").expect("the new file's snippet in the list");
}

/// These press real keys on the X display every test shares; nextest runs
/// them with no other test beside them.
mod real_keys {
    use gtk4::gdk;

    use super::*;

    fn selected(buffer: &gtk4::TextBuffer) -> Option<String> {
        buffer
            .selection_bounds()
            .map(|(start, end)| buffer.text(&start, &end, false).to_string())
    }

    #[gtk4::test]
    fn an_accepted_insert_snippet_takes_tab_through_its_stops() {
        let screen = OnScreen::new(ConnectionScript::default(), Vec::new(), "");
        crate::test_support::KeyInjector::focus_only(&screen.window);
        let view = screen.view();
        view.grab_focus();
        wait_until(WAIT, || view.has_focus()).expect("the view with the focus");
        let buffer = view.buffer();
        let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");
        let press = |key: gdk::Key| keys.press(key, gdk::ModifierType::empty()).expect("the key press");
        let text = |buffer: &gtk4::TextBuffer| buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string();

        for key in [gdk::Key::i, gdk::Key::n, gdk::Key::s] {
            press(key);
        }
        wait_until(WAIT, || text(&buffer) == "ins").expect("the keys typed");
        accept_builtin_snippet(&view, "ins");

        wait_until(WAIT, || {
            text(&buffer) == "INSERT INTO table_name (columns)\nVALUES (values);"
        })
        .unwrap_or_else(|_| panic!("the INSERT was not written: {:?}", text(&buffer)));
        assert_eq!(selected(&buffer).as_deref(), Some("table_name"));

        press(gdk::Key::Tab);
        wait_until(WAIT, || selected(&buffer).as_deref() == Some("columns"))
            .unwrap_or_else(|_| panic!("Tab selected {:?}", selected(&buffer)));
        press(gdk::Key::Tab);
        wait_until(WAIT, || selected(&buffer).as_deref() == Some("values"))
            .unwrap_or_else(|_| panic!("Tab selected {:?}", selected(&buffer)));
        press(gdk::Key::Tab);
        wait_until(WAIT, || {
            !buffer.has_selection() && buffer.iter_at_offset(buffer.cursor_position()).is_end()
        })
        .expect("the last Tab to leave the cursor after the statement");
        assert_eq!(text(&buffer), "INSERT INTO table_name (columns)\nVALUES (values);");
    }
}
