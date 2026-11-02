use std::path::Path;

use tablepro_core::{AiPolicy, AuthMode, ExternalAccess, SafeModeLevel, TlsConfig};
use tempfile::TempDir;
use uuid::Uuid;

use super::super::{ConnectionStore, ConnectionsDocument, RemoveOutcome, SavedConnection};
use crate::error::StorageError;
use crate::{
    ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionIcon, GroupIcon, StoragePaths, SymbolName,
};

struct Library {
    store: ConnectionStore,
    _root: TempDir,
}

impl Library {
    fn new() -> Self {
        let root = TempDir::new().expect("tempdir");
        let store = ConnectionStore::new(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"));
        Self { store, _root: root }
    }

    fn group(&self, name: &str, parent: Option<&ConnectionGroup>) -> ConnectionGroup {
        self.store
            .create_group_blocking(ConnectionGroup::new(group_name(name), parent.map(|parent| parent.id)))
            .expect("the group")
    }

    fn connection(&self, name: &str, group: Option<&ConnectionGroup>) -> Uuid {
        let connection = SavedConnection {
            group_id: group.map(|group| group.id),
            ..connection(name)
        };
        self.store.upsert_blocking(connection.clone()).expect("the connection");
        connection.id
    }

    /// The names of the connections in `group`, in their order.
    fn in_group(&self, group: Option<&ConnectionGroup>) -> Vec<String> {
        let list = self.store.list_blocking().expect("the list");
        list.connections_in(group.map(|group| group.id))
            .iter()
            .map(|connection| connection.name.clone())
            .collect()
    }

    /// The names of the groups under `parent`, in their order.
    fn under(&self, parent: Option<&ConnectionGroup>) -> Vec<String> {
        let list = self.store.list_blocking().expect("the list");
        list.group_tree()
            .children(parent.map(|parent| parent.id))
            .iter()
            .map(|group| group.name.as_str().to_owned())
            .collect()
    }

    fn favorites(&self) -> Vec<String> {
        let list = self.store.list_blocking().expect("the list");
        list.favorites
            .iter()
            .filter_map(|id| list.connections.iter().find(|connection| connection.id == *id))
            .map(|connection| connection.name.clone())
            .collect()
    }

    fn revision(&self) -> u64 {
        self.store.snapshot().revision
    }
}

fn group_name(name: &str) -> ConnectionGroupName {
    ConnectionGroupName::new(name).expect("a group name")
}

fn connection(name: &str) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: name.to_owned(),
        driver_id: "postgres".to_owned(),
        host: "db.internal".to_owned(),
        port: 5432,
        database: "app".to_owned(),
        username: "postgres".to_owned(),
        tls: TlsConfig::verify_full(),
        safe_mode: SafeModeLevel::Off,
        external_access: ExternalAccess::ReadOnly,
        ai_policy: AiPolicy::Ask,
        query_timeout_secs: None,
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    }
}

#[test]
fn groups_are_created_at_the_end_of_their_parent_and_nest() {
    let library = Library::new();
    let work = library.group("Work", None);
    let home = library.group("Home", None);
    let staging = library.group("Staging", Some(&work));
    let production = library.group("Production", Some(&work));

    assert_eq!(library.under(None), ["Work", "Home"]);
    assert_eq!(library.under(Some(&work)), ["Staging", "Production"]);
    assert_eq!((work.order, home.order, staging.order, production.order), (0, 1, 0, 1));
    let list = library.store.list_blocking().expect("the list");
    assert_eq!(
        list.group_tree().label(production.id).as_deref(),
        Some("Work / Production")
    );
}

#[test]
fn a_group_is_refused_a_taken_id_a_missing_parent_a_fourth_level_and_a_siblings_name() {
    let library = Library::new();
    let work = library.group("Work", None);
    let staging = library.group("Staging", Some(&work));
    let eu = library.group("EU", Some(&staging));
    let revision = library.revision();

    let again = library.store.create_group_blocking(work.clone());
    let orphan = library
        .store
        .create_group_blocking(ConnectionGroup::new(group_name("Orphan"), Some(Uuid::new_v4())));
    let deep = library
        .store
        .create_group_blocking(ConnectionGroup::new(group_name("Paris"), Some(eu.id)));
    let twin = library
        .store
        .create_group_blocking(ConnectionGroup::new(group_name(" WORK "), None));

    assert!(matches!(again, Err(StorageError::GroupExists { id }) if id == work.id));
    assert!(matches!(orphan, Err(StorageError::GroupNotFound { .. })));
    assert!(matches!(
        deep,
        Err(StorageError::GroupTooDeep {
            max: ConnectionGroup::MAX_DEPTH
        })
    ));
    assert!(matches!(twin, Err(StorageError::GroupNameTaken { name }) if name == "WORK"));
    assert_eq!(library.revision(), revision, "a refused group was written");
    library.group("Work", Some(&staging));
}

#[test]
fn a_group_is_renamed_recoloured_and_given_an_icon() {
    let library = Library::new();
    let work = library.group("Work", None);
    library.group("Home", None);
    let symbol = GroupIcon::Symbol(SymbolName::new("briefcase.fill").expect("a symbol"));

    library
        .store
        .rename_group_blocking(work.id, group_name("work"))
        .expect("its own name in another case");
    let taken = library.store.rename_group_blocking(work.id, group_name("HOME"));
    library
        .store
        .set_group_color_blocking(work.id, Some(ConnectionColor::Red))
        .expect("the colour");
    library
        .store
        .set_group_icon_blocking(work.id, Some(symbol.clone()))
        .expect("the icon");
    let missing = library.store.rename_group_blocking(Uuid::new_v4(), group_name("Gone"));

    assert!(matches!(taken, Err(StorageError::GroupNameTaken { .. })));
    assert!(matches!(missing, Err(StorageError::GroupNotFound { .. })));
    let list = library.store.list_blocking().expect("the list");
    let stored = list.group_tree().get(work.id).cloned().expect("the group");
    assert_eq!(stored.name.as_str(), "work");
    assert_eq!(stored.color, Some(ConnectionColor::Red));
    assert_eq!(stored.icon, Some(symbol));

    library
        .store
        .set_group_color_blocking(work.id, None)
        .expect("no colour");
    library
        .store
        .set_group_icon_blocking(work.id, Some(GroupIcon::Named(ConnectionIcon::Folder)))
        .expect("a named icon");
    let list = library.store.list_blocking().expect("the list");
    let stored = list.group_tree().get(work.id).cloned().expect("the group");
    assert_eq!(stored.color, None);
    assert_eq!(stored.icon, Some(GroupIcon::Named(ConnectionIcon::Folder)));
}

#[test]
fn groups_move_under_another_parent_and_reorder_among_siblings() {
    let library = Library::new();
    let (work, home, archive) = (
        library.group("Work", None),
        library.group("Home", None),
        library.group("Archive", None),
    );
    let staging = library.group("Staging", Some(&work));

    library
        .store
        .move_groups_blocking(&[archive.id], None, Some(work.id))
        .expect("the reorder");
    assert_eq!(library.under(None), ["Archive", "Work", "Home"]);

    library
        .store
        .move_groups_blocking(&[home.id, archive.id], Some(work.id), Some(staging.id))
        .expect("the move");
    assert_eq!(library.under(None), ["Work"]);
    assert_eq!(library.under(Some(&work)), ["Home", "Archive", "Staging"]);

    library
        .store
        .move_groups_blocking(&[staging.id], None, None)
        .expect("back to the top");
    assert_eq!(library.under(None), ["Work", "Staging"]);
    let list = library.store.list_blocking().expect("the list");
    let orders: Vec<u32> = list
        .group_tree()
        .children(Some(work.id))
        .iter()
        .map(|group| group.order)
        .collect();
    assert_eq!(orders, [0, 1], "the group that left left a gap");
}

#[test]
fn a_group_never_moves_inside_itself() {
    let library = Library::new();
    let work = library.group("Work", None);
    let staging = library.group("Staging", Some(&work));
    let eu = library.group("EU", Some(&staging));

    for target in [work.id, staging.id, eu.id] {
        let refused = library.store.move_groups_blocking(&[work.id], Some(target), None);

        assert!(
            matches!(refused, Err(StorageError::GroupCycle { id }) if id == work.id),
            "{refused:?}"
        );
    }
    assert_eq!(library.under(None), ["Work"]);
}

#[test]
fn a_move_is_refused_past_the_depth_limit_onto_a_taken_name_or_under_a_missing_parent() {
    let library = Library::new();
    let work = library.group("Work", None);
    let staging = library.group("Staging", Some(&work));
    library.group("EU", Some(&staging));
    let home = library.group("Home", None);
    let lab = library.group("Lab", Some(&home));
    library.group("staging", Some(&home));
    let revision = library.revision();

    let deep = library.store.move_groups_blocking(&[work.id], Some(home.id), None);
    let deeper = library.store.move_groups_blocking(&[staging.id], Some(lab.id), None);
    let clash = library.store.move_groups_blocking(&[staging.id], Some(home.id), None);
    let orphan = library
        .store
        .move_groups_blocking(&[staging.id], Some(Uuid::new_v4()), None);
    let nothing = library.store.move_groups_blocking(&[Uuid::new_v4()], None, None);

    assert!(matches!(deep, Err(StorageError::GroupTooDeep { .. })), "{deep:?}");
    assert!(matches!(deeper, Err(StorageError::GroupTooDeep { .. })), "{deeper:?}");
    assert!(matches!(clash, Err(StorageError::GroupNameTaken { .. })), "{clash:?}");
    assert!(matches!(orphan, Err(StorageError::GroupNotFound { .. })), "{orphan:?}");
    assert!(
        matches!(nothing, Err(StorageError::GroupNotFound { .. })),
        "{nothing:?}"
    );
    assert_eq!(library.revision(), revision, "a refused move was written");
}

#[test]
fn two_moving_groups_of_one_name_are_refused_together() {
    let library = Library::new();
    let (work, home) = (library.group("Work", None), library.group("Home", None));
    let first = library.group("Shared", Some(&work));
    let second = library.group("shared", Some(&home));

    let refused = library.store.move_groups_blocking(&[first.id, second.id], None, None);

    assert!(
        matches!(refused, Err(StorageError::GroupNameTaken { .. })),
        "{refused:?}"
    );
}

#[test]
fn deleting_a_group_deletes_its_subtree_and_moves_its_connections_to_the_top() {
    let library = Library::new();
    let work = library.group("Work", None);
    let staging = library.group("Staging", Some(&work));
    let eu = library.group("EU", Some(&staging));
    let home = library.group("Home", None);
    library.connection("loose", None);
    library.connection("in eu", Some(&eu));
    library.connection("in work b", Some(&work));
    library.connection("in work a", Some(&work));
    library.connection("in staging", Some(&staging));
    library.connection("at home", Some(&home));
    let favorite = library.connection("favourite in work", Some(&work));
    library
        .store
        .add_favorites_blocking(&[favorite], None)
        .expect("the favourite");

    let outcome = library.store.delete_group_blocking(work.id).expect("the delete");

    assert_eq!(outcome, RemoveOutcome::Removed);
    assert_eq!(library.under(None), ["Home"]);
    assert_eq!(
        library.in_group(None),
        [
            "loose",
            "in work b",
            "in work a",
            "favourite in work",
            "in staging",
            "in eu"
        ]
    );
    assert_eq!(library.in_group(Some(&home)), ["at home"]);
    assert_eq!(library.favorites(), ["favourite in work"]);
    let list = library.store.list_blocking().expect("the list");
    assert_eq!(list.groups.len(), 1);
    let revision = library.revision();
    assert_eq!(
        library.store.delete_group_blocking(work.id).expect("again"),
        RemoveOutcome::NotPresent
    );
    assert_eq!(library.revision(), revision);
}

#[test]
fn connections_move_between_groups_and_reorder() {
    let library = Library::new();
    let (work, home) = (library.group("Work", None), library.group("Home", None));
    let a = library.connection("a", Some(&work));
    let b = library.connection("b", Some(&work));
    let c = library.connection("c", Some(&work));
    let d = library.connection("d", Some(&home));

    library
        .store
        .move_connections_blocking(&[c], Some(work.id), Some(a))
        .expect("the reorder");
    assert_eq!(library.in_group(Some(&work)), ["c", "a", "b"]);

    library
        .store
        .move_connections_blocking(&[a, b, Uuid::new_v4()], Some(home.id), Some(d))
        .expect("the move");
    assert_eq!(library.in_group(Some(&work)), ["c"]);
    assert_eq!(library.in_group(Some(&home)), ["a", "b", "d"]);

    library
        .store
        .move_connections_blocking(&[d], None, None)
        .expect("to the top");
    assert_eq!(library.in_group(None), ["d"]);
    let list = library.store.list_blocking().expect("the list");
    let orders: Vec<u32> = list
        .connections_in(Some(home.id))
        .iter()
        .map(|saved| saved.order)
        .collect();
    assert_eq!(orders, [0, 1]);
}

#[test]
fn a_connection_move_is_refused_into_a_missing_group_or_for_no_saved_connection() {
    let library = Library::new();
    let a = library.connection("a", None);
    let revision = library.revision();

    let missing_group = library
        .store
        .move_connections_blocking(&[a], Some(Uuid::new_v4()), None);
    let gone = Uuid::new_v4();
    let missing_connection = library.store.move_connections_blocking(&[gone], None, None);

    assert!(matches!(missing_group, Err(StorageError::GroupNotFound { .. })));
    assert!(matches!(missing_connection, Err(StorageError::ConnectionNotFound { id }) if id == gone));
    library
        .store
        .move_connections_blocking(&[], None, None)
        .expect("nothing to move");
    library
        .store
        .move_connections_blocking(&[a], None, None)
        .expect("already there");
    assert_eq!(library.revision(), revision, "a move that changed nothing was written");
}

#[test]
fn a_named_group_is_found_in_any_case_or_made_last() {
    let library = Library::new();
    let work = library.group("Work", None);
    let a = library.connection("a", Some(&work));
    let b = library.connection("b", None);
    let c = library.connection("c", None);

    let found = library
        .store
        .move_connections_to_group_named_blocking(&[b, a], None, group_name("work"))
        .expect("the move");
    assert_eq!(found.id, work.id);
    assert_eq!(
        library.in_group(Some(&work)),
        ["a", "b"],
        "a moved within its own group"
    );

    let made = library
        .store
        .move_connections_to_group_named_blocking(&[c], Some(work.id), group_name("Staging"))
        .expect("the new group");
    assert_eq!(made.parent_id, Some(work.id));
    assert_eq!(library.under(Some(&work)), ["Staging"]);
    assert_eq!(library.in_group(Some(&made)), ["c"]);

    let revision = library.revision();
    library
        .store
        .move_connections_to_group_named_blocking(&[a], None, group_name("Work"))
        .expect("already there");
    assert_eq!(library.revision(), revision);
}

#[test]
fn a_named_group_prefers_the_exact_name_and_respects_the_depth_limit() {
    let library = Library::new();
    let lower = library.group("work", None);
    let a = library.connection("a", None);
    let exact = library
        .store
        .create_group_blocking(ConnectionGroup::new(group_name("Work"), None));
    assert!(
        matches!(exact, Err(StorageError::GroupNameTaken { .. })),
        "siblings differ in more than case"
    );

    let found = library
        .store
        .move_connections_to_group_named_blocking(&[a], None, group_name("WORK"))
        .expect("the move");
    assert_eq!(found.id, lower.id);

    let staging = library.group("Staging", Some(&lower));
    let eu = library.group("EU", Some(&staging));
    let deep = library
        .store
        .move_connections_to_group_named_blocking(&[a], Some(eu.id), group_name("Paris"));
    assert!(matches!(deep, Err(StorageError::GroupTooDeep { .. })), "{deep:?}");
}

#[test]
fn favourites_are_added_reordered_and_removed() {
    let library = Library::new();
    let a = library.connection("a", None);
    let b = library.connection("b", None);
    let c = library.connection("c", None);

    library
        .store
        .add_favorites_blocking(&[a, b], None)
        .expect("two favourites");
    library
        .store
        .add_favorites_blocking(&[c], Some(a))
        .expect("one before them");
    assert_eq!(library.favorites(), ["c", "a", "b"]);

    library.store.add_favorites_blocking(&[b], Some(c)).expect("a reorder");
    assert_eq!(library.favorites(), ["b", "c", "a"]);

    library
        .store
        .remove_favorites_blocking(&[c, Uuid::new_v4()])
        .expect("one off");
    assert_eq!(library.favorites(), ["b", "a"]);
    let list = library.store.list_blocking().expect("the list");
    assert!(list.is_favorite(a) && !list.is_favorite(c));

    let gone = Uuid::new_v4();
    assert!(matches!(
        library.store.add_favorites_blocking(&[gone], None),
        Err(StorageError::ConnectionNotFound { id }) if id == gone
    ));
    library.store.remove_blocking(a).expect("the delete");
    assert_eq!(library.favorites(), ["b"], "a deleted connection is still a favourite");
}

#[test]
fn recent_lists_opened_connections_newest_first_without_favourites() {
    let library = Library::new();
    let a = library.connection("a", None);
    let b = library.connection("b", None);
    let c = library.connection("c", None);
    library.connection("never", None);
    for id in [a, b, c] {
        library.store.touch_last_opened_blocking(id).expect("the stamp");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    library.store.add_favorites_blocking(&[b], None).expect("a favourite");

    let list = library.store.list_blocking().expect("the list");
    let recent: Vec<&str> = list.recent(5).iter().map(|saved| saved.name.as_str()).collect();
    let one: Vec<&str> = list.recent(1).iter().map(|saved| saved.name.as_str()).collect();

    assert_eq!(recent, ["c", "a"]);
    assert_eq!(one, ["c"]);
}

#[test]
fn an_upsert_or_an_update_that_changes_group_goes_last_there() {
    let library = Library::new();
    let (work, home) = (library.group("Work", None), library.group("Home", None));
    let a = library.connection("a", Some(&work));
    library.connection("b", Some(&work));
    library.connection("c", Some(&home));
    library
        .store
        .move_connections_blocking(&[a], Some(work.id), None)
        .expect("a last");
    assert_eq!(library.in_group(Some(&work)), ["b", "a"]);

    let stored = library.store.load_blocking().expect("the list");
    let edited = SavedConnection {
        host: "elsewhere".to_owned(),
        order: 0,
        ..stored.iter().find(|saved| saved.id == a).cloned().expect("a")
    };
    library.store.upsert_blocking(edited).expect("an edit");
    assert_eq!(library.in_group(Some(&work)), ["b", "a"], "an edit moved the entry");

    library
        .store
        .update_blocking(a, |entry| entry.group_id = Some(home.id))
        .expect("the update");
    assert_eq!(library.in_group(Some(&home)), ["c", "a"]);
    assert_eq!(library.in_group(Some(&work)), ["b"]);

    let lost = SavedConnection {
        group_id: Some(Uuid::new_v4()),
        ..connection("lost")
    };
    library.store.upsert_blocking(lost).expect("a group the list lacks");
    assert_eq!(library.in_group(None), ["lost"]);
}

#[test]
fn a_crafted_tree_reads_without_cycles_strays_or_doubles() {
    let root = TempDir::new().expect("tempdir");
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");
    let mut first = ConnectionGroup::new(group_name("First"), None);
    let second = ConnectionGroup::new(group_name("Second"), Some(first.id));
    first.parent_id = Some(second.id);
    let stray = ConnectionGroup::new(group_name("Stray"), Some(Uuid::new_v4()));
    let selfish = ConnectionGroup {
        order: 7,
        ..ConnectionGroup::new(group_name("Selfish"), None)
    };
    let selfish = ConnectionGroup {
        parent_id: Some(selfish.id),
        ..selfish
    };
    let twin = ConnectionGroup {
        name: group_name("Twin"),
        ..stray.clone()
    };
    let mut a = connection("a");
    a.group_id = Some(Uuid::new_v4());
    a.order = 9;
    let mut b = connection("b");
    b.order = 9;
    let document = ConnectionsDocument {
        connections: vec![a.clone(), b.clone()],
        groups: vec![first.clone(), second.clone(), stray.clone(), selfish.clone(), twin],
        favorites: vec![b.id, Uuid::new_v4(), b.id],
        ..ConnectionsDocument::default()
    };
    let file = paths.connections_file();
    std::fs::create_dir_all(file.parent().expect("a parent")).expect("the directory");
    std::fs::write(&file, crate::document::encode_document(&document).expect("encode")).expect("the file");

    let list = ConnectionStore::new(&paths).list_blocking().expect("the list");

    let tops: Vec<(&str, u32)> = list
        .group_tree()
        .children(None)
        .iter()
        .map(|group| (group.name.as_str(), group.order))
        .collect();
    assert_eq!(tops, [("First", 0), ("Second", 1), ("Stray", 2), ("Selfish", 3)]);
    assert_eq!(list.groups.len(), 4, "a doubled id was kept");
    assert_eq!(list.connections[0].group_id, None);
    let orders: Vec<(&str, u32)> = list
        .connections_in(None)
        .iter()
        .map(|saved| (saved.name.as_str(), saved.order))
        .collect();
    assert_eq!(orders, [("a", 0), ("b", 1)]);
    assert_eq!(list.favorites.to_vec(), [b.id]);
}

#[test]
fn groups_and_favourites_survive_an_export_and_an_import_twice() {
    let source = Library::new();
    let work = source.group("Work", None);
    let staging = source.group("Staging", Some(&work));
    source
        .store
        .set_group_icon_blocking(
            staging.id,
            Some(GroupIcon::Symbol(SymbolName::new("server.rack").expect("a symbol"))),
        )
        .expect("the icon");
    source
        .store
        .set_group_color_blocking(work.id, Some(ConnectionColor::Blue))
        .expect("the colour");
    source.group("Empty", None);
    let b = source.connection("b", Some(&staging));
    let a = source.connection("a", Some(&staging));
    source.connection("loose", None);
    source.store.add_favorites_blocking(&[a, b], None).expect("favourites");
    let bytes = source.store.export_blocking().expect("the export");

    let target = Library::new();
    let first = target
        .store
        .import_blocking(Path::new("/tmp/c.json"), &bytes)
        .expect("the import");
    let second = target
        .store
        .import_blocking(Path::new("/tmp/c.json"), &bytes)
        .expect("again");

    assert_eq!((first.added, second.updated), (3, 3));
    let exported = source.store.list_blocking().expect("the source");
    let imported = target.store.list_blocking().expect("the target");
    assert_eq!(imported.groups.to_vec(), exported.groups.to_vec());
    assert_eq!(imported.favorites.to_vec(), exported.favorites.to_vec());
    assert_eq!(target.in_group(Some(&staging)), ["b", "a"]);
    assert_eq!(target.in_group(None), ["loose"]);
}

#[test]
fn an_import_matches_a_group_by_name_in_its_place_and_keeps_local_favourites() {
    let target = Library::new();
    let work = target.group("Work", None);
    let mine = target.connection("mine", None);
    target.store.add_favorites_blocking(&[mine], None).expect("a favourite");

    let source = Library::new();
    let theirs = source.group("Work", None);
    let nested = source.group("Staging", Some(&theirs));
    source.connection("theirs", Some(&nested));
    let bytes = source.store.export_blocking().expect("the export");

    target
        .store
        .import_blocking(Path::new("/tmp/c.json"), &bytes)
        .expect("the import");

    assert_eq!(target.under(None), ["Work"], "a second Work was added");
    assert_eq!(target.under(Some(&work)), ["Staging"]);
    let list = target.store.list_blocking().expect("the list");
    let staging = list.group_tree().children(Some(work.id))[0].id;
    assert_eq!(list.group_tree().label(staging).as_deref(), Some("Work / Staging"));
    assert_eq!(target.favorites(), ["mine"], "an import without favourites cleared one");
}

#[test]
fn an_imported_group_matched_by_id_keeps_its_place_and_a_name_a_sibling_holds() {
    let target = Library::new();
    let work = target.group("Work", None);
    let home = target.group("Home", None);
    target.group("Office", None);
    let theirs = ConnectionsDocument {
        groups: vec![
            ConnectionGroup {
                name: group_name("Office"),
                color: Some(ConnectionColor::Green),
                ..work.clone()
            },
            ConnectionGroup {
                name: group_name("House"),
                parent_id: Some(work.id),
                ..home.clone()
            },
        ],
        connections: vec![connection("c")],
        ..ConnectionsDocument::default()
    };
    let bytes = crate::document::encode_document(&theirs).expect("encode");

    target
        .store
        .import_blocking(Path::new("/tmp/c.json"), &bytes)
        .expect("the import");

    assert_eq!(target.under(None), ["Work", "House", "Office"]);
    let list = target.store.list_blocking().expect("the list");
    assert_eq!(
        list.group_tree().get(work.id).map(|group| group.color),
        Some(Some(ConnectionColor::Green))
    );
}

#[test]
fn an_import_that_moves_a_saved_connection_puts_it_last_in_the_new_group() {
    let target = Library::new();
    let work = target.group("Work", None);
    let a = target.connection("a", None);
    target.connection("b", Some(&work));
    let list = target.store.list_blocking().expect("the list");
    let moved = SavedConnection {
        group_id: Some(work.id),
        order: 0,
        ..list.connections.iter().find(|saved| saved.id == a).cloned().expect("a")
    };
    let document = ConnectionsDocument {
        connections: vec![moved],
        groups: list.groups.to_vec(),
        favorites: vec![a],
        ..ConnectionsDocument::default()
    };

    let report = target
        .store
        .import_blocking(
            Path::new("/tmp/c.json"),
            &crate::document::encode_document(&document).expect("encode"),
        )
        .expect("the import");

    assert_eq!(report.updated, 1);
    assert_eq!(target.in_group(Some(&work)), ["b", "a"]);
    assert_eq!(target.favorites(), ["a"]);
}
