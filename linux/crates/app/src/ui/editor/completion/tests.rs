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
        provider: SqlCompletionProvider::new(active, runtime.tasks()),
        session: Some(fake),
        _runtime: runtime,
    }
}

fn unconnected() -> Harness {
    let runtime = test_runtime();
    Harness {
        provider: SqlCompletionProvider::new(ActiveSession::new(), runtime.tasks()),
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

    harness.provider.refilter("ord", &model);

    assert_eq!(model.n_items(), 1);
    assert_eq!(
        model
            .item(0)
            .and_downcast::<SqlProposal>()
            .map(|proposal| proposal.label().to_owned()),
        Some("orders".to_owned())
    );
    harness.provider.refilter("", &model);
    assert_eq!(model.n_items(), 2);
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
        self.editor.imp().source_view.get()
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
