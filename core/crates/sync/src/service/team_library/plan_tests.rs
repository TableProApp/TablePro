use serde_json::json;
use tablepro_keys::encoding::TeamId;
use tablepro_storage::{TeamLibraryCopy, TeamLibraryRef};

use super::*;
use crate::api::ids::{ChangeTag, KindName, RecordKey, ScopeName};

// Every id has hex letters, so a test of its case sees two spellings.
fn uuid(n: u128) -> Uuid {
    Uuid::from_u128(0xabcd_ef00_0000_4000_8000_0000_0000_0000 | n)
}

fn id(n: u128) -> String {
    uuid(n).hyphenated().to_string()
}

fn item(kind: TeamLibraryKind, id: &str, fields: Value) -> TeamLibraryItem {
    TeamLibraryItem {
        kind,
        id: id.to_owned(),
        fields,
    }
}

fn base(kind: TeamLibraryKind, id: &str, deleted: bool) -> (TeamLibraryKind, BaseRow) {
    let scope = ScopeName::Team(TeamId(uuid(99)));
    (
        kind,
        BaseRow {
            key: RecordKey::new(scope, KindName::of(kind_of(kind)), id),
            tag: ChangeTag::Service("t".to_owned()),
            version: Some(1),
            revision: Some(1),
            epoch: None,
            deleted: deleted.then_some(DeletedReason::User),
            fields: None,
            created_ms: None,
        },
    )
}

fn folder(n: u128, name: &str, parent: Option<u128>, sort_order: i64) -> TeamFolder {
    TeamFolder {
        id: uuid(n),
        name: name.to_owned(),
        parent: parent.map(uuid),
        sort_order,
    }
}

fn query(n: u128, name: &str, folder: Option<u128>) -> TeamQuery {
    TeamQuery {
        id: uuid(n),
        name: name.to_owned(),
        query: "select 1".to_owned(),
        keyword: Some(String::new()),
        folder: folder.map(uuid),
        connection: None,
        sort_order: 0,
    }
}

fn published(kind: TeamLibraryKind, id: &str) -> TeamLibraryRef {
    TeamLibraryRef {
        kind,
        id: id.to_owned(),
    }
}

fn local(published: Vec<TeamLibraryRef>, declined: Vec<TeamLibraryCopy>) -> TeamLibraryLocal {
    TeamLibraryLocal {
        team_id: "team".to_owned(),
        published,
        declined,
        ..TeamLibraryLocal::default()
    }
}

#[test]
fn ids_go_out_in_lowercase_and_a_folder_goes_before_the_folders_and_queries_in_it() {
    let local = local(Vec::new(), Vec::new());
    let view = TeamView::new(&[], &[], &local);

    let planned = saved_queries(
        &view,
        &[folder(2, "Child", Some(1), 0), folder(1, "Parent", None, 5)],
        &[query(3, "Revenue", Some(2))],
    );

    let ids: Vec<String> = planned.iter().map(|planned| planned.item().id).collect();
    assert_eq!(ids, [id(1), id(2), id(3)]);
    assert_eq!(
        planned[1],
        Planned::Put {
            kind: TeamLibraryKind::Folder,
            id: id(2),
            fields: json!({"name": "Child", "parent_client_id": id(1), "sort_order": 0}),
            own: true,
        }
    );
    assert_eq!(
        planned[2],
        Planned::Put {
            kind: TeamLibraryKind::Query,
            id: id(3),
            fields: json!({"name": "Revenue", "query": "select 1", "sort_order": 0, "folder_client_id": id(2)}),
            own: true,
        }
    );
}

#[test]
fn what_the_team_holds_as_it_would_be_sent_plans_nothing_whatever_the_case_of_its_ids() {
    let upper = id(2).to_uppercase();
    assert_ne!(upper, id(2));
    let items = [
        item(
            TeamLibraryKind::Folder,
            &upper,
            json!({"name": "F", "sort_order": 0, "parent_client_id": ""}),
        ),
        item(
            TeamLibraryKind::Query,
            &id(3),
            json!({"name": "Q", "query": "select 1", "sort_order": 0, "keyword": "", "folder_client_id": upper}),
        ),
    ];
    let local = local(Vec::new(), Vec::new());
    let view = TeamView::new(&items, &[], &local);

    let planned = saved_queries(&view, &[folder(2, "F", None, 0)], &[query(3, "Q", Some(2))]);

    assert_eq!(planned, []);
}

#[test]
fn an_update_keeps_the_team_s_spelling_of_the_id_and_the_members_this_build_does_not_know() {
    let upper = id(2).to_uppercase();
    assert_ne!(upper, id(2));
    let items = [item(
        TeamLibraryKind::Folder,
        &upper,
        json!({"name": "Old", "sort_order": 0, "colorFromANewerBuild": "red"}),
    )];
    let local = local(Vec::new(), Vec::new());
    let view = TeamView::new(&items, &[], &local);

    let planned = saved_queries(&view, &[folder(2, "New", None, 0)], &[]);

    assert_eq!(
        planned,
        [Planned::Put {
            kind: TeamLibraryKind::Folder,
            id: upper,
            fields: json!({"name": "New", "sort_order": 0, "colorFromANewerBuild": "red"}),
            own: true,
        }]
    );
}

#[test]
fn a_removed_folder_moves_what_others_keep_in_it_up_first_and_its_query_goes_before_it() {
    let items = [
        item(TeamLibraryKind::Folder, &id(1), json!({"name": "Top", "sort_order": 0})),
        item(
            TeamLibraryKind::Folder,
            &id(2),
            json!({"name": "Mine", "sort_order": 0, "parent_client_id": id(1)}),
        ),
        item(
            TeamLibraryKind::Query,
            &id(3),
            json!({"name": "Mine too", "query": "q", "sort_order": 0, "folder_client_id": id(2)}),
        ),
        item(
            TeamLibraryKind::Query,
            &id(4),
            json!({"name": "Theirs", "query": "q", "sort_order": 0, "folder_client_id": id(2), "keyword": "k"}),
        ),
    ];
    let local = local(
        vec![
            published(TeamLibraryKind::Folder, &id(2)),
            published(TeamLibraryKind::Query, &id(3)),
        ],
        Vec::new(),
    );
    let view = TeamView::new(&items, &[], &local);

    let planned = saved_queries(&view, &[], &[]);

    assert_eq!(
        planned,
        [
            Planned::Put {
                kind: TeamLibraryKind::Query,
                id: id(4),
                fields: json!({"name": "Theirs", "query": "q", "sort_order": 0, "folder_client_id": id(1), "keyword": "k"}),
                own: false,
            },
            Planned::Delete {
                kind: TeamLibraryKind::Query,
                id: id(3),
            },
            Planned::Delete {
                kind: TeamLibraryKind::Folder,
                id: id(2),
            },
        ]
    );
}

#[test]
fn an_item_published_here_that_someone_else_then_removed_plans_nothing_more() {
    let local = local(vec![published(TeamLibraryKind::Query, &id(3))], Vec::new());
    let bases = [base(TeamLibraryKind::Query, &id(3), true)];
    let view = TeamView::new(&[], &bases, &local);

    assert_eq!(saved_queries(&view, &[], &[]), []);
}

#[test]
fn an_item_the_team_deleted_asks_before_it_comes_back() {
    let local = local(Vec::new(), Vec::new());
    let bases = [base(TeamLibraryKind::Query, &id(3), true)];
    let view = TeamView::new(&[], &bases, &local);

    let planned = saved_queries(&view, &[], &[query(3, "Back", None)]);

    assert!(matches!(&planned[..], [Planned::Ask { id: asked, own: true, .. }] if *asked == id(3)));
}

#[test]
fn a_copy_keep_theirs_turned_down_is_left_alone_until_it_changes_here() {
    let declined = TeamLibraryCopy {
        kind: TeamLibraryKind::Query,
        id: id(3).to_uppercase(),
        fields: json!({"name": "Mine", "query": "select 1", "sort_order": 0, "colorFromANewerBuild": "red"}),
    };
    let items = [item(
        TeamLibraryKind::Query,
        &id(3),
        json!({"name": "Theirs", "query": "select 1", "sort_order": 0, "colorFromANewerBuild": "red"}),
    )];
    let local = local(Vec::new(), vec![declined]);
    let view = TeamView::new(&items, &[], &local);

    let same = saved_queries(&view, &[], &[query(3, "Mine", None)]);
    let changed = saved_queries(&view, &[], &[query(3, "Mine again", None)]);

    assert_eq!(same, []);
    assert_eq!(changed.len(), 1);
}

#[test]
fn a_connection_goes_up_without_a_secret_at_any_depth_and_once_held_plans_nothing() {
    let settings = json!({
        "name": "Prod",
        "host": "db",
        "password": "hunter2",
        "sshConfig": {"host": "bastion", "keyPassphrase": "x", "jumpHosts": [{"host": "j", "privateKey": "k"}]},
    });
    let connection = TeamConnection { id: uuid(7), settings };
    let empty = local(Vec::new(), Vec::new());
    let first = connections(&TeamView::new(&[], &[], &empty), std::slice::from_ref(&connection));
    let Planned::Put { fields, .. } = &first[0] else {
        panic!("a put");
    };
    let items = [item(TeamLibraryKind::Connection, &id(7), fields.clone())];
    let again = connections(&TeamView::new(&items, &[], &empty), &[connection]);

    assert_eq!(
        *fields,
        json!({"name": "Prod", "host": "db", "sshConfig": {"host": "bastion", "jumpHosts": [{"host": "j"}]}})
    );
    assert_eq!(again, []);
}

#[test]
fn removing_names_the_items_the_team_holds_once_each_in_its_spelling() {
    let upper = id(5).to_uppercase();
    assert_ne!(upper, id(5));
    let items = [item(TeamLibraryKind::Connection, &upper, json!({"name": "C"}))];
    let empty = local(Vec::new(), Vec::new());
    let view = TeamView::new(&items, &[], &empty);
    let named = |id: String| TeamItemRef {
        kind: TeamLibraryKind::Connection,
        id,
    };

    let planned = removals(&view, &[named(id(5)), named(upper.clone()), named(id(6))]);

    assert_eq!(
        planned,
        [Planned::Delete {
            kind: TeamLibraryKind::Connection,
            id: upper,
        }]
    );
}

#[test]
fn ids_two_records_share_without_case_take_no_edit_removal_or_move() {
    let upper = id(2).to_uppercase();
    let items = [
        item(TeamLibraryKind::Folder, &id(2), json!({"name": "One", "sort_order": 0})),
        item(TeamLibraryKind::Folder, &upper, json!({"name": "Two", "sort_order": 0})),
        item(
            TeamLibraryKind::Query,
            &id(4),
            json!({"name": "Theirs", "query": "q", "sort_order": 0, "folder_client_id": upper}),
        ),
    ];
    let local = local(vec![published(TeamLibraryKind::Folder, &id(2))], Vec::new());
    let view = TeamView::new(&items, &[], &local);

    let edited = saved_queries(&view, &[folder(2, "Renamed", None, 0)], &[query(3, "In it", Some(2))]);
    let dropped = saved_queries(&view, &[], &[]);
    let removed = removals(
        &view,
        &[TeamItemRef {
            kind: TeamLibraryKind::Folder,
            id: id(2),
        }],
    );

    assert_eq!(edited, []);
    assert_eq!(dropped, []);
    assert_eq!(removed, []);
}
