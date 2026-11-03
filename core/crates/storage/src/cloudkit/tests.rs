use std::collections::{BTreeMap, HashSet};

use proptest::prelude::*;
use tablepro_core::{AiPolicy, AuthMode, ExternalAccess, SafeModeLevel, TlsConfig};
use tempfile::TempDir;
use uuid::Uuid;

use super::*;
use crate::{
    ConnectionColor, ConnectionGroupName, ConnectionIcon, ConnectionStore, GroupIcon, StoragePaths, SymbolName,
};

fn upper(id: Uuid) -> String {
    id.hyphenated().to_string().to_uppercase()
}

fn saved(id: Uuid, name: &str) -> SavedConnection {
    SavedConnection {
        id,
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

fn group(id: Uuid, name: &str, parent: Option<Uuid>, sort_order: i64) -> CloudGroup {
    CloudGroup {
        group_id: upper(id),
        name: Some(name.to_owned()),
        color: Some("None".to_owned()),
        icon_name: None,
        parent_id: parent.map(upper),
        sort_order: Some(sort_order),
    }
}

fn connection(id: Uuid, name: &str, group: Option<Uuid>, sort_order: i64, favorite: bool) -> CloudConnection {
    CloudConnection {
        connection_id: upper(id),
        name: Some(name.to_owned()),
        group_id: group.map(upper),
        sort_order: Some(sort_order),
        is_favorite: Some(i64::from(favorite)),
    }
}

fn library_of(records: &CloudRecords) -> ConnectionList {
    let connections: Vec<SavedConnection> = records
        .connections
        .iter()
        .filter_map(|record| {
            let id = values::record_id(&record.connection_id)?;
            Some(saved(id, record.name.as_deref().unwrap_or("unnamed")))
        })
        .collect();
    let mut seen = HashSet::new();
    let connections: Vec<SavedConnection> = connections.into_iter().filter(|saved| seen.insert(saved.id)).collect();
    ConnectionList::new(connections, Vec::new())
}

fn names_under(list: &ConnectionList, parent: Option<Uuid>) -> Vec<String> {
    list.group_tree()
        .children(parent)
        .iter()
        .map(|group| group.name.as_str().to_owned())
        .collect()
}

fn names_in(list: &ConnectionList, group: Option<Uuid>) -> Vec<String> {
    list.connections_in(group)
        .iter()
        .map(|saved| saved.name.clone())
        .collect()
}

#[test]
fn macos_records_read_as_a_tree_and_write_back_unchanged() {
    let (work, staging, eu, home) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
    let records = CloudRecords {
        groups: vec![
            CloudGroup {
                color: Some("Gray".to_owned()),
                icon_name: Some("server.rack".to_owned()),
                ..group(work, "Work", None, 1)
            },
            CloudGroup {
                color: Some("Indigo".to_owned()),
                icon_name: Some("cylinder.split.1x2".to_owned()),
                ..group(home, "Home\tLab ", None, 0)
            },
            group(staging, "Staging", Some(work), 0),
            CloudGroup {
                icon_name: Some("Not A Symbol".to_owned()),
                sort_order: None,
                ..group(eu, "EU", Some(staging), 0)
            },
        ],
        connections: vec![
            connection(Uuid::new_v4(), "b", Some(work), 0, true),
            connection(Uuid::new_v4(), "a", Some(work), 0, false),
            CloudConnection {
                is_favorite: Some(2),
                ..connection(Uuid::new_v4(), "top", None, 3, false)
            },
        ],
    };
    let list = layout(&library_of(&records), &records, &[]);

    assert_eq!(names_under(&list, None), ["Home Lab", "Work"]);
    assert_eq!(names_under(&list, Some(work)), ["Staging"]);
    assert_eq!(names_under(&list, Some(staging)), ["EU"]);
    let tree = list.group_tree();
    let [work_group, home_group, eu_group] = [work, home, eu].map(|id| tree.get(id).expect("the group"));
    assert_eq!(work_group.color, Some(ConnectionColor::Slate));
    assert_eq!(work_group.icon, Some(GroupIcon::Named(ConnectionIcon::Server)));
    assert_eq!(home_group.color, None);
    assert_eq!(
        home_group.icon,
        Some(GroupIcon::Symbol(
            SymbolName::new("cylinder.split.1x2").expect("a symbol")
        ))
    );
    assert_eq!(eu_group.icon, None);
    assert_eq!(names_in(&list, Some(work)), ["a", "b"]);
    assert_eq!(list.favorites.len(), 2);

    assert_eq!(edits(&list, &records), CloudRecords::default());
    let mut written = super::records(&list, &records);
    let mut expected = records.clone();
    for set in [&mut written, &mut expected] {
        set.groups.sort_by(|l, r| l.group_id.cmp(&r.group_id));
        set.connections.sort_by(|l, r| l.connection_id.cmp(&r.connection_id));
    }
    assert_eq!(written, expected);
}

#[test]
fn a_parent_the_records_lack_or_a_cycle_roots_the_group_and_its_record_keeps_the_parent() {
    let (lone, first, second, gone) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
    let records = CloudRecords {
        groups: vec![
            group(lone, "Lone", Some(gone), 0),
            group(first, "First", Some(second), 1),
            group(second, "Second", Some(first), 2),
            CloudGroup {
                name: Some(" \t ".to_owned()),
                ..group(Uuid::new_v4(), "", None, 3)
            },
        ],
        connections: vec![connection(Uuid::new_v4(), "stray", Some(gone), 0, false)],
    };
    let list = layout(&library_of(&records), &records, &[]);

    assert_eq!(names_under(&list, None), ["Lone", "First", "Second"]);
    assert_eq!(names_in(&list, None), ["stray"]);
    assert_eq!(edits(&list, &records), CloudRecords::default());
}

#[test]
fn a_new_library_writes_records_as_macos_does_and_reads_them_back() {
    let (work, staging) = (Uuid::new_v4(), Uuid::new_v4());
    let (a, b, c) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
    let groups = vec![
        ConnectionGroup {
            id: work,
            order: 0,
            color: Some(ConnectionColor::Slate),
            icon: Some(GroupIcon::Named(ConnectionIcon::Lab)),
            ..ConnectionGroup::new(ConnectionGroupName::new("Work").expect("a name"), None)
        },
        ConnectionGroup {
            id: staging,
            order: 0,
            color: Some(ConnectionColor::Teal),
            ..ConnectionGroup::new(ConnectionGroupName::new("Staging").expect("a name"), Some(work))
        },
    ];
    let connections = vec![
        SavedConnection {
            group_id: Some(staging),
            order: 0,
            ..saved(a, "a")
        },
        SavedConnection {
            group_id: Some(staging),
            order: 1,
            ..saved(b, "b")
        },
        saved(c, "c"),
    ];
    let list = ConnectionList::new(connections, Vec::new())
        .with_groups(groups)
        .with_favorites(vec![b, c]);

    let written = records(&list, &CloudRecords::default());

    assert_eq!(
        written.groups,
        [
            CloudGroup {
                color: Some("Gray".to_owned()),
                icon_name: Some("flask".to_owned()),
                ..group(work, "Work", None, 0)
            },
            CloudGroup {
                color: Some("Teal".to_owned()),
                ..group(staging, "Staging", Some(work), 0)
            },
        ]
    );
    assert_eq!(
        written.connections,
        [
            connection(c, "c", None, 0, true),
            connection(a, "a", Some(staging), 0, false),
            connection(b, "b", Some(staging), 1, true),
        ]
    );
    let read = layout(&list, &written, &[b, c]);
    assert_eq!(read.groups.to_vec(), list.groups.to_vec());
    assert_eq!(read.connections.to_vec(), list.connections.to_vec());
    assert_eq!(read.favorites.to_vec(), [b, c]);
}

#[test]
fn an_edit_writes_only_the_records_and_fields_it_changed() {
    let (work, home) = (Uuid::new_v4(), Uuid::new_v4());
    let (a, b, c) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
    let base = CloudRecords {
        groups: vec![group(work, "Work", None, 0), group(home, "Home", None, 1)],
        connections: vec![
            connection(a, "a", Some(work), 0, true),
            connection(b, "b", Some(work), 1, false),
            connection(c, "c", Some(work), 2, false),
        ],
    };
    let list = layout(&library_of(&base), &base, &[]);
    let mut connections = list.connections.to_vec();
    for saved in &mut connections {
        if saved.id == b {
            saved.group_id = Some(home);
            saved.order = 0;
        }
    }
    let mut groups = list.groups.to_vec();
    groups[0].name = ConnectionGroupName::new("Office").expect("a name");
    let edited = ConnectionList::new(connections, Vec::new())
        .with_groups(groups)
        .with_favorites(Vec::new());

    let sent = edits(&edited, &base);

    assert_eq!(
        sent.groups,
        [CloudGroup {
            name: Some("Office".to_owned()),
            ..base.groups[0].clone()
        }]
    );
    assert_eq!(
        sent.connections,
        [
            CloudConnection {
                is_favorite: Some(0),
                ..base.connections[0].clone()
            },
            connection(b, "b", Some(home), 0, false),
        ]
    );
}

#[test]
fn favourites_keep_this_devices_order_then_take_new_ones_by_name() {
    let ids: Vec<Uuid> = (0..4).map(|_| Uuid::new_v4()).collect();
    let records = CloudRecords {
        groups: Vec::new(),
        connections: ["delta", "alpha", "Charlie", "bravo"]
            .iter()
            .zip(&ids)
            .zip(0..)
            .map(|((name, id), order)| connection(*id, name, None, order, true))
            .collect(),
    };

    let list = layout(&library_of(&records), &records, &[ids[2], Uuid::new_v4(), ids[0]]);

    assert_eq!(list.favorites.to_vec(), [ids[2], ids[0], ids[1], ids[3]]);
}

fn pull_over(base: &CloudRecords, changed: CloudRecords) -> CloudPull {
    CloudPull {
        base: base.clone(),
        changed,
        ..CloudPull::default()
    }
}

#[test]
fn fields_two_devices_changed_apart_both_survive_and_this_devices_unpushed_edit_wins_its_field() {
    let work = Uuid::new_v4();
    let base = CloudRecords {
        groups: vec![group(work, "Work", None, 0)],
        connections: Vec::new(),
    };
    let mut groups = layout(&library_of(&base), &base, &[]).groups.to_vec();
    groups[0].name = ConnectionGroupName::new("Office").expect("a name");
    groups[0].icon = Some(GroupIcon::Named(ConnectionIcon::Star));
    let local = ConnectionList::new(Vec::new(), Vec::new()).with_groups(groups);
    let server = CloudGroup {
        color: Some("Red".to_owned()),
        icon_name: Some("bolt".to_owned()),
        ..base.groups[0].clone()
    };

    let merged = merged(
        &local,
        &pull_over(
            &base,
            CloudRecords {
                groups: vec![server],
                connections: Vec::new(),
            },
        ),
    );

    assert_eq!(
        merged.groups,
        [CloudGroup {
            name: Some("Office".to_owned()),
            color: Some("Red".to_owned()),
            icon_name: Some("star".to_owned()),
            ..base.groups[0].clone()
        }]
    );
}

#[test]
fn a_deletion_from_either_side_wins_and_a_record_with_no_base_takes_the_servers_copy() {
    let (kept, gone, dropped, fresh) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
    let base = CloudRecords {
        groups: vec![
            group(kept, "Kept", None, 0),
            group(gone, "Gone", None, 1),
            group(dropped, "Dropped", None, 2),
        ],
        connections: Vec::new(),
    };
    let mut groups = layout(&library_of(&base), &base, &[]).groups.to_vec();
    for group in &mut groups {
        group.name = ConnectionGroupName::new(&format!("{} here", group.name)).expect("a name");
    }
    groups.push(ConnectionGroup {
        id: fresh,
        ..ConnectionGroup::new(ConnectionGroupName::new("Fresh here").expect("a name"), None)
    });
    let local = ConnectionList::new(Vec::new(), Vec::new()).with_groups(groups);
    let pull = CloudPull {
        deleted: CloudIds {
            groups: vec![gone],
            connections: Vec::new(),
        },
        deleted_here: CloudIds {
            groups: vec![dropped],
            connections: Vec::new(),
        },
        ..pull_over(
            &base,
            CloudRecords {
                groups: vec![group(fresh, "Fresh there", None, 5)],
                connections: Vec::new(),
            },
        )
    };

    let names: Vec<Option<String>> = merged(&local, &pull).groups.into_iter().map(|g| g.name).collect();

    assert_eq!(names, [Some("Kept here".to_owned()), Some("Fresh there".to_owned())]);
}

#[test]
fn a_move_here_that_closes_a_cycle_with_another_devices_move_yields_to_it() {
    let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
    let base = CloudRecords {
        groups: vec![group(a, "A", None, 0), group(b, "B", None, 1)],
        connections: Vec::new(),
    };
    let mut groups = layout(&library_of(&base), &base, &[]).groups.to_vec();
    for group in &mut groups {
        if group.id == a {
            group.parent_id = Some(b);
        }
    }
    let local = ConnectionList::new(Vec::new(), Vec::new()).with_groups(groups);
    let server = CloudRecords {
        groups: vec![group(a, "A", None, 0), group(b, "B", Some(a), 1)],
        connections: Vec::new(),
    };

    let after = layout(&local, &merged(&local, &pull_over(&base, server.clone())), &[]);

    assert_eq!(names_under(&after, None), ["A"]);
    assert_eq!(names_under(&after, Some(a)), ["B"]);
    assert_eq!(edits(&after, &server), CloudRecords::default());
}

#[test]
fn a_connection_in_a_group_deleted_elsewhere_goes_to_the_top_and_its_record_stays() {
    let (work, a) = (Uuid::new_v4(), Uuid::new_v4());
    let base = CloudRecords {
        groups: vec![group(work, "Work", None, 0)],
        connections: vec![connection(a, "a", Some(work), 0, false)],
    };
    let list = layout(&library_of(&base), &base, &[]);
    let pull = CloudPull {
        deleted: CloudIds {
            groups: vec![work],
            connections: Vec::new(),
        },
        ..pull_over(&base, CloudRecords::default())
    };

    let records_after = merged(&list, &pull);
    let after = layout(&list, &records_after, &[]);

    assert!(after.groups.is_empty());
    assert_eq!(names_in(&after, None), ["a"]);
    let server = CloudRecords {
        groups: Vec::new(),
        connections: base.connections.clone(),
    };
    assert_eq!(edits(&after, &server), CloudRecords::default());
}

fn raw_id(ids: &[Uuid]) -> impl Strategy<Value = Option<String>> + use<> {
    let ids = ids.to_vec();
    prop_oneof![
        Just(None),
        (0..ids.len()).prop_map(move |at| Some(upper(ids[at]))),
        Just(Some("not an id".to_owned())),
        Just(Some(upper(Uuid::nil()))),
    ]
}

fn records_strategy() -> impl Strategy<Value = CloudRecords> {
    let ids: Vec<Uuid> = (0..6).map(|_| Uuid::new_v4()).collect();
    let names = prop::sample::select(vec!["Work", "work", "Prod 10", "Prod 9", "", " \t", "A\u{7}b", "Ünï"]);
    let colors = prop::sample::select(vec![
        None,
        Some("None"),
        Some("Red"),
        Some("Gray"),
        Some("Teal"),
        Some("red"),
    ]);
    let icons = prop::sample::select(vec![
        None,
        Some(""),
        Some("folder"),
        Some("bolt.fill"),
        Some("Bad Name"),
    ]);
    let orders = prop_oneof![Just(None), (-2_i64..4).prop_map(Some), Just(Some(i64::MAX))];
    let group = (
        prop::sample::select(ids.clone()),
        names.clone(),
        colors,
        icons,
        raw_id(&ids),
        orders.clone(),
    )
        .prop_map(|(id, name, color, icon, parent_id, sort_order)| CloudGroup {
            group_id: upper(id),
            name: Some(name.to_owned()),
            color: color.map(str::to_owned),
            icon_name: icon.map(str::to_owned),
            parent_id,
            sort_order,
        });
    let connection_ids: Vec<Uuid> = (0..6).map(|_| Uuid::new_v4()).collect();
    let connection = (
        prop::sample::select(connection_ids),
        names,
        raw_id(&ids),
        orders,
        prop_oneof![Just(None), (0_i64..3).prop_map(Some)],
    )
        .prop_map(|(id, name, group_id, sort_order, is_favorite)| CloudConnection {
            connection_id: upper(id),
            name: Some(name.to_owned()),
            group_id,
            sort_order,
            is_favorite,
        });
    (
        prop::collection::vec(group, 0..8),
        prop::collection::vec(connection, 0..8),
    )
        .prop_map(|(groups, connections)| CloudRecords { groups, connections })
}

proptest! {
    #[test]
    fn any_records_read_and_written_back_send_no_edit(records in records_strategy()) {
        let list = layout(&library_of(&records), &records, &[]);

        prop_assert_eq!(edits(&list, &records), CloudRecords::default());
        let again = layout(&list, &super::records(&list, &records), &list.favorites);
        prop_assert_eq!(shape(&again), shape(&list));
    }
}

// Two devices editing one library apart, syncing through a server that rebases each push as CloudKit does.
struct Device {
    store: ConnectionStore,
    _root: TempDir,
    cache: CloudRecords,
    deleted_here: CloudIds,
}

#[derive(Default)]
struct Server {
    groups: BTreeMap<String, CloudGroup>,
    connections: BTreeMap<String, CloudConnection>,
}

fn key(id: &str) -> String {
    id.to_uppercase()
}

impl Device {
    fn new(connections: &[SavedConnection]) -> Self {
        let root = TempDir::new().expect("tempdir");
        let store = ConnectionStore::new(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"));
        for saved in connections {
            store.upsert_blocking(saved.clone()).expect("the connection");
        }
        Self {
            store,
            _root: root,
            cache: CloudRecords::default(),
            deleted_here: CloudIds::default(),
        }
    }

    // A push saves each edit onto the server's copy, then takes the saved copies in as a pull would: a copy rebased onto another device's change holds fields this library has not read yet.
    fn push(&mut self, server: &mut Server) {
        let sent = self.store.cloud_edits_blocking(&self.cache).expect("the edits");
        let mut saved = CloudRecords::default();
        for record in sent.groups {
            let base = self
                .cache
                .groups
                .iter()
                .find(|held| key(&held.group_id) == key(&record.group_id));
            let stored = server
                .groups
                .entry(key(&record.group_id))
                .or_insert_with(|| record.clone());
            *stored = base.map_or_else(|| record.clone(), |base| merge_group(base, &record, stored));
            saved.groups.push(stored.clone());
        }
        for record in sent.connections {
            let base = self
                .cache
                .connections
                .iter()
                .find(|held| key(&held.connection_id) == key(&record.connection_id));
            let stored = server
                .connections
                .entry(key(&record.connection_id))
                .or_insert_with(|| record.clone());
            *stored = base.map_or_else(|| record.clone(), |base| merge_connection(base, &record, stored));
            saved.connections.push(stored.clone());
        }
        let deleted = std::mem::take(&mut self.deleted_here);
        for id in &deleted.groups {
            server.groups.remove(&upper(*id));
        }
        for id in &deleted.connections {
            server.connections.remove(&upper(*id));
        }
        let pull = CloudPull {
            base: self.cache.clone(),
            changed: saved.clone(),
            deleted: deleted.clone(),
            ..CloudPull::default()
        };
        self.store.apply_cloud_pull_blocking(&pull).expect("the saved records");
        let gone: HashSet<String> = deleted
            .groups
            .iter()
            .chain(&deleted.connections)
            .map(|id| upper(*id))
            .collect();
        self.cache.groups.retain(|held| !gone.contains(&key(&held.group_id)));
        self.cache
            .connections
            .retain(|held| !gone.contains(&key(&held.connection_id)));
        for record in saved.groups {
            self.cache
                .groups
                .retain(|held| key(&held.group_id) != key(&record.group_id));
            self.cache.groups.push(record);
        }
        for record in saved.connections {
            self.cache
                .connections
                .retain(|held| key(&held.connection_id) != key(&record.connection_id));
            self.cache.connections.push(record);
        }
    }

    fn pull(&mut self, server: &Server) {
        let current = server.snapshot();
        let held =
            |records: &CloudRecords| -> HashSet<String> { records.groups.iter().map(|g| key(&g.group_id)).collect() };
        let deleted_groups: Vec<Uuid> = held(&self.cache)
            .difference(&held(&current))
            .filter_map(|id| values::record_id(id))
            .collect();
        let pull = CloudPull {
            base: self.cache.clone(),
            changed: current.clone(),
            deleted: CloudIds {
                groups: deleted_groups,
                connections: Vec::new(),
            },
            deleted_here: self.deleted_here.clone(),
            favorites_order: None,
        };
        self.store.apply_cloud_pull_blocking(&pull).expect("the pull");
        self.cache = current;
    }

    fn list(&self) -> ConnectionList {
        self.store.list_blocking().expect("the list")
    }
}

impl Server {
    fn snapshot(&self) -> CloudRecords {
        CloudRecords {
            groups: self.groups.values().cloned().collect(),
            connections: self.connections.values().cloned().collect(),
        }
    }
}

fn pick<T: Clone + PartialEq>(base: &T, edit: &T, server: &T) -> T {
    if edit == base { server.clone() } else { edit.clone() }
}

fn merge_group(base: &CloudGroup, edit: &CloudGroup, server: &CloudGroup) -> CloudGroup {
    CloudGroup {
        group_id: server.group_id.clone(),
        name: pick(&base.name, &edit.name, &server.name),
        color: pick(&base.color, &edit.color, &server.color),
        icon_name: pick(&base.icon_name, &edit.icon_name, &server.icon_name),
        parent_id: pick(&base.parent_id, &edit.parent_id, &server.parent_id),
        sort_order: pick(&base.sort_order, &edit.sort_order, &server.sort_order),
    }
}

fn merge_connection(base: &CloudConnection, edit: &CloudConnection, server: &CloudConnection) -> CloudConnection {
    CloudConnection {
        connection_id: server.connection_id.clone(),
        name: server.name.clone(),
        group_id: pick(&base.group_id, &edit.group_id, &server.group_id),
        sort_order: pick(&base.sort_order, &edit.sort_order, &server.sort_order),
        is_favorite: pick(&base.is_favorite, &edit.is_favorite, &server.is_favorite),
    }
}

// xorshift, so a failing seed replays.
struct Dice(u64);

impl Dice {
    fn roll(&mut self, sides: usize) -> usize {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        usize::try_from(self.0 % u64::try_from(sides.max(1)).expect("a count")).expect("an index")
    }

    fn pick<T: Copy>(&mut self, items: &[T]) -> Option<T> {
        (!items.is_empty()).then(|| items[self.roll(items.len())])
    }
}

const GROUP_NAMES: [&str; 6] = ["Work", "Home", "Staging", "EU", "work", "Lab"];

fn group_name(dice: &mut Dice) -> ConnectionGroupName {
    ConnectionGroupName::new(GROUP_NAMES[dice.roll(GROUP_NAMES.len())]).expect("a name")
}

// Refused moves and names are part of the game: each device only does what its library allows.
fn play(device: &mut Device, dice: &mut Dice) {
    let list = device.list();
    let groups: Vec<Uuid> = list.groups.iter().map(|group| group.id).collect();
    let connections: Vec<Uuid> = list.connections.iter().map(|saved| saved.id).collect();
    let store = &device.store;
    match dice.roll(9) {
        0 => {
            let parent = if dice.roll(2) == 0 { None } else { dice.pick(&groups) };
            let _ = store.create_group_blocking(ConnectionGroup::new(group_name(dice), parent));
        }
        1 => {
            if let Some(id) = dice.pick(&groups) {
                let name = group_name(dice);
                let _ = store.rename_group_blocking(id, name);
            }
        }
        2 => {
            if let Some(id) = dice.pick(&groups) {
                let color = dice.pick(&ConnectionColor::ALL);
                let _ = store.set_group_color_blocking(id, color);
            }
        }
        3 => {
            if let Some(id) = dice.pick(&groups) {
                let icon = dice.pick(&ConnectionIcon::ALL).map(GroupIcon::Named);
                let _ = store.set_group_icon_blocking(id, icon);
            }
        }
        4 => {
            if let Some(id) = dice.pick(&groups) {
                let parent = if dice.roll(2) == 0 { None } else { dice.pick(&groups) };
                let _ = store.move_groups_blocking(&[id], parent, dice.pick(&groups));
            }
        }
        5 => {
            if let Some(id) = dice.pick(&groups) {
                let mut gone = list.group_tree().descendants(id);
                gone.push(id);
                store.delete_group_blocking(id).expect("the delete");
                device.deleted_here.groups.extend(gone);
            }
        }
        6 => {
            if let Some(id) = dice.pick(&connections) {
                let group = if dice.roll(3) == 0 { None } else { dice.pick(&groups) };
                let _ = store.move_connections_blocking(&[id], group, dice.pick(&connections));
            }
        }
        7 => {
            if let Some(id) = dice.pick(&connections) {
                store
                    .add_favorites_blocking(&[id], dice.pick(&connections))
                    .expect("a favourite");
            }
        }
        _ => {
            if let Some(id) = dice.pick(&connections) {
                store.remove_favorites_blocking(&[id]).expect("no favourite");
            }
        }
    }
}

fn settle(devices: &mut [Device], server: &mut Server) {
    for _ in 0..4 {
        for device in devices.iter_mut() {
            device.push(server);
            device.pull(server);
        }
    }
}

fn shape(list: &ConnectionList) -> (Vec<ConnectionGroup>, Vec<(Uuid, Option<Uuid>, u32)>, Vec<Uuid>) {
    let mut groups = list.groups.to_vec();
    groups.sort_by_key(|group| group.id);
    let mut connections: Vec<(Uuid, Option<Uuid>, u32)> = list
        .connections
        .iter()
        .map(|saved| (saved.id, saved.group_id, saved.order))
        .collect();
    connections.sort();
    let mut favorites = list.favorites.to_vec();
    favorites.sort();
    (groups, connections, favorites)
}

#[test]
fn two_devices_editing_apart_converge_and_then_send_nothing() {
    let connections: Vec<SavedConnection> = ["alpha", "bravo", "charlie", "delta", "echo"]
        .iter()
        .map(|name| saved(Uuid::new_v4(), name))
        .collect();
    for seed in 1..=24_u64 {
        let mut dice = Dice(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15));
        let mut server = Server::default();
        let mut devices = [Device::new(&connections), Device::new(&connections)];
        settle(&mut devices, &mut server);
        for _ in 0..30 {
            let at = dice.roll(2);
            play(&mut devices[at], &mut dice);
            match dice.roll(4) {
                0 => devices[at].push(&mut server),
                1 => devices[at].pull(&server),
                _ => {}
            }
        }
        settle(&mut devices, &mut server);

        let [first, second] = &devices;
        assert_eq!(shape(&first.list()), shape(&second.list()), "seed {seed}");
        for device in &devices {
            let sent = device.store.cloud_edits_blocking(&device.cache).expect("the edits");
            assert_eq!(sent, CloudRecords::default(), "seed {seed}");
        }
    }
}
