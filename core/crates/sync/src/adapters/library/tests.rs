use serde_json::json;
use tablepro_storage::{
    ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionTag, ConnectionTagName, StoragePaths,
};

use super::*;

fn store(dir: &std::path::Path) -> ConnectionStore {
    ConnectionStore::new(&StoragePaths::under(dir, "tablepro", "app.tablepro.TablePro"))
}

fn adapter(store: &ConnectionStore, kind: Kind) -> Arc<dyn RecordAdapter> {
    LibraryAdapter::all(store)
        .into_iter()
        .find(|adapter| adapter.kind() == kind)
        .expect("an adapter for the kind")
}

const GROUP: &str = "E6C12C96-3CBD-4A0E-9F41-E36B47F35D84";
const PARENT: &str = "84BC7D00-A144-4C18-80C0-A11C6070D4F9";
const TAG: &str = "3FD0B191-5CF8-4760-84A9-92779983F3CF";

#[test]
fn a_group_goes_up_as_the_mac_writes_it() {
    let group = ConnectionGroup {
        color: Some(ConnectionColor::Slate),
        order: 3,
        parent_id: parse_uuid(PARENT),
        ..ConnectionGroup::new(ConnectionGroupName::new("Work").unwrap(), None)
    };
    let plain = ConnectionGroup::new(ConnectionGroupName::new("Home").unwrap(), None);

    assert_eq!(
        groups::group_to_wire(&group),
        json!({"name": "Work", "color": "Gray", "parent_id": PARENT, "sort_order": 3})
    );
    assert_eq!(
        groups::group_to_wire(&plain),
        json!({"name": "Home", "color": "None", "sort_order": 0})
    );
}

#[test]
fn a_tag_with_no_colour_reads_as_gray_as_the_mac_reads_it() {
    let id = parse_uuid(TAG).unwrap();

    let tag = groups::tag(id, &json!({"name": "prod", "is_preset": true}), None);

    assert_eq!(tag.color, Some(ConnectionColor::Slate));
    assert!(tag.is_preset);
    assert_eq!(
        groups::tag_to_wire(&ConnectionTag {
            color: None,
            ..tag
        }),
        json!({"name": "prod", "color": "None", "is_preset": true})
    );
}

#[test]
fn a_colour_a_newer_build_names_reads_as_the_base_s_until_the_person_changes_it() {
    let base = json!({"name": "Work", "color": "Magenta", "sort_order": 0});
    let id = parse_uuid(GROUP).unwrap();
    let stored = groups::group_to_wire(&groups::group(id, &base, None));
    let mut recoloured = stored.clone();
    recoloured["color"] = json!("Red");

    assert_eq!(stored["color"], json!("None"));
    assert_eq!(at_base(Kind::Group, &stored, Some(&base)), ["/color"]);
    assert!(at_base(Kind::Group, &recoloured, Some(&base)).is_empty());
}

#[tokio::test]
async fn groups_and_tags_round_trip_through_the_store_in_one_write_each() {
    let dir = tempfile::tempdir().unwrap();
    let store = store(dir.path());
    let groups = adapter(&store, Kind::Group);
    let tags = adapter(&store, Kind::Tag);
    let group = json!({"name": "Work", "color": "Blue", "icon_name": "server.rack", "sort_order": 2});
    let tag = json!({"name": "prod", "color": "Red", "is_preset": false});

    let before = groups.identity().await.unwrap();
    groups
        .apply(
            ScopeName::Personal,
            vec![LocalChange::Put {
                record_id: GROUP.to_owned(),
                fields: group.clone(),
            }],
        )
        .await
        .unwrap();
    let after = tags
        .apply(
            ScopeName::Personal,
            vec![LocalChange::Put {
                record_id: TAG.to_owned(),
                fields: tag.clone(),
            }],
        )
        .await
        .unwrap();
    let held = groups.records(ScopeName::Personal).await.unwrap().records;
    let elsewhere = groups.records(ScopeName::History).await.unwrap().records;

    assert!(!after.needs_refill(before));
    assert_eq!(held.len(), 1);
    assert_eq!(held[0].record_id, GROUP);
    assert_eq!(held[0].fields, group);
    assert_eq!(tags.records(ScopeName::Personal).await.unwrap().records[0].fields, tag);
    assert!(elsewhere.is_empty());

    groups
        .apply(
            ScopeName::Personal,
            vec![LocalChange::Delete {
                record_id: GROUP.to_owned(),
            }],
        )
        .await
        .unwrap();
    assert!(groups.records(ScopeName::Personal).await.unwrap().records.is_empty());
    assert_eq!(tags.records(ScopeName::Personal).await.unwrap().records.len(), 1);
}

#[tokio::test]
async fn a_new_store_starts_its_generation_and_every_kind_names_the_one_file() {
    let dir = tempfile::tempdir().unwrap();
    let store = store(dir.path());
    let adapters = LibraryAdapter::all(&store);

    let first = adapters[0].identity().await.unwrap();
    let again = adapters[1].identity().await.unwrap();

    assert_ne!(first.generation, Uuid::nil());
    assert_eq!(first, again);
    assert!(adapters.iter().all(|adapter| adapter.store() == STORE));
}
