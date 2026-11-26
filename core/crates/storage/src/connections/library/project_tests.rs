use std::path::Path;

use uuid::Uuid;

use super::super::{ConnectionList, ConnectionsDocument, ImportedConnection, RemoveOutcome, SavedConnection};
use super::tests::{Library, connection, encoded, group_name};
use crate::error::StorageError;
use crate::{ConnectionColor, ConnectionGroup, ConnectionIcon, ConnectionProject, ConnectionProjectName, GroupIcon};

fn project_name(name: &str) -> ConnectionProjectName {
    ConnectionProjectName::new(name).expect("a project name")
}

impl Library {
    fn project(&self, name: &str) -> ConnectionProject {
        self.store
            .create_project_blocking(ConnectionProject::new(project_name(name)))
            .expect("the project")
    }

    fn group_in(&self, name: &str, project: &ConnectionProject) -> ConnectionGroup {
        self.store
            .create_group_blocking(ConnectionGroup {
                project_id: Some(project.id),
                ..ConnectionGroup::new(group_name(name), None)
            })
            .expect("the group")
    }

    fn connection_in(&self, name: &str, project: &ConnectionProject) -> Uuid {
        let connection = SavedConnection {
            project_id: Some(project.id),
            ..connection(name)
        };
        self.store.upsert_blocking(connection.clone()).expect("the connection");
        connection.id
    }

    fn list(&self) -> ConnectionList {
        self.store.list_blocking().expect("the list")
    }

    fn saved(&self, id: Uuid) -> SavedConnection {
        self.list()
            .connections
            .iter()
            .find(|connection| connection.id == id)
            .cloned()
            .expect("the connection")
    }

    fn stored_group(&self, id: Uuid) -> ConnectionGroup {
        self.list()
            .groups
            .iter()
            .find(|group| group.id == id)
            .cloned()
            .expect("the group")
    }

    fn project_of(&self, connection: Uuid) -> Option<Uuid> {
        let list = self.list();
        list.effective_project(&self.saved(connection))
    }

    fn projects(&self) -> Vec<String> {
        self.list()
            .projects_in_order()
            .iter()
            .map(|project| project.name.as_str().to_owned())
            .collect()
    }
}

fn names(list: &ConnectionList) -> Vec<String> {
    let mut names: Vec<String> = list
        .connections
        .iter()
        .map(|connection| connection.name.clone())
        .collect();
    names.sort();
    names
}

fn group_names(list: &ConnectionList) -> Vec<String> {
    let mut names: Vec<String> = list.groups.iter().map(|group| group.name.as_str().to_owned()).collect();
    names.sort();
    names
}

// Acme: group Production (prod, with subgroup EU holding eu) and the ungrouped loose.
// Globex: the ungrouped other. No project: group Home (home) and the ungrouped stray.
struct Two {
    library: Library,
    acme: ConnectionProject,
    globex: ConnectionProject,
    production: ConnectionGroup,
    eu: ConnectionGroup,
    home: ConnectionGroup,
    prod: Uuid,
    in_eu: Uuid,
    loose: Uuid,
    other: Uuid,
    at_home: Uuid,
    stray: Uuid,
}

fn two_projects() -> Two {
    let library = Library::new();
    let acme = library.project("Acme");
    let globex = library.project("Globex");
    let production = library.group_in("Production", &acme);
    let eu = library.group("EU", Some(&production));
    let home = library.group("Home", None);
    let prod = library.connection("prod", Some(&production));
    let in_eu = library.connection("eu", Some(&eu));
    let loose = library.connection_in("loose", &acme);
    let other = library.connection_in("other", &globex);
    let at_home = library.connection("home", Some(&home));
    let stray = library.connection("stray", None);
    Two {
        library,
        acme,
        globex,
        production,
        eu,
        home,
        prod,
        in_eu,
        loose,
        other,
        at_home,
        stray,
    }
}

#[test]
fn all_connections_and_an_id_no_project_holds_show_the_whole_list() {
    let two = two_projects();
    let list = two.library.list();

    for scope in [None, Some(Uuid::new_v4())] {
        let scoped = list.scoped(scope);

        assert_eq!(names(&scoped), ["eu", "home", "loose", "other", "prod", "stray"]);
        assert_eq!(group_names(&scoped), ["EU", "Home", "Production"]);
        assert_eq!(list.resolved_scope(scope), None);
    }
    assert_eq!(list.resolved_scope(Some(two.acme.id)), Some(two.acme.id));
}

#[test]
fn a_project_shows_its_groups_with_their_subtrees_and_its_ungrouped_connections() {
    let two = two_projects();
    let tag = two
        .library
        .store
        .create_tag_blocking(
            crate::ConnectionTagName::new("billing").expect("a tag name"),
            ConnectionColor::Red,
        )
        .expect("the tag");
    let list = two.library.list();

    let acme = list.scoped(Some(two.acme.id));

    assert_eq!(names(&acme), ["eu", "loose", "prod"]);
    assert_eq!(group_names(&acme), ["EU", "Production"]);
    assert_eq!(acme.group_tree().label(two.eu.id).as_deref(), Some("Production / EU"));
    assert_eq!(acme.connections_in(None).len(), 1);
    assert_eq!(acme.connections_in(Some(two.production.id)).len(), 1);
    assert_eq!(acme.tags.iter().map(|held| held.id).collect::<Vec<_>>(), [tag.id]);
    assert_eq!(acme.projects.len(), 2);

    let globex = list.scoped(Some(two.globex.id));
    assert_eq!(names(&globex), ["other"]);
    assert!(globex.groups.is_empty());
}

#[test]
fn a_project_keeps_its_empty_groups_and_an_empty_project_shows_nothing() {
    let library = Library::new();
    let acme = library.project("Acme");
    let empty = library.project("Empty");
    library.group_in("Later", &acme);
    library.connection("stray", None);
    let list = library.list();

    assert_eq!(group_names(&list.scoped(Some(acme.id))), ["Later"]);
    assert!(list.scoped(Some(acme.id)).connections.is_empty());
    let nothing = list.scoped(Some(empty.id));
    assert!(nothing.connections.is_empty() && nothing.groups.is_empty() && nothing.favorites.is_empty());
    assert_eq!(nothing.projects.len(), 2);
}

#[test]
fn favourites_and_recent_are_the_projects_own() {
    let two = two_projects();
    let store = &two.library.store;
    store
        .add_favorites_blocking(&[two.other, two.loose, two.stray], None)
        .expect("the favourites");
    for id in [two.prod, two.in_eu, two.at_home, two.other] {
        store.touch_last_opened_blocking(id).expect("the stamp");
    }
    let list = two.library.list();

    let acme = list.scoped(Some(two.acme.id));

    assert_eq!(&*acme.favorites, [two.loose]);
    // The newest opens are outside the project, and a limit of one still finds the project's own.
    let recent: Vec<Uuid> = acme.recent(1).iter().map(|connection| connection.id).collect();
    assert_eq!(recent, [two.in_eu]);
    let whole: Vec<Uuid> = list.recent(1).iter().map(|connection| connection.id).collect();
    assert_eq!(whole, [two.at_home]);
}

#[test]
fn a_top_level_group_decides_for_its_subtree_and_a_stored_project_below_it_is_ignored() {
    let acme = ConnectionProject::new(project_name("Acme"));
    let globex = ConnectionProject::new(project_name("Globex"));
    let root = ConnectionGroup {
        project_id: Some(acme.id),
        ..ConnectionGroup::new(group_name("Production"), None)
    };
    let child = ConnectionGroup {
        project_id: Some(globex.id),
        ..ConnectionGroup::new(group_name("EU"), Some(root.id))
    };
    let grouped = SavedConnection {
        group_id: Some(child.id),
        project_id: Some(globex.id),
        ..connection("eu")
    };
    let library = Library::seeded(&ConnectionsDocument {
        connections: vec![grouped.clone()],
        groups: vec![root.clone(), child.clone()],
        projects: vec![acme.clone(), globex.clone()],
        ..ConnectionsDocument::default()
    });
    let list = library.list();

    assert_eq!(list.effective_group_project(root.id), Some(acme.id));
    assert_eq!(list.effective_group_project(child.id), Some(acme.id));
    assert_eq!(list.effective_project(&library.saved(grouped.id)), Some(acme.id));
    assert_eq!(names(&list.scoped(Some(acme.id))), ["eu"]);
    assert!(list.scoped(Some(globex.id)).connections.is_empty());
    // A read keeps what is stored: only a local change of the entry clears it.
    assert_eq!(library.stored_group(child.id).project_id, Some(globex.id));
}

#[test]
fn projects_are_created_last_and_refuse_a_name_or_an_id_already_held() {
    let library = Library::new();
    let acme = library.project("Acme");
    let cafe = library.project("Caf\u{e9}");

    assert_eq!((acme.order, cafe.order), (0, 1));
    assert_eq!(library.projects(), ["Acme", "Caf\u{e9}"]);
    for taken in [" ACME ", "ac\u{200b}me", "CAFE\u{301}"] {
        let refused = library
            .store
            .create_project_blocking(ConnectionProject::new(project_name(taken)));
        assert!(
            matches!(refused, Err(StorageError::ProjectNameTaken { .. })),
            "{taken:?}"
        );
    }
    let again = library.store.create_project_blocking(ConnectionProject {
        name: project_name("Other"),
        ..acme.clone()
    });
    assert!(matches!(again, Err(StorageError::ProjectExists { id }) if id == acme.id));
    assert_eq!(library.projects().len(), 2);
}

#[test]
fn a_project_is_renamed_recoloured_and_given_an_icon() {
    let library = Library::new();
    let acme = library.project("Acme");
    let globex = library.project("Globex");
    let store = &library.store;

    store
        .rename_project_blocking(acme.id, project_name("ACME"))
        .expect("its own name in another case");
    store
        .set_project_color_blocking(acme.id, Some(ConnectionColor::Red))
        .expect("the colour");
    store
        .set_project_icon_blocking(acme.id, Some(GroupIcon::Named(ConnectionIcon::Star)))
        .expect("the icon");

    let list = library.list();
    let stored = list.project(acme.id).expect("the project");
    assert_eq!(stored.name.as_str(), "ACME");
    assert_eq!(stored.color, Some(ConnectionColor::Red));
    assert_eq!(stored.icon, Some(GroupIcon::Named(ConnectionIcon::Star)));
    assert!(matches!(
        store.rename_project_blocking(globex.id, project_name("acme")),
        Err(StorageError::ProjectNameTaken { name }) if name == "acme"
    ));
    let missing = Uuid::new_v4();
    assert!(matches!(
        store.rename_project_blocking(missing, project_name("New")),
        Err(StorageError::ProjectNotFound { id }) if id == missing
    ));
    assert!(matches!(
        store.set_project_color_blocking(missing, None),
        Err(StorageError::ProjectNotFound { .. })
    ));
}

#[test]
fn projects_reorder_before_one_another_and_skip_ids_the_list_lacks() {
    let library = Library::new();
    let a = library.project("A");
    let b = library.project("B");
    let c = library.project("C");
    let store = &library.store;

    store
        .move_projects_blocking(&[c.id, Uuid::new_v4()], Some(a.id))
        .expect("a move");
    assert_eq!(library.projects(), ["C", "A", "B"]);
    store.move_projects_blocking(&[c.id], None).expect("to the end");
    assert_eq!(library.projects(), ["A", "B", "C"]);
    store.move_projects_blocking(&[b.id, a.id], None).expect("two at once");
    assert_eq!(library.projects(), ["C", "B", "A"]);
    let missing = Uuid::new_v4();
    assert!(matches!(
        store.move_projects_blocking(&[missing], None),
        Err(StorageError::ProjectNotFound { id }) if id == missing
    ));
}

#[test]
fn deleting_a_project_keeps_its_groups_and_connections_in_no_project() {
    let two = two_projects();
    let store = &two.library.store;

    assert_eq!(
        store.delete_project_blocking(two.acme.id).expect("the delete"),
        RemoveOutcome::Removed
    );

    let list = two.library.list();
    assert_eq!(list.connections.len(), 6);
    assert_eq!(group_names(&list), ["EU", "Home", "Production"]);
    assert_eq!(two.library.stored_group(two.production.id).project_id, None);
    assert_eq!(two.library.saved(two.loose).project_id, None);
    assert_eq!(two.library.project_of(two.prod), None);
    assert_eq!(two.library.project_of(two.other), Some(two.globex.id));
    assert_eq!(two.library.projects(), ["Globex"]);
    assert_eq!(list.project(two.globex.id).map(|project| project.order), Some(0));
    assert_eq!(
        store.delete_project_blocking(two.acme.id).expect("a second delete"),
        RemoveOutcome::NotPresent
    );
}

#[test]
fn ungrouped_connections_move_to_a_project_and_out_of_every_one() {
    let two = two_projects();
    let store = &two.library.store;

    store
        .move_connections_to_project_blocking(&[two.stray, two.loose, Uuid::new_v4()], Some(two.globex.id))
        .expect("the move");
    assert_eq!(two.library.project_of(two.stray), Some(two.globex.id));
    assert_eq!(two.library.project_of(two.loose), Some(two.globex.id));

    store
        .move_connections_to_project_blocking(&[two.loose], None)
        .expect("out of every project");
    assert_eq!(two.library.saved(two.loose).project_id, None);

    let missing = Uuid::new_v4();
    assert!(matches!(
        store.move_connections_to_project_blocking(&[two.stray], Some(missing)),
        Err(StorageError::ProjectNotFound { id }) if id == missing
    ));
    assert!(matches!(
        store.move_connections_to_project_blocking(&[missing], None),
        Err(StorageError::ConnectionNotFound { id }) if id == missing
    ));
}

#[test]
fn a_grouped_connection_is_refused_and_the_whole_move_with_it() {
    let two = two_projects();
    let before = two.library.revision();

    let refused = two
        .library
        .store
        .move_connections_to_project_blocking(&[two.stray, two.prod], Some(two.globex.id));

    assert!(matches!(refused, Err(StorageError::ConnectionGrouped { id }) if id == two.prod));
    assert_eq!(two.library.project_of(two.stray), None);
    assert_eq!(two.library.project_of(two.prod), Some(two.acme.id));
    assert_eq!(two.library.revision(), before);
}

#[test]
fn a_top_level_group_moves_to_a_project_with_its_subtree() {
    let two = two_projects();
    let store = &two.library.store;

    store
        .move_groups_to_project_blocking(&[two.production.id, Uuid::new_v4()], Some(two.globex.id))
        .expect("the move");

    assert_eq!(two.library.project_of(two.prod), Some(two.globex.id));
    assert_eq!(two.library.project_of(two.in_eu), Some(two.globex.id));
    assert_eq!(
        two.library.list().effective_group_project(two.eu.id),
        Some(two.globex.id)
    );
    assert_eq!(two.library.stored_group(two.eu.id).project_id, None);
    assert_eq!(two.library.project_of(two.loose), Some(two.acme.id));

    store
        .move_groups_to_project_blocking(&[two.production.id], None)
        .expect("out of every project");
    assert_eq!(two.library.project_of(two.prod), None);
}

#[test]
fn a_subgroup_an_unknown_group_and_a_name_the_project_holds_are_refused() {
    let two = two_projects();
    let store = &two.library.store;
    let twin = two.library.group_in("production", &two.globex);

    assert!(matches!(
        store.move_groups_to_project_blocking(&[two.eu.id], Some(two.globex.id)),
        Err(StorageError::GroupNotTopLevel { id }) if id == two.eu.id
    ));
    assert!(matches!(
        store.move_groups_to_project_blocking(&[two.production.id], Some(two.globex.id)),
        Err(StorageError::GroupNameTaken { name }) if name == "Production"
    ));
    let missing = Uuid::new_v4();
    assert!(matches!(
        store.move_groups_to_project_blocking(&[missing], None),
        Err(StorageError::GroupNotFound { id }) if id == missing
    ));
    assert!(matches!(
        store.move_groups_to_project_blocking(&[two.home.id], Some(missing)),
        Err(StorageError::ProjectNotFound { id }) if id == missing
    ));
    // A group already there is not its own rival.
    store
        .move_groups_to_project_blocking(&[twin.id], Some(two.globex.id))
        .expect("a move to where it is");
    assert_eq!(two.library.project_of(two.prod), Some(two.acme.id));
}

#[test]
fn a_connection_filed_in_a_group_drops_its_own_project() {
    let two = two_projects();

    two.library
        .store
        .move_connections_blocking(&[two.other], Some(two.production.id), None)
        .expect("the move");

    assert_eq!(two.library.saved(two.other).project_id, None);
    assert_eq!(two.library.project_of(two.other), Some(two.acme.id));
}

#[test]
fn a_connection_moved_out_to_the_top_stays_in_the_project_it_was_in() {
    let two = two_projects();
    let store = &two.library.store;

    store
        .move_connections_blocking(&[two.in_eu, two.at_home], None, None)
        .expect("the move");

    assert_eq!(two.library.saved(two.in_eu).project_id, Some(two.acme.id));
    assert_eq!(two.library.saved(two.at_home).project_id, None);
    assert_eq!(two.library.in_group(None), ["loose", "other", "stray", "eu", "home"]);
}

#[test]
fn a_saved_edit_that_leaves_a_group_stays_in_its_project_unless_it_names_another() {
    let two = two_projects();
    let store = &two.library.store;

    store
        .upsert_blocking(SavedConnection {
            group_id: None,
            ..two.library.saved(two.prod)
        })
        .expect("the save");
    assert_eq!(two.library.saved(two.prod).project_id, Some(two.acme.id));

    store
        .update_blocking(two.in_eu, |connection| {
            connection.group_id = None;
            connection.project_id = Some(two.globex.id);
        })
        .expect("the edit");
    assert_eq!(two.library.saved(two.in_eu).project_id, Some(two.globex.id));

    store
        .update_blocking(two.in_eu, |connection| connection.group_id = Some(two.home.id))
        .expect("the edit");
    assert_eq!(two.library.saved(two.in_eu).project_id, None);
    assert_eq!(two.library.project_of(two.in_eu), None);
}

#[test]
fn a_group_moved_under_another_drops_its_project_and_one_moved_up_keeps_its_roots() {
    let two = two_projects();
    let store = &two.library.store;

    store
        .move_groups_blocking(&[two.eu.id], None, None)
        .expect("up to the top");
    assert_eq!(two.library.stored_group(two.eu.id).project_id, Some(two.acme.id));
    assert_eq!(two.library.project_of(two.in_eu), Some(two.acme.id));

    store
        .move_groups_blocking(&[two.eu.id], Some(two.home.id), None)
        .expect("under a group of no project");
    assert_eq!(two.library.stored_group(two.eu.id).project_id, None);
    assert_eq!(two.library.project_of(two.in_eu), None);
}

#[test]
fn deleting_a_group_leaves_its_connections_in_the_groups_project() {
    let two = two_projects();

    two.library
        .store
        .delete_group_blocking(two.production.id)
        .expect("the delete");

    for id in [two.prod, two.in_eu] {
        assert_eq!(two.library.saved(id).group_id, None);
        assert_eq!(two.library.saved(id).project_id, Some(two.acme.id));
    }
    assert_eq!(
        names(&two.library.list().scoped(Some(two.acme.id))),
        ["eu", "loose", "prod"]
    );
}

#[test]
fn a_new_group_and_a_new_connection_are_made_in_a_project() {
    let library = Library::new();
    let acme = library.project("Acme");
    let work = library.group_in("Work", &acme);

    assert_eq!(work.project_id, Some(acme.id));
    let below = library
        .store
        .create_group_blocking(ConnectionGroup {
            project_id: Some(acme.id),
            ..ConnectionGroup::new(group_name("Staging"), Some(work.id))
        })
        .expect("a subgroup");
    assert_eq!(below.project_id, None);
    let loose = library.connection_in("loose", &acme);
    assert_eq!(library.saved(loose).project_id, Some(acme.id));
    let missing = Uuid::new_v4();
    let refused = library.store.create_group_blocking(ConnectionGroup {
        project_id: Some(missing),
        ..ConnectionGroup::new(group_name("Nowhere"), None)
    });
    assert!(matches!(refused, Err(StorageError::ProjectNotFound { id }) if id == missing));
}

#[test]
fn a_copy_saved_after_its_original_is_in_the_originals_project() {
    let two = two_projects();
    let copy = connection("loose copy");

    two.library
        .store
        .insert_after_blocking(copy.clone(), two.loose)
        .expect("the copy");

    assert_eq!(two.library.saved(copy.id).project_id, Some(two.acme.id));
}

#[test]
fn a_read_drops_a_project_no_project_holds_and_numbers_the_projects() {
    let acme = ConnectionProject {
        order: 7,
        ..ConnectionProject::new(project_name("Acme"))
    };
    let twice = ConnectionProject {
        name: project_name("Again"),
        order: 9,
        ..acme.clone()
    };
    let globex = ConnectionProject {
        order: 3,
        ..ConnectionProject::new(project_name("Globex"))
    };
    let gone = Uuid::new_v4();
    let group = ConnectionGroup {
        project_id: Some(gone),
        ..ConnectionGroup::new(group_name("Work"), None)
    };
    let kept = SavedConnection {
        project_id: Some(acme.id),
        ..connection("kept")
    };
    let dangling = SavedConnection {
        project_id: Some(gone),
        ..connection("dangling")
    };
    let library = Library::seeded(&ConnectionsDocument {
        connections: vec![kept.clone(), dangling.clone()],
        groups: vec![group.clone()],
        projects: vec![acme.clone(), twice, globex],
        ..ConnectionsDocument::default()
    });

    assert_eq!(library.projects(), ["Globex", "Acme"]);
    assert_eq!(library.stored_group(group.id).project_id, None);
    assert_eq!(library.saved(dangling.id).project_id, None);
    assert_eq!(library.saved(kept.id).project_id, Some(acme.id));
}

#[test]
fn two_projects_each_have_a_top_level_group_of_one_name() {
    let library = Library::new();
    let acme = library.project("Acme");
    let globex = library.project("Globex");
    let store = &library.store;
    let ours = library.group_in("Production", &acme);
    let theirs = library.group_in("Production", &globex);
    let none = library.group("Production", None);

    assert_eq!(library.under(None), ["Production", "Production", "Production"]);
    let twin = store.create_group_blocking(ConnectionGroup {
        project_id: Some(acme.id),
        ..ConnectionGroup::new(group_name("PRODUCTION"), None)
    });
    assert!(matches!(twin, Err(StorageError::GroupNameTaken { .. })));
    let staging = library.group_in("Staging", &acme);
    assert!(matches!(
        store.rename_group_blocking(staging.id, group_name("production")),
        Err(StorageError::GroupNameTaken { .. })
    ));
    library.group_in("Staging", &globex);
    assert_ne!(ours.id, theirs.id);
    assert_ne!(ours.id, none.id);
}

#[test]
fn a_connection_filed_under_a_named_group_finds_the_group_of_its_project() {
    let library = Library::new();
    let acme = library.project("Acme");
    let globex = library.project("Globex");
    let ours = library.group_in("Production", &acme);
    let a = library.connection_in("a", &globex);
    let b = library.connection("b", None);
    let store = &library.store;

    let made = store
        .move_connections_to_group_named_blocking(&[a], None, Some(globex.id), group_name("production"))
        .expect("a group of the project");
    assert_ne!(made.id, ours.id);
    assert_eq!(made.project_id, Some(globex.id));
    assert_eq!(library.project_of(a), Some(globex.id));

    let found = store
        .move_connections_to_group_named_blocking(&[b], None, Some(acme.id), group_name("production"))
        .expect("the group it has");
    assert_eq!(found.id, ours.id);
    let missing = Uuid::new_v4();
    assert!(matches!(
        store.move_connections_to_group_named_blocking(&[b], None, Some(missing), group_name("Other")),
        Err(StorageError::ProjectNotFound { .. })
    ));
}

#[test]
fn a_group_comes_up_to_the_top_unless_its_project_has_one_of_its_name_there() {
    let library = Library::new();
    let acme = library.project("Acme");
    let globex = library.project("Globex");
    let ours = library.group_in("Work", &acme);
    let theirs = library.group_in("Other", &globex);
    let clash = library.group("Work", Some(&ours));
    let free = library.group("Work", Some(&theirs));
    let store = &library.store;

    assert!(matches!(
        store.move_groups_blocking(&[clash.id], None, None),
        Err(StorageError::GroupNameTaken { .. })
    ));
    store
        .move_groups_blocking(&[free.id], None, None)
        .expect("the same name in another project");
    assert_eq!(library.stored_group(free.id).project_id, Some(globex.id));
}

#[test]
fn an_import_matches_a_project_by_id_then_by_name_and_adds_the_rest() {
    let library = Library::new();
    let acme = library.project("Acme");
    let globex = library.project("Globex");
    let file = {
        let renamed = ConnectionProject {
            name: project_name("Acme Corp"),
            color: Some(ConnectionColor::Blue),
            ..acme.clone()
        };
        let by_name = ConnectionProject::new(project_name("GLOBEX"));
        let new = ConnectionProject::new(project_name("Initech"));
        ConnectionsDocument {
            connections: vec![
                SavedConnection {
                    project_id: Some(by_name.id),
                    ..connection("theirs")
                },
                SavedConnection {
                    project_id: Some(new.id),
                    ..connection("new")
                },
            ],
            projects: vec![new, by_name, renamed],
            ..ConnectionsDocument::default()
        }
    };

    library.import(&file);
    library.import(&file);

    assert_eq!(library.projects(), ["Acme Corp", "Globex", "Initech"]);
    let list = library.list();
    assert_eq!(
        list.project(acme.id).and_then(|project| project.color),
        Some(ConnectionColor::Blue)
    );
    assert_eq!(names(&list.scoped(Some(globex.id))), ["theirs"]);
    let initech = list.projects_in_order()[2].id;
    assert_eq!(names(&list.scoped(Some(initech))), ["new"]);
}

#[test]
fn an_imported_project_does_not_take_a_name_another_project_holds() {
    let library = Library::new();
    let acme = library.project("Acme");
    library.project("Globex");
    let file = ConnectionsDocument {
        projects: vec![ConnectionProject {
            name: project_name("globex"),
            ..acme.clone()
        }],
        connections: vec![SavedConnection {
            project_id: Some(acme.id),
            ..connection("one")
        }],
        ..ConnectionsDocument::default()
    };

    library.import(&file);

    assert_eq!(library.projects(), ["Acme", "Globex"]);
}

#[test]
fn an_import_matches_a_top_level_group_by_name_only_inside_its_project() {
    let library = Library::new();
    let acme = library.project("Acme");
    let globex = library.project("Globex");
    let ours = library.group_in("Production", &acme);
    let file = {
        let their_project = ConnectionProject::new(project_name("Globex"));
        let group = ConnectionGroup {
            project_id: Some(their_project.id),
            ..ConnectionGroup::new(group_name("Production"), None)
        };
        ConnectionsDocument {
            connections: vec![SavedConnection {
                group_id: Some(group.id),
                ..connection("theirs")
            }],
            groups: vec![group],
            projects: vec![their_project],
            ..ConnectionsDocument::default()
        }
    };

    library.import(&file);
    library.import(&file);

    let list = library.list();
    assert_eq!(list.groups.len(), 2);
    assert_eq!(names(&list.scoped(Some(globex.id))), ["theirs"]);
    assert!(list.connections_in(Some(ours.id)).is_empty());
}

#[test]
fn an_import_started_in_a_project_lands_what_the_file_files_under_none_there() {
    let library = Library::new();
    let acme = library.project("Acme");
    let globex = library.project("Globex");
    let held = library.connection_in("held", &globex);
    let work = library.group("Work", None);
    let file = {
        let group = ConnectionGroup::new(group_name("Work"), None);
        ConnectionsDocument {
            connections: vec![
                connection("loose"),
                SavedConnection {
                    group_id: Some(group.id),
                    ..connection("filed")
                },
                SavedConnection {
                    name: "held again".to_owned(),
                    project_id: None,
                    ..library.saved(held)
                },
            ],
            groups: vec![group],
            ..ConnectionsDocument::default()
        }
    };

    let preview = library
        .store
        .preview_import_into_blocking(Path::new("/tmp/c.json"), &encoded(&file), Some(acme.id))
        .expect("the preview");
    assert_eq!(preview.entries()[0].connection.project_id, Some(acme.id));
    library.store.apply_import_blocking(&preview).expect("the import");

    let list = library.list();
    assert_eq!(names(&list.scoped(Some(acme.id))), ["filed", "loose"]);
    // The group of no project is another group than the project's new one.
    assert!(list.connections_in(Some(work.id)).is_empty());
    assert_eq!(list.groups.len(), 2);
    // An entry the import only updates stays in its own project.
    assert_eq!(library.saved(held).name, "held again");
    assert_eq!(library.saved(held).project_id, Some(globex.id));
}

#[test]
fn an_export_holds_the_projects_and_imports_back_with_every_member() {
    let two = two_projects();
    let bytes = two.library.store.export_blocking().expect("the export");
    let fresh = Library::new();

    fresh
        .store
        .import_blocking(Path::new("/tmp/c.json"), &bytes)
        .expect("the import");

    let list = fresh.list();
    assert_eq!(fresh.projects(), ["Acme", "Globex"]);
    assert_eq!(names(&list.scoped(Some(two.acme.id))), ["eu", "loose", "prod"]);
    assert_eq!(names(&list.scoped(Some(two.globex.id))), ["other"]);
    assert_eq!(group_names(&list.scoped(Some(two.acme.id))), ["EU", "Production"]);
}

#[test]
fn an_exported_empty_project_is_imported_with_its_groups_and_a_second_import_writes_nothing() {
    let library = Library::new();
    let acme = library.project("Acme");
    library.group_in("Work", &acme);
    let (bytes, count) = library.store.export_scoped_blocking(Some(acme.id)).expect("the export");
    assert_eq!(count, 0);
    let fresh = Library::new();

    let preview = fresh
        .store
        .preview_import_blocking(Path::new("/tmp/c.json"), &bytes)
        .expect("the preview");
    assert!(preview.entries().is_empty());
    assert!(preview.changes_library());
    let report = fresh.store.apply_import_blocking(&preview).expect("the import");

    assert_eq!(report.total(), 0);
    assert_eq!(fresh.projects(), ["Acme"]);
    let list = fresh.list();
    assert_eq!(
        group_names(&list.scoped(list.projects.first().map(|project| project.id))),
        ["Work"]
    );
    let again = fresh
        .store
        .preview_import_blocking(Path::new("/tmp/c.json"), &bytes)
        .expect("the preview");
    assert!(!again.changes_library());
}

#[test]
fn an_empty_file_changes_nothing_after_a_pull_filed_a_connection_in_a_group() {
    let library = Library::new();
    let acme = library.project("Acme");
    let work = library.group_in("Work", &acme);
    let filed = library.connection_in("filed", &acme);
    // A pull lays the list out as it arrived, so the connection keeps the project it stored before the move.
    library
        .store
        .lay_out_blocking(&[], |list| {
            let connections: Vec<SavedConnection> = list
                .connections
                .iter()
                .map(|connection| SavedConnection {
                    group_id: (connection.id == filed).then_some(work.id).or(connection.group_id),
                    ..connection.clone()
                })
                .collect();
            ConnectionList {
                connections: std::sync::Arc::from(connections),
                ..list.clone()
            }
        })
        .expect("the pull");
    assert_eq!(library.saved(filed).project_id, Some(acme.id));

    let preview = library
        .store
        .preview_import_blocking(Path::new("/tmp/c.json"), &encoded(&ConnectionsDocument::default()))
        .expect("the preview");

    assert!(!preview.changes_library());
}

#[test]
fn a_projects_export_holds_its_members_and_no_other_project() {
    let two = two_projects();
    let bytes = two
        .library
        .store
        .export_scoped_blocking(Some(two.acme.id))
        .expect("the export")
        .0;
    let fresh = Library::new();

    fresh
        .store
        .import_blocking(Path::new("/tmp/c.json"), &bytes)
        .expect("the import");

    let list = fresh.list();
    assert_eq!(fresh.projects(), ["Acme"]);
    assert_eq!(names(&list), ["eu", "loose", "prod"]);
    assert_eq!(group_names(&list), ["EU", "Production"]);
    let whole = two.library.store.export_blocking().expect("the export");
    let gone = Uuid::new_v4();
    let unknown = two.library.store.export_scoped_blocking(Some(gone));
    assert_eq!(
        two.library.store.export_scoped_blocking(None).expect("the export").0,
        whole
    );
    assert!(matches!(unknown, Err(StorageError::ProjectNotFound { id }) if id == gone));
}

#[test]
fn a_connection_from_another_app_lands_in_the_project_it_is_imported_into() {
    let library = Library::new();
    let acme = library.project("Acme");
    let elsewhere = library.group("Work", None);
    let before = library.list();

    let saved = library
        .store
        .add_imported_blocking(
            &before,
            vec![
                ImportedConnection {
                    connection: connection("loose"),
                    group_path: Vec::new(),
                    replaces: None,
                    project_id: Some(acme.id),
                },
                ImportedConnection {
                    connection: connection("filed"),
                    group_path: vec![group_name("Work"), group_name("Staging")],
                    replaces: None,
                    project_id: Some(acme.id),
                },
            ],
        )
        .expect("the import");

    assert_eq!(saved[0].project_id, Some(acme.id));
    assert_eq!(saved[1].project_id, None);
    let list = library.list();
    assert_eq!(names(&list.scoped(Some(acme.id))), ["filed", "loose"]);
    assert_eq!(group_names(&list.scoped(Some(acme.id))), ["Staging", "Work"]);
    assert!(list.connections_in(Some(elsewhere.id)).is_empty());
}

#[test]
fn a_connection_another_app_replaces_stays_in_its_project_with_the_groups_it_is_filed_in() {
    let library = Library::new();
    let acme = library.project("Acme");
    let globex = library.project("Globex");
    let loose = library.connection_in("loose", &globex);
    let team = library.group_in("Team", &globex);
    let filed = library.connection("filed", Some(&team));
    let replacing = |id: Uuid, path: &[&str]| ImportedConnection {
        connection: library.saved(id),
        group_path: path.iter().map(|name| group_name(name)).collect(),
        replaces: Some(id),
        project_id: Some(acme.id),
    };
    let before = library.list();

    let saved = library
        .store
        .add_imported_blocking(
            &before,
            vec![
                replacing(loose, &["Work"]),
                replacing(filed, &["Work", "Staging"]),
                ImportedConnection {
                    replaces: None,
                    ..replacing(loose, &["Work"])
                },
            ],
        )
        .expect("the import");

    assert_eq!((saved[0].id, saved[1].id), (loose, filed));
    assert_eq!(library.project_of(loose), Some(globex.id));
    assert_eq!(library.project_of(filed), Some(globex.id));
    assert_eq!(
        saved[0].group_id,
        saved[1].group_id.and_then(|id| library.stored_group(id).parent_id)
    );
    // The copy is new, so its `Work` is the import's project's own.
    assert_eq!(library.project_of(saved[2].id), Some(acme.id));
    assert_ne!(saved[2].group_id, saved[0].group_id);
    let list = library.list();
    assert_eq!(group_names(&list.scoped(Some(globex.id))), ["Staging", "Team", "Work"]);
    assert_eq!(group_names(&list.scoped(Some(acme.id))), ["Work"]);
}

#[test]
fn a_connection_a_file_updates_stays_in_its_project_with_the_groups_the_file_files_it_in() {
    let library = Library::new();
    let acme = library.project("Acme");
    let globex = library.project("Globex");
    let loose = library.connection_in("loose", &globex);
    let team = library.group_in("Team", &globex);
    let filed = library.connection("filed", Some(&team));
    let file = {
        let work = ConnectionGroup::new(group_name("Work"), None);
        let staging = ConnectionGroup::new(group_name("Staging"), Some(work.id));
        ConnectionsDocument {
            connections: vec![
                SavedConnection {
                    group_id: Some(work.id),
                    project_id: None,
                    ..library.saved(loose)
                },
                SavedConnection {
                    group_id: Some(staging.id),
                    ..library.saved(filed)
                },
                SavedConnection {
                    group_id: Some(staging.id),
                    ..connection("fresh")
                },
            ],
            groups: vec![work, staging],
            ..ConnectionsDocument::default()
        }
    };

    for _ in 0..2 {
        let preview = library
            .store
            .preview_import_into_blocking(Path::new("/tmp/c.json"), &encoded(&file), Some(acme.id))
            .expect("the preview");
        library.store.apply_import_blocking(&preview).expect("the import");
    }

    assert_eq!(library.project_of(loose), Some(globex.id));
    assert_eq!(library.project_of(filed), Some(globex.id));
    let list = library.list();
    assert_eq!(names(&list.scoped(Some(globex.id))), ["filed", "loose"]);
    assert_eq!(group_names(&list.scoped(Some(globex.id))), ["Staging", "Team", "Work"]);
    assert_eq!(names(&list.scoped(Some(acme.id))), ["fresh"]);
    assert_eq!(group_names(&list.scoped(Some(acme.id))), ["Staging", "Work"]);
    let work = library.saved(loose).group_id.expect("a group");
    let staging = library.saved(filed).group_id.expect("a group");
    assert_eq!(library.stored_group(staging).parent_id, Some(work));
}
