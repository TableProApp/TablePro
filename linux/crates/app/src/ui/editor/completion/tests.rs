use std::rc::Rc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use sourceview5::CompletionColumn;
use sourceview5::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectKind};
use tablepro_core::{ColumnInfo, TableRef};
use tablepro_test_support::{ConnectionScript, FakeReply};

use super::proposal_kind::ProposalKind;
use super::sql_completion_provider::{SqlCompletionProvider, column_text, replace_word};
use super::sql_proposal::SqlProposal;
use crate::services::active_session::ActiveSession;
use crate::test_support::{FakeSession, MemorySettings, descendants, finish_on_main, test_runtime, wait_until};
use crate::ui::editor::{SqlEditor, SqlEditorInit};

const WAIT: Duration = Duration::from_secs(10);

struct Harness {
    provider: SqlCompletionProvider,
    _session: Option<FakeSession>,
    _runtime: crate::runtime::AppRuntime,
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

/// A provider on a session whose default schema holds `objects`.
fn connected(script: ConnectionScript, objects: Vec<ObjectInfo>) -> Harness {
    let runtime = test_runtime();
    let fake = FakeSession::start(script, [], runtime.tasks());
    fake.session.catalog().commit(Vec::new(), objects);
    let active = ActiveSession::new();
    active.replace(fake.session.clone());
    Harness {
        provider: SqlCompletionProvider::new(active, runtime.tasks()),
        _session: Some(fake),
        _runtime: runtime,
    }
}

fn unconnected() -> Harness {
    let runtime = test_runtime();
    Harness {
        provider: SqlCompletionProvider::new(ActiveSession::new(), runtime.tasks()),
        _session: None,
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
        ],
    );

    let found = proposals(&harness, "SELECT * FROM |");

    assert_eq!(find(&found, "Order Items").insert_text(""), "\"Order Items\"");
    assert_eq!(find(&found, "users").insert_text(""), "users");
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
