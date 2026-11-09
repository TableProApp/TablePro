use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;
use std::time::{Duration, SystemTime};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::saved_queries::{NewSavedQuery, SavedQuery};
use tablepro_storage::{QueryHistory, StoragePaths};
use uuid::Uuid;

use super::*;
use crate::runtime::AppRuntime;
use crate::test_support::{OwnedWindow, assert_access_keys, descendants, drain_main_context, test_runtime, wait_until};

// Long enough that a loaded machine cannot decide the outcome; a passing
// test returns as soon as its condition holds.
const WAIT: Duration = Duration::from_secs(30);

struct Harness {
    runtime: AppRuntime,
    hold: Rc<tablepro_session::runtime::CountingHold>,
    store: SavedQueries,
    root: tempfile::TempDir,
}

impl Harness {
    // Each query is its name, its SQL, and the id and name of its connection.
    fn with(queries: &[(&str, &str, Uuid, &str)]) -> Self {
        init();
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
        let store = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(async {
                let store = QueryHistory::open(&paths).await.expect("open").saved_queries();
                for &(name, sql, connection_id, connection_name) in queries {
                    store
                        .save(NewSavedQuery {
                            name: name.to_owned(),
                            query: sql.to_owned(),
                            connection_id,
                            connection_name: connection_name.to_owned(),
                        })
                        .await
                        .expect("save");
                }
                store
            });
        Self {
            runtime: test_runtime(),
            hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
            store,
            root,
        }
    }

    fn dialog(&self, active_connection: Option<Uuid>) -> SavedQueriesDialog {
        SavedQueriesDialog::new(SavedQueriesDialogInit {
            store: Some(self.store.clone()),
            active_connection,
            tasks: self.runtime.tasks(),
            hold: self.hold.clone(),
        })
    }
}

fn init() {
    crate::register_test_resources();
    adw::init().expect("libadwaita initialises under the test backend");
}

// One query on each of two connections, `local` and `staging`.
fn seeded() -> (Harness, Uuid, Uuid) {
    let (local, staging) = (Uuid::new_v4(), Uuid::new_v4());
    let harness = Harness::with(&[
        ("daily orders", "SELECT * FROM orders", local, "local"),
        ("stale carts", "SELECT * FROM carts", staging, "staging"),
    ]);
    (harness, local, staging)
}

// A window large enough that the list view lays out its rows.
fn window() -> OwnedWindow<adw::Window> {
    let window = adw::Window::new();
    window.set_default_size(640, 640);
    OwnedWindow::presented(window)
}

// What the list view shows, in its order.
fn objects(dialog: &SavedQueriesDialog) -> Vec<SavedQueryObject> {
    let Some(model) = dialog.imp().list_view.model() else {
        return Vec::new();
    };
    (0..model.n_items())
        .filter_map(|position| model.item(position).and_downcast::<SavedQueryObject>())
        .collect()
}

fn row_titles(dialog: &SavedQueriesDialog) -> Vec<String> {
    objects(dialog)
        .iter()
        .filter_map(|object| object.name().map(str::to_owned))
        .collect()
}

// Everything the last read listed, whatever the search shows.
fn stored(dialog: &SavedQueriesDialog) -> Vec<SavedQueryObject> {
    dialog
        .imp()
        .parts
        .get()
        .map(|parts| parts.items.iter::<SavedQueryObject>().filter_map(Result::ok).collect())
        .unwrap_or_default()
}

fn named(dialog: &SavedQueriesDialog, name: &str) -> SavedQueryObject {
    stored(dialog)
        .into_iter()
        .find(|object| object.name() == Some(name))
        .expect("the saved query")
}

fn visible_page(dialog: &SavedQueriesDialog) -> Option<String> {
    dialog.imp().stack.visible_child_name().map(|name| name.to_string())
}

fn chosen(dialog: &SavedQueriesDialog) -> Rc<RefCell<Vec<(QueryDestination, String)>>> {
    let chosen: Rc<RefCell<Vec<(QueryDestination, String)>>> = Rc::default();
    let sink = chosen.clone();
    dialog.connect_query_chosen(move |_, destination, query| sink.borrow_mut().push((destination, query)));
    chosen
}

fn row_named(dialog: &SavedQueriesDialog, name: &str) -> Option<SavedQueryRow> {
    descendants(&dialog.imp().list_view.get())
        .into_iter()
        .filter_map(|widget| widget.downcast::<SavedQueryRow>().ok())
        .find(|row| row.id().is_some() && row.labels().0.label() == name)
}

#[gtk4::test]
fn the_saved_queries_reach_the_list() {
    let (harness, local, staging) = seeded();
    let dialog = harness.dialog(Some(local));

    wait_until(WAIT, || !row_titles(&dialog).is_empty()).expect("the saved queries never listed");

    // The active connection's query comes first, whatever order the
    // store returned them in.
    assert_eq!(row_titles(&dialog), ["daily orders", "stale carts"]);
    assert_eq!(visible_page(&dialog).as_deref(), Some("list"));
    let on_staging = harness.dialog(Some(staging));
    wait_until(WAIT, || !row_titles(&on_staging).is_empty()).expect("the saved queries never listed");
    assert_eq!(row_titles(&on_staging), ["stale carts", "daily orders"]);
}

#[gtk4::test]
fn searching_narrows_the_list_to_what_matches() {
    let (harness, local, _staging) = seeded();
    let dialog = harness.dialog(Some(local));
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("the saved queries never listed");
    let imp = dialog.imp();

    imp.search_entry.set_text("carts");
    wait_until(WAIT, || row_titles(&dialog) == ["stale carts"]).expect("the search did not narrow the list");

    imp.search_entry.set_text("invoices");
    wait_until(WAIT, || visible_page(&dialog).as_deref() == Some("empty")).expect("the empty search page");
    assert_eq!(imp.status_page.title(), "No Matches");
    assert_eq!(
        imp.status_page.description().as_deref(),
        Some("Try a different search term.")
    );
}

#[gtk4::test]
fn a_search_filters_the_items_it_has_rather_than_building_new_ones() {
    let (harness, local, _staging) = seeded();
    let dialog = harness.dialog(Some(local));
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("the saved queries never listed");
    let before = stored(&dialog);
    let carts = named(&dialog, "stale carts");
    let search = dialog.imp().search_entry.get();

    search.set_text("carts");
    wait_until(WAIT, || row_titles(&dialog) == ["stale carts"]).expect("the search did not narrow the list");
    assert_eq!(objects(&dialog), [carts], "the search built the item again");
    assert_eq!(stored(&dialog), before, "the search replaced the list");

    search.set_text("");
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("the cleared search");
    assert_eq!(objects(&dialog), before, "clearing the search built the items again");
}

#[gtk4::test]
fn an_answer_to_a_replaced_search_is_dropped() {
    let (harness, local, _staging) = seeded();
    let dialog = harness.dialog(Some(local));
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("the saved queries never listed");
    let carts = named(&dialog, "stale carts").id().expect("an id");
    let search = dialog.imp().search_entry.get();
    search.set_text("carts");
    wait_until(WAIT, || row_titles(&dialog) == ["stale carts"]).expect("the search for carts");
    let replaced = dialog.imp().search_generation.get();
    search.set_text("orders");
    wait_until(WAIT, || row_titles(&dialog) == ["daily orders"]).expect("the search for orders");

    dialog.search_finished(replaced, Ok(HashSet::from([carts])));

    assert_eq!(
        row_titles(&dialog),
        ["daily orders"],
        "a replaced search's answer was applied"
    );
}

#[gtk4::test]
fn two_connections_sharing_a_name_are_two_sections() {
    let (first, second) = (Uuid::new_v4(), Uuid::new_v4());
    let harness = Harness::with(&[("a", "SELECT 1", first, "local"), ("b", "SELECT 2", second, "local")]);
    let dialog = harness.dialog(None);
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("the saved queries never listed");

    let sorted = dialog.imp().parts.get().expect("parts").sorted.clone();

    assert_eq!(sorted.section(0), (0, 1));
    assert_eq!(sorted.section(1), (1, 2));
}

#[gtk4::test]
fn a_dialog_that_goes_before_its_list_lands_is_freed() {
    let (harness, local, _staging) = seeded();

    let dropped = harness.dialog(Some(local));
    let weak = dropped.downgrade();
    drop(dropped);
    // Nothing has run on the main loop yet, so its read has not landed.
    assert!(weak.upgrade().is_none(), "its read kept a dropped dialog alive");

    let window = window();
    let closed = harness.dialog(Some(local));
    closed.present(Some(&*window));
    let weak = closed.downgrade();
    closed.force_close();
    drop(closed);
    wait_until(WAIT, || weak.upgrade().is_none()).expect("the closed dialog to be freed");

    // One opened after them lists once their reads have had their turn.
    let open = harness.dialog(Some(local));
    wait_until(WAIT, || row_titles(&open).len() == 2).expect("a later dialog's list");
    drain_main_context();
}

#[gtk4::test]
fn activating_a_row_opens_its_query_in_a_new_tab() {
    let (harness, local, _staging) = seeded();
    let window = window();
    let dialog = harness.dialog(Some(local));
    dialog.present(Some(&*window));
    let chosen = chosen(&dialog);
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("the saved queries never listed");

    dialog.imp().list_view.emit_by_name::<()>("activate", &[&1u32]);

    assert_eq!(
        *chosen.borrow(),
        [(QueryDestination::NewTab, "SELECT * FROM carts".to_owned())]
    );
}

#[gtk4::test]
fn a_rows_menu_acts_on_the_query_that_row_shows() {
    let (harness, local, _staging) = seeded();
    let window = window();
    let dialog = harness.dialog(Some(local));
    dialog.present(Some(&*window));
    let chosen = chosen(&dialog);
    wait_until(WAIT, || row_named(&dialog, "stale carts").is_some()).expect("the rows");

    row_named(&dialog, "stale carts")
        .expect("the row")
        .activate_action("saved.replace", None)
        .expect("the action");

    assert_eq!(
        *chosen.borrow(),
        [(QueryDestination::CurrentTab, "SELECT * FROM carts".to_owned())]
    );
}

#[gtk4::test]
fn a_row_shows_its_name_and_summary_as_written() {
    init();
    let row = SavedQueryRow::default();
    let saved = SavedQuery {
        id: 7,
        name: "R&D <prod>".to_owned(),
        query: "\n  SELECT 1 & 2\nFROM t".to_owned(),
        connection_id: Uuid::nil(),
        connection_name: "local".to_owned(),
        created_at: SystemTime::UNIX_EPOCH,
        updated_at: SystemTime::UNIX_EPOCH,
    };

    row.bind(&SavedQueryObject::new(saved, 0));

    let (name, summary) = row.labels();
    assert_eq!(name.label(), "R&D <prod>");
    assert!(!name.uses_markup(), "the name was read as markup");
    assert_eq!(summary.label(), "SELECT 1 & 2");
    assert!(!summary.uses_markup(), "the summary was read as markup");
    assert_eq!(row.id(), Some(7));
}

// No scenario opens the dialog, so its one field is checked here.
#[gtk4::test]
fn the_search_field_is_named() {
    let (harness, local, _staging) = seeded();
    let dialog = harness.dialog(Some(local));

    assert_eq!(
        crate::test_support::assert_labelled(&dialog.imp().search_entry.get()),
        Ok(())
    );
}

#[gtk4::test]
fn deleting_a_query_takes_it_out_of_the_list() {
    let (harness, local, _staging) = seeded();
    let dialog = harness.dialog(Some(local));
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("the saved queries never listed");
    let id = named(&dialog, "daily orders").id().expect("an id");

    dialog.delete(id);
    assert_eq!(harness.hold.live(), 1, "deletion holds the process");

    wait_until(WAIT, || row_titles(&dialog) == ["stale carts"]).expect("the deleted query stayed in the list");
}

#[gtk4::test]
fn renaming_a_query_lists_it_under_its_new_name() {
    let (harness, local, _staging) = seeded();
    let dialog = harness.dialog(Some(local));
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("the saved queries never listed");
    let id = named(&dialog, "daily orders").id().expect("an id");

    dialog.rename(id, "weekly orders".to_owned());
    assert_eq!(harness.hold.live(), 1, "rename holds the process");

    wait_until(WAIT, || row_titles(&dialog) == ["weekly orders", "stale carts"]).expect("the new name");
}

// Take away the table the store reads, as a damaged file does, through a
// connection of its own.
fn drop_the_table(root: &tempfile::TempDir) {
    use tablepro_core::statement::{GuardedStatement, StatementBuilder};
    use tablepro_core::{
        CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, DatabaseDriver, FileEndpoint, ForeignKeyMode,
        TableRef, WorkspaceSettings, WriteBatch, WriteKind,
    };
    use tokio_util::sync::CancellationToken;

    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
    let endpoint = FileEndpoint::open_existing(paths.history_database()).expect("the history file");
    let options = ConnectOptions {
        target: ConnectTarget::File(endpoint),
        workspace_settings: WorkspaceSettings::workspace(false),
        liveness: tablepro_core::LivenessPolicy::DESKTOP,
        environment: ConnectEnvironment::new("test"),
    };
    let mut drop = StatementBuilder::new();
    drop.push_sql("DROP TABLE saved_queries");
    let batch = WriteBatch::new(
        WriteKind::SchemaChanges,
        TableRef::unqualified("saved_queries"),
        vec![GuardedStatement::unguarded(drop.finish())],
        ForeignKeyMode::Enforced,
    );
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime")
        .block_on(async {
            let connection = tablepro_driver_sqlite::SqliteDriver
                .connect(options, CancellationToken::new())
                .await
                .expect("connect");
            connection
                .write_batch(&batch, CallOptions::new(None, CancellationToken::new()))
                .await
                .expect("the table dropped");
            connection.close().await.expect("close");
        });
}

#[gtk4::test]
fn a_list_that_cannot_be_read_says_so_and_offers_try_again() {
    let (harness, local, _staging) = seeded();
    drop_the_table(&harness.root);
    let dialog = harness.dialog(Some(local));

    wait_until(WAIT, || visible_page(&dialog).as_deref() == Some("error")).expect("the error page");
    let imp = dialog.imp();
    assert_eq!(imp.error_page.title(), "Could Not Read Saved Queries");
    assert_eq!(
        imp.error_page.description().as_deref(),
        Some("The query history file could not be read. It may be damaged.")
    );
    let retry = imp
        .error_page
        .child()
        .and_downcast::<gtk::Button>()
        .expect("a Try Again button");
    assert_eq!(retry.label().as_deref(), Some("Try Again"));

    imp.search_entry.set_text("orders");
    dialog.apply_matches(Some(HashSet::new()));
    assert_eq!(
        visible_page(&dialog).as_deref(),
        Some("error"),
        "a search took the list off its error page"
    );

    retry.emit_clicked();
    drain_main_context();
    assert_eq!(
        visible_page(&dialog).as_deref(),
        Some("error"),
        "Try Again found the table back"
    );
}

#[gtk4::test]
fn copying_a_query_says_so_inside_the_dialog() {
    let (harness, local, _staging) = seeded();
    let dialog = harness.dialog(Some(local));
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("the saved queries never listed");
    let id = named(&dialog, "daily orders").id().expect("an id");

    dialog.copy_query(id);
    drain_main_context();

    let toasts = dialog.imp().toast_overlay.get();
    assert!(
        descendants(&toasts)
            .iter()
            .filter_map(|widget| widget.downcast_ref::<gtk::Label>())
            .any(|label| label.label() == "Copied to clipboard"),
        "the toast went somewhere the dialog covers"
    );
}

#[gtk4::test]
fn a_dialog_with_no_database_shows_an_error() {
    init();
    let runtime = test_runtime();
    let dialog = SavedQueriesDialog::new(SavedQueriesDialogInit {
        store: None,
        active_connection: None,
        tasks: runtime.tasks(),
        hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
    });

    drain_main_context();

    assert_eq!(visible_page(&dialog).as_deref(), Some("error"));
    assert!(row_titles(&dialog).is_empty());
}

#[test]
fn a_rename_failure_says_what_went_wrong() {
    assert_eq!(
        rename_failure_text(&StorageError::NameTaken),
        "That name is already used by another saved query."
    );
    assert_eq!(
        rename_failure_text(&StorageError::NotFound),
        "That saved query was deleted elsewhere."
    );
    assert_eq!(
        rename_failure_text(&StorageError::NotInitialised),
        "The saved query could not be renamed."
    );
}

#[test]
fn every_row_menu_item_has_an_access_key_of_its_own() {
    assert_access_keys(&row_menu());
}

#[gtk4::test]
fn a_change_keeps_the_process_until_it_lands_after_the_dialog_is_gone() {
    let (harness, local, _) = seeded();
    let dialog = harness.dialog(Some(local));
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("queries listed");
    let id = named(&dialog, "daily orders").id().expect("id");
    let (finish, finished) = tokio::sync::oneshot::channel();
    dialog.change(StoreChange::Rename, move |store| async move {
        let _ = finished.await;
        store.rename(id, "weekly orders").await
    });
    assert_eq!(harness.hold.live(), 1);
    drop(dialog);
    drain_main_context();
    assert_eq!(harness.hold.live(), 1);
    finish.send(()).expect("release write");
    wait_until(WAIT, || harness.hold.live() == 0).expect("write finished");
    let store = harness.store.clone();
    let read = harness.runtime.tasks().spawn_task(async move { store.get(id).await });
    let query = crate::test_support::finish_on_main(WAIT, read)
        .expect("read finished")
        .expect("task")
        .expect("read")
        .expect("query");
    assert_eq!(query.name, "weekly orders");
}

#[gtk4::test]
fn external_changes_reach_the_dialog_and_keep_selection_by_id() {
    let (harness, local, _) = seeded();
    let dialog = harness.dialog(Some(local));
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("queries listed");
    let id = named(&dialog, "daily orders").id().expect("id");
    dialog.imp().parts.get().expect("parts").selection.set_selected(0);
    let store = harness.store.clone();
    let change = harness
        .runtime
        .tasks()
        .spawn_task(async move { store.rename(id, "weekly orders").await });
    crate::test_support::finish_on_main(WAIT, change)
        .expect("rename finished")
        .expect("task")
        .expect("rename");
    wait_until(WAIT, || row_titles(&dialog) == ["weekly orders", "stale carts"]).expect("external rename listed");
    let selected = dialog
        .imp()
        .parts
        .get()
        .expect("parts")
        .selection
        .selected_item()
        .and_downcast::<SavedQueryObject>()
        .and_then(|object| object.id());
    assert_eq!(selected, Some(id));
    let store = harness.store.clone();
    let change = harness
        .runtime
        .tasks()
        .spawn_task(async move { store.delete(id).await });
    crate::test_support::finish_on_main(WAIT, change)
        .expect("delete finished")
        .expect("task")
        .expect("delete");
    wait_until(WAIT, || row_titles(&dialog) == ["stale carts"]).expect("external deletion listed");
    assert!(
        dialog
            .imp()
            .parts
            .get()
            .expect("parts")
            .selection
            .selected_item()
            .is_none()
    );
}

#[gtk4::test]
fn a_replaced_read_cannot_replace_the_current_list() {
    let (harness, local, _) = seeded();
    let dialog = harness.dialog(Some(local));
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("queries listed");
    let old = dialog.imp().load_generation.get();
    dialog.load();
    dialog.list_arrived(old, Ok(Ok(Listing::new(Vec::new(), Some(local)))));
    assert_eq!(row_titles(&dialog).len(), 2);
}

#[gtk4::test]
fn an_initial_read_never_claims_the_list_is_empty() {
    let (harness, local, _) = seeded();
    let dialog = harness.dialog(Some(local));
    assert_eq!(visible_page(&dialog).as_deref(), Some("loading"));
    dialog.apply_matches(Some(HashSet::new()));
    assert_eq!(visible_page(&dialog).as_deref(), Some("loading"));
    wait_until(WAIT, || row_titles(&dialog).len() == 2).expect("queries listed");
    assert_eq!(visible_page(&dialog).as_deref(), Some("list"));
}
