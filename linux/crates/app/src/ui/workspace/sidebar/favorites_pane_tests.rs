use super::rows::{find_row, menu_of};
use super::*;
use std::time::SystemTime;
use uuid::Uuid;

fn saved(id: i64, name: &str) -> SavedQuery {
    SavedQuery {
        id,
        name: name.to_owned(),
        query: "SELECT 1".to_owned(),
        connection_id: Uuid::nil(),
        connection_name: "Database".to_owned(),
        keyword: None,
        folder_id: None,
        order: 0,
        created_at: SystemTime::UNIX_EPOCH,
        updated_at: SystemTime::UNIX_EPOCH,
    }
}

#[gtk4::test]
fn favorites_keep_selection_by_id_after_rename_and_reorder() {
    let pane = FavoritesPane::new(|_| {}, || {});
    show(&pane, vec![saved(1, "One"), saved(2, "Two")]);
    pane.selection.set_selected(1);
    show(&pane, vec![saved(2, "Renamed"), saved(1, "One")]);
    assert_eq!(pane.selection.selected(), 0);
    show(&pane, vec![saved(1, "One")]);
    assert_eq!(pane.selection.selected(), gtk::INVALID_LIST_POSITION);
}

#[gtk4::test]
fn favorites_distinguish_loading_empty_unavailable_and_failed_refresh() {
    let retried = Rc::new(std::cell::Cell::new(false));
    let retry = retried.clone();
    let pane = FavoritesPane::new(|_| {}, move || retry.set(true));
    pane.loading();
    assert_eq!(pane.stack.visible_child_name().as_deref(), Some("loading"));
    pane.failed();
    assert_eq!(pane.stack.visible_child_name().as_deref(), Some("error"));
    pane.retry.emit_clicked();
    assert!(retried.get());
    show(&pane, vec![]);
    assert_eq!(pane.stack.visible_child_name().as_deref(), Some(EMPTY));
    show(&pane, vec![saved(1, "One")]);
    pane.failed();
    assert!(pane.stale.is_revealed());
    assert_eq!(pane.names(), ["One"]);
    pane.unavailable();
    assert!(!pane.retry.is_visible());
    assert!(pane.names().is_empty());
    pane.no_connection();
    assert_eq!(pane.stack.visible_child_name().as_deref(), Some("disconnected"));
}

type Actions = Rc<std::cell::RefCell<Vec<FavoriteAction>>>;
const WAIT: std::time::Duration = std::time::Duration::from_secs(30);

fn shown() -> (FavoritesPane, crate::test_support::OwnedWindow<gtk::Window>, Actions) {
    adw::init().expect("libadwaita");
    let actions = Actions::default();
    let sink = actions.clone();
    let pane = FavoritesPane::new(move |action| sink.borrow_mut().push(action), || {});
    show(&pane, vec![saved(1, "One"), saved(2, "Two")]);
    let window = gtk::Window::builder()
        .default_width(360)
        .default_height(360)
        .child(&pane.widget())
        .build();
    let window = crate::test_support::OwnedWindow::presented(window);
    crate::test_support::wait_until(WAIT, || {
        find_row(&list(&pane), Key::Query(2)).is_some_and(|row| row.height() > 0)
    })
    .expect("rows laid out");
    (pane, window, actions)
}

fn list(pane: &FavoritesPane) -> gtk::ListView {
    pane.menu
        .parent()
        .and_downcast::<gtk::ListView>()
        .expect("menu belongs to list")
}

fn press(pane: &FavoritesPane, key: gtk::gdk::Key, modifiers: gtk::gdk::ModifierType) -> bool {
    let controllers = list(pane).observe_controllers();
    let keys = (0..controllers.n_items())
        .filter_map(|position| controllers.item(position).and_downcast::<gtk::EventControllerKey>())
        .find(|keys| keys.name().as_deref() == Some(KEYS))
        .expect("favorite key handler");
    keys.emit_by_name::<bool>("key-pressed", &[&key, &0u32, &modifiers])
}

fn target(menu: &impl IsA<gio::MenuModel>, position: i32) -> glib::Variant {
    menu.as_ref()
        .item_attribute_value(position, "target", None)
        .expect("menu target")
}

fn requested(actions: &Actions) -> Vec<(&'static str, i64, String)> {
    actions
        .borrow()
        .iter()
        .filter_map(|action| match action {
            FavoriteAction::Rename(saved) => Some(("rename", saved.id, saved.name.clone())),
            FavoriteAction::Delete(saved) => Some(("delete", saved.id, saved.name.clone())),
            _ => None,
        })
        .collect()
}

#[gtk4::test]
fn a_favorite_has_a_named_menu_button_that_acts_on_its_row() {
    let (pane, _window, actions) = shown();
    let row = find_row(&list(&pane), Key::Query(2)).expect("second row");
    let button = row
        .last_child()
        .and_downcast::<gtk::MenuButton>()
        .expect("row menu button");
    assert_eq!(crate::test_support::assert_labelled(&button), Ok(()));
    assert_eq!(button.tooltip_text().as_deref(), Some("Options for “Two”"));
    button.popup();
    assert!(button.popover().expect("row popover").is_visible());
    let menu = button.menu_model().expect("row menu");
    assert_eq!(menu.n_items(), 3);
    crate::test_support::assert_access_keys(&menu);
    let action = menu
        .item_attribute_value(0, "action", None)
        .and_then(|value| value.get::<String>())
        .expect("rename action");
    button
        .activate_action(&action, Some(&target(&menu, 0)))
        .expect("rename from menu");
    assert_eq!(requested(&actions), [("rename", 2, "Two".to_owned())]);
}

#[gtk4::test]
fn favorite_shortcuts_use_selection_and_ignore_modifiers() {
    use gtk::gdk::{Key, ModifierType};
    let (pane, _window, actions) = shown();
    pane.selection.set_selected(1);
    for modifier in [
        ModifierType::SHIFT_MASK,
        ModifierType::CONTROL_MASK,
        ModifierType::ALT_MASK,
        ModifierType::SUPER_MASK,
    ] {
        for key in [Key::F2, Key::Delete, Key::KP_Delete] {
            assert!(!press(&pane, key, modifier));
        }
    }
    assert!(actions.borrow().is_empty());
    assert!(press(&pane, Key::F2, ModifierType::empty()));
    assert!(press(&pane, Key::Delete, ModifierType::empty()));
    assert!(press(&pane, Key::KP_Delete, ModifierType::empty()));
    assert_eq!(
        requested(&actions),
        [
            ("rename", 2, "Two".to_owned()),
            ("delete", 2, "Two".to_owned()),
            ("delete", 2, "Two".to_owned()),
        ]
    );
    pane.selection.set_selected(gtk::INVALID_LIST_POSITION);
    assert!(!press(&pane, Key::F2, ModifierType::empty()));
}

#[gtk4::test]
fn the_keyboard_opens_the_selected_favorites_context_menu() {
    use gtk::gdk::{Key, ModifierType};
    let (pane, _window, actions) = shown();
    pane.selection.set_selected(1);
    for (key, modifiers) in [(Key::F10, ModifierType::SHIFT_MASK), (Key::Menu, ModifierType::empty())] {
        assert!(press(&pane, key, modifiers));
        assert!(pane.menu.is_visible());
        let model = pane.menu.menu_model().expect("context menu");
        let target = target(&model, 2);
        assert_eq!(target.get::<String>().as_deref(), Some("q2"));
        pane.menu.popdown();
    }
    assert!(actions.borrow().is_empty());
    assert!(!press(
        &pane,
        Key::F10,
        ModifierType::CONTROL_MASK | ModifierType::SHIFT_MASK
    ));
}

#[gtk4::test]
fn a_secondary_click_targets_the_clicked_favorite() {
    let (pane, _window, actions) = shown();
    let list = list(&pane);
    pane.selection.set_selected(0);
    let row = find_row(&list, Key::Query(2)).expect("second row");
    let bounds = row.compute_bounds(&list).expect("row bounds");
    let controllers = list.observe_controllers();
    let click = (0..controllers.n_items())
        .filter_map(|position| controllers.item(position).and_downcast::<gtk::GestureClick>())
        .find(|click| click.button() == gtk::gdk::BUTTON_SECONDARY)
        .expect("secondary click");
    click.emit_by_name::<()>(
        "pressed",
        &[&1i32, &f64::from(bounds.x() + 4.0), &f64::from(bounds.y() + 4.0)],
    );
    assert!(pane.menu.is_visible());
    let model = pane.menu.menu_model().expect("context menu");
    list.activate_action("favorite.delete", Some(&target(&model, 2)))
        .expect("delete");
    assert_eq!(requested(&actions), [("delete", 2, "Two".to_owned())]);
}

#[gtk4::test]
fn reordered_menu_targets_keep_their_id_and_removed_targets_do_nothing() {
    let (pane, _window, actions) = shown();
    let list = list(&pane);
    let previous = target(&menu_of(Key::Query(2)), 0);
    pane.selection.set_selected(1);
    show(&pane, vec![saved(2, "Renamed"), saved(1, "One")]);
    list.activate_action("favorite.rename", Some(&previous))
        .expect("old action routed");
    assert_eq!(requested(&actions), [("rename", 2, "Renamed".to_owned())]);
    assert!(press(&pane, gtk::gdk::Key::F2, gtk::gdk::ModifierType::empty()));
    assert_eq!(
        requested(&actions),
        [("rename", 2, "Renamed".to_owned()), ("rename", 2, "Renamed".to_owned()),]
    );
    let before_switch = target(&menu_of(Key::Query(2)), 2);
    pane.clear();
    list.activate_action("favorite.delete", Some(&before_switch))
        .expect("stale target routed");
    assert_eq!(actions.borrow().len(), 2);
    show(&pane, vec![saved(3, "Different connection")]);
    list.activate_action("favorite.delete", Some(&before_switch))
        .expect("stale target routed");
    assert_eq!(actions.borrow().len(), 2);
    let current = target(&menu_of(Key::Query(3)), 2);
    show(&pane, vec![]);
    list.activate_action("favorite.delete", Some(&current))
        .expect("removed target routed");
    assert_eq!(actions.borrow().len(), 2);
}

fn show(pane: &FavoritesPane, mut queries: Vec<SavedQuery>) {
    for (order, query) in queries.iter_mut().enumerate() {
        query.order = order as i64;
    }
    pane.show(SavedQueriesSnapshot {
        queries,
        folders: vec![],
    });
}

fn folder(id: i64, name: &str, parent_id: Option<i64>) -> SavedQueryFolder {
    SavedQueryFolder {
        id,
        name: name.to_owned(),
        parent_id,
        connection_id: Uuid::nil(),
        order: id,
        created_at: SystemTime::UNIX_EPOCH,
        updated_at: SystemTime::UNIX_EPOCH,
    }
}

fn nested_snapshot(name: &str) -> SavedQueriesSnapshot {
    let mut query = saved(1, name);
    query.folder_id = Some(3);
    SavedQueriesSnapshot {
        queries: vec![query],
        folders: vec![
            folder(1, "Parent", None),
            folder(2, "Child", Some(1)),
            folder(3, "Nested", Some(2)),
        ],
    }
}

fn tree_row(pane: &FavoritesPane, key: Key) -> gtk::TreeListRow {
    pane.tree
        .row(position_of(&pane.tree, key).expect("visible key"))
        .expect("row")
}

#[gtk4::test]
fn nested_expansion_and_selected_identity_survive_refresh_and_collapsed_ancestors() {
    let pane = FavoritesPane::new(|_| {}, || {});
    pane.show(nested_snapshot("Before"));
    assert_eq!(pane.tree.n_items(), 1);
    tree_row(&pane, Key::Folder(1)).set_expanded(true);
    tree_row(&pane, Key::Folder(2)).set_expanded(true);
    tree_row(&pane, Key::Folder(3)).set_expanded(true);
    pane.selection
        .set_selected(position_of(&pane.tree, Key::Query(1)).expect("query"));
    pane.show(nested_snapshot("After"));
    assert_eq!(pane.tree.n_items(), 4);
    assert_eq!(
        pane.tree.row(pane.selection.selected()).as_ref().and_then(key_of),
        Some(Key::Query(1))
    );
    assert_eq!(pane.names(), ["After"]);
    tree_row(&pane, Key::Folder(1)).set_expanded(false);
    pane.show(nested_snapshot("After again"));
    assert_eq!(pane.tree.n_items(), 1);
    tree_row(&pane, Key::Folder(1)).set_expanded(true);
    assert!(tree_row(&pane, Key::Folder(2)).is_expanded());
    assert!(tree_row(&pane, Key::Folder(3)).is_expanded());
    assert_eq!(pane.tree.n_items(), 4);
    pane.clear();
    pane.show(nested_snapshot("Different connection"));
    assert_eq!(pane.tree.n_items(), 1);
    assert_eq!(pane.selection.selected(), gtk::INVALID_LIST_POSITION);
}

#[gtk4::test]
fn new_folder_requires_a_successful_read_and_an_invalid_graph_keeps_the_last_good_rows() {
    let actions = Actions::default();
    let sink = actions.clone();
    let pane = FavoritesPane::new(move |action| sink.borrow_mut().push(action), || {});
    assert!(!pane.new_folder.is_sensitive());
    show(&pane, vec![]);
    assert!(pane.new_folder.is_sensitive());
    pane.new_folder.emit_clicked();
    assert!(matches!(actions.borrow().as_slice(), [FavoriteAction::NewFolder(None)]));
    pane.loading();
    assert!(!pane.new_folder.is_sensitive());
    pane.failed();
    assert!(!pane.new_folder.is_sensitive());
    pane.show(nested_snapshot("Kept"));
    assert!(pane.new_folder.is_sensitive());
    let mut invalid = nested_snapshot("Lost");
    invalid.folders.clear();
    pane.show(invalid);
    assert_eq!(pane.names(), ["Kept"]);
    assert!(pane.stale.is_revealed());
    assert!(!pane.new_folder.is_sensitive());
    pane.no_connection();
    assert!(!pane.new_folder.is_sensitive());
}

#[gtk4::test]
fn folder_and_query_menus_use_distinct_ids_and_hidden_targets_do_nothing() {
    let (pane, _window, actions) = shown();
    pane.show(nested_snapshot("Query"));
    pane.selection.set_selected(0);
    assert!(press(&pane, gtk::gdk::Key::F2, gtk::gdk::ModifierType::empty()));
    assert!(matches!(actions.borrow().last(), Some(FavoriteAction::RenameFolder(folder)) if folder.id == 1));
    let list = list(&pane);
    let menu = menu_of(Key::Folder(1));
    crate::test_support::assert_access_keys(&menu);
    list.activate_action("favorite.new-folder", Some(&target(&menu, 0)))
        .expect("new subfolder");
    assert!(matches!(actions.borrow().last(), Some(FavoriteAction::NewFolder(Some(folder))) if folder.id == 1));
    list.activate_action("favorite.delete", Some(&target(&menu, 2)))
        .expect("delete folder");
    assert!(matches!(actions.borrow().last(), Some(FavoriteAction::DeleteFolder(folder)) if folder.id == 1));
    let query_menu = menu_of(Key::Query(1));
    let before = actions.borrow().len();
    list.activate_action("favorite.move", Some(&target(&query_menu, 1)))
        .expect("hidden action routed");
    assert_eq!(actions.borrow().len(), before);
    for id in [1, 2, 3] {
        tree_row(&pane, Key::Folder(id)).set_expanded(true);
    }
    list.activate_action("favorite.move", Some(&target(&query_menu, 1)))
        .expect("move query");
    assert!(matches!(actions.borrow().last(), Some(FavoriteAction::MoveTo(query)) if query.id == 1));
    crate::test_support::wait_until(WAIT, || {
        find_row(&list, Key::Folder(1)).is_some_and(|row| row.height() > 0)
    })
    .expect("folder visible");
    let row = find_row(&list, Key::Folder(1)).expect("folder row");
    let expander = row
        .parent()
        .and_downcast::<gtk::TreeExpander>()
        .expect("native expander");
    assert_eq!(crate::test_support::assert_labelled(&expander), Ok(()));
    let button = row
        .last_child()
        .and_downcast::<gtk::MenuButton>()
        .expect("folder menu button");
    assert_eq!(crate::test_support::assert_labelled(&button), Ok(()));
}

#[gtk4::test]
fn reopening_an_expanded_subtree_keeps_a_selected_root_siblings_position() {
    let pane = FavoritesPane::new(|_| {}, || {});
    let mut snapshot = nested_snapshot("Filed query");
    snapshot.queries.push(saved(2, "Root query"));
    pane.show(snapshot);
    tree_row(&pane, Key::Folder(1)).set_expanded(true);
    tree_row(&pane, Key::Folder(2)).set_expanded(true);
    let selected = Key::Query(2);
    pane.selection
        .set_selected(position_of(&pane.tree, selected).expect("root query"));
    tree_row(&pane, Key::Folder(1)).set_expanded(false);
    assert_eq!(pane.selection.selected(), 1);
    tree_row(&pane, Key::Folder(1)).set_expanded(true);
    assert!(tree_row(&pane, Key::Folder(2)).is_expanded());
    assert_eq!(
        pane.selection.selected(),
        position_of(&pane.tree, selected).expect("selected query")
    );
    assert_eq!(pane.selection.selected(), 3);
    assert_eq!(
        pane.tree.row(pane.selection.selected()).as_ref().and_then(key_of),
        Some(selected)
    );
}
