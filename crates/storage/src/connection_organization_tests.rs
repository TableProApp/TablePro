use tempfile::TempDir;

use tablepro_core::{AuthMode, Environment, TlsMode};

use super::*;

fn connection(name: &str, driver_id: &str) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: name.into(),
        driver_id: driver_id.into(),
        host: "localhost".into(),
        port: 5432,
        socket_dir: None,
        database: "app".into(),
        username: "app".into(),
        use_tls: false,
        tls_mode: Some(TlsMode::Disabled),
        tls_root_cert: None,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: false,
        auth_mode: AuthMode::Password,
        environment: Environment::Local,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    }
}

fn organization(group: Option<&str>, tags: &[&str], favorite: bool) -> ConnectionOrganization {
    let tags: Vec<String> = tags.iter().map(|tag| (*tag).to_string()).collect();
    ConnectionOrganization::new(group, &tags, favorite).unwrap()
}

#[test]
fn a_connection_belongs_to_at_most_one_group() {
    let entry = organization(Some("  Production  "), &[], false);
    assert_eq!(entry.group.as_deref(), Some("Production"));
    let cleared = organization(Some("   "), &[], false);
    assert!(cleared.group.is_none());
}

#[test]
fn tags_are_trimmed_deduplicated_and_sorted() {
    let entry = organization(None, &[" Reporting ", "reporting", "Billing", ""], false);
    assert_eq!(entry.tags, vec!["Billing".to_string(), "Reporting".to_string()]);
}

#[test]
fn oversized_labels_and_tag_counts_are_refused() {
    let long = "x".repeat(MAX_LABEL_LEN + 1);
    assert!(ConnectionOrganization::new(Some(&long), &[], false).is_err());
    assert!(ConnectionOrganization::new(None, std::slice::from_ref(&long), false).is_err());
    assert!(ConnectionOrganization::new(Some("a\u{0007}b"), &[], false).is_err());
    let many: Vec<String> = (0..MAX_TAGS_PER_CONNECTION + 1).map(|i| format!("tag{i}")).collect();
    assert!(ConnectionOrganization::new(None, &many, false).is_err());
}

#[test]
fn the_index_caps_how_many_connections_it_organizes() {
    let mut index = ConnectionOrganizationIndex::default();
    for _ in 0..MAX_ORGANIZED_CONNECTIONS {
        index.set(Uuid::new_v4(), organization(Some("g"), &[], false)).unwrap();
    }
    let over = index.set(Uuid::new_v4(), organization(Some("g"), &[], false));
    assert!(over.is_err(), "the index must refuse to grow past its ceiling");
}

#[test]
fn clearing_every_field_drops_the_entry_instead_of_storing_a_blank() {
    let mut index = ConnectionOrganizationIndex::default();
    let id = Uuid::new_v4();
    index.set(id, organization(Some("Prod"), &["a"], true)).unwrap();
    index.set(id, ConnectionOrganization::default()).unwrap();
    assert!(index.groups().is_empty());
    assert!(!index.is_favorite(id));
}

#[test]
fn the_favorite_flag_toggles_without_touching_group_or_tags() {
    let mut index = ConnectionOrganizationIndex::default();
    let id = Uuid::new_v4();
    index.set(id, organization(Some("Prod"), &["billing"], false)).unwrap();
    index.set_favorite(id, true).unwrap();
    let entry = index.get(id);
    assert!(entry.favorite);
    assert_eq!(entry.group.as_deref(), Some("Prod"));
    assert_eq!(entry.tags, vec!["billing".to_string()]);
}

#[test]
fn deleting_a_connection_prunes_its_organization_entry() {
    let kept = connection("Kept", "postgres");
    let gone = connection("Gone", "mysql");
    let mut index = ConnectionOrganizationIndex::default();
    index.set(kept.id, organization(Some("Prod"), &[], false)).unwrap();
    index.set(gone.id, organization(Some("Old"), &[], false)).unwrap();
    index.retain_known(std::slice::from_ref(&kept));
    assert_eq!(index.groups(), vec!["Prod".to_string()]);
}

#[test]
fn groups_and_tags_are_listed_once_each_case_insensitively() {
    let mut index = ConnectionOrganizationIndex::default();
    index
        .set(Uuid::new_v4(), organization(Some("Prod"), &["billing"], false))
        .unwrap();
    index
        .set(Uuid::new_v4(), organization(Some("prod"), &["Billing", "audit"], false))
        .unwrap();
    assert_eq!(index.groups().len(), 1);
    assert_eq!(index.tags(), vec!["audit".to_string(), "Billing".to_string()]);
    assert_eq!(index.groups(), vec!["Prod".to_string()]);
}

#[test]
fn a_bare_filter_term_matches_name_group_tag_or_driver() {
    let connection = connection("Sales warehouse", "clickhouse");
    let entry = organization(Some("Analytics"), &["billing"], false);
    for term in ["sales", "analytics", "billing", "clickhouse", "CLICK"] {
        assert!(
            connection_matches_filter(&connection, &entry, term),
            "{term} should match"
        );
    }
    assert!(!connection_matches_filter(&connection, &entry, "postgres"));
}

#[test]
fn qualified_filter_terms_narrow_to_one_field() {
    let connection = connection("Analytics", "postgres");
    let entry = organization(Some("Production"), &["billing"], false);
    assert!(connection_matches_filter(&connection, &entry, "group:prod"));
    assert!(!connection_matches_filter(&connection, &entry, "group:billing"));
    assert!(connection_matches_filter(&connection, &entry, "tag:billing"));
    assert!(!connection_matches_filter(&connection, &entry, "tag:analytics"));
    assert!(connection_matches_filter(&connection, &entry, "driver:postgres"));
    assert!(!connection_matches_filter(&connection, &entry, "driver:mysql"));
    assert!(!connection_matches_filter(&connection, &entry, "group:"));
}

#[test]
fn multiple_terms_narrow_instead_of_widening() {
    let connection = connection("Analytics", "postgres");
    let entry = organization(Some("Production"), &["billing"], false);
    assert!(connection_matches_filter(&connection, &entry, "group:prod tag:billing"));
    assert!(!connection_matches_filter(&connection, &entry, "group:prod tag:audit"));
}

#[test]
fn is_favorite_keeps_only_favorites_and_an_empty_filter_keeps_everything() {
    let connection = connection("Analytics", "postgres");
    let plain = organization(None, &[], false);
    let starred = organization(None, &[], true);
    assert!(connection_matches_filter(&connection, &plain, "   "));
    assert!(!connection_matches_filter(&connection, &plain, "is:favorite"));
    assert!(connection_matches_filter(&connection, &starred, "is:favorite"));
}

#[test]
fn arranging_puts_favorites_first_then_groups_then_ungrouped() {
    let star = connection("zeta", "postgres");
    let grouped = connection("alpha", "postgres");
    let other_group = connection("beta", "postgres");
    let loose = connection("gamma", "postgres");
    let mut index = ConnectionOrganizationIndex::default();
    index.set(star.id, organization(None, &[], true)).unwrap();
    index.set(grouped.id, organization(Some("Prod"), &[], false)).unwrap();
    index
        .set(other_group.id, organization(Some("Analytics"), &[], false))
        .unwrap();

    let connections = vec![loose.clone(), grouped.clone(), other_group.clone(), star.clone()];
    let arranged = arrange_connections(&connections, &index, "");
    let names: Vec<&str> = arranged.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["zeta", "beta", "alpha", "gamma"]);
}

#[test]
fn arranging_applies_the_filter() {
    let a = connection("Reporting", "postgres");
    let b = connection("Sales", "mysql");
    let index = ConnectionOrganizationIndex::default();
    let arranged = arrange_connections(&[a.clone(), b.clone()], &index, "driver:mysql");
    assert_eq!(arranged.len(), 1);
    assert_eq!(arranged[0].name, "Sales");
}

#[tokio::test]
async fn load_returns_an_empty_index_when_the_file_is_missing() {
    let dir = TempDir::new().unwrap();
    let index = load_from(&dir.path().join("connection-organization.json"))
        .await
        .unwrap();
    assert_eq!(index, ConnectionOrganizationIndex::default());
}

#[tokio::test]
async fn a_file_written_by_this_version_still_loads() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    let id = Uuid::new_v4();
    let mut index = ConnectionOrganizationIndex::default();
    index
        .set(id, organization(Some("Prod"), &["billing", "audit"], true))
        .unwrap();
    save_to(&path, &index).await.unwrap();

    let loaded = load_from(&path).await.unwrap();
    assert_eq!(loaded, index);
    assert!(loaded.is_favorite(id));
}

#[tokio::test]
async fn a_field_written_by_a_newer_version_survives_a_rewrite() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    let id = Uuid::new_v4();
    let mut index = ConnectionOrganizationIndex::default();
    index.set(id, organization(Some("Prod"), &[], false)).unwrap();
    save_to(&path, &index).await.unwrap();

    let mut document: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    document["connections"][id.to_string()]["colour"] = serde_json::json!("teal");
    document["future_section"] = serde_json::json!({ "keep": true });
    std::fs::write(&path, serde_json::to_vec_pretty(&document).unwrap()).unwrap();

    let mut reloaded = load_from(&path).await.unwrap();
    reloaded.set_favorite(id, true).unwrap();
    save_to(&path, &reloaded).await.unwrap();

    let rewritten: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(rewritten["connections"][id.to_string()]["colour"], "teal");
    assert_eq!(rewritten["future_section"]["keep"], true);
    assert_eq!(rewritten["connections"][id.to_string()]["favorite"], true);
}

#[tokio::test]
async fn an_unsupported_version_is_refused() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    tokio::fs::write(&path, r#"{"version":999,"connections":{}}"#)
        .await
        .unwrap();
    assert!(load_from(&path).await.is_err());
}

#[tokio::test]
async fn a_file_over_the_connection_ceiling_is_refused() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    let mut entries = serde_json::Map::new();
    for _ in 0..(MAX_ORGANIZED_CONNECTIONS + 1) {
        entries.insert(Uuid::new_v4().to_string(), serde_json::json!({ "favorite": true }));
    }
    let document = serde_json::json!({ "version": 1, "connections": entries });
    tokio::fs::write(&path, serde_json::to_vec(&document).unwrap())
        .await
        .unwrap();
    assert!(load_from(&path).await.is_err());
}

#[tokio::test]
async fn a_hostile_file_is_sanitized_rather_than_trusted() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    let id = Uuid::new_v4();
    let long = "x".repeat(MAX_LABEL_LEN + 1);
    let tags: Vec<String> = (0..MAX_TAGS_PER_CONNECTION + 5).map(|i| format!("tag{i}")).collect();
    let document = serde_json::json!({
        "version": 1,
        "connections": { id.to_string(): { "group": long, "tags": tags, "favorite": true } },
    });
    tokio::fs::write(&path, serde_json::to_vec(&document).unwrap())
        .await
        .unwrap();

    let loaded = load_from(&path).await.unwrap();
    let entry = loaded.get(id);
    assert!(entry.group.is_none(), "an over-long group must not be trusted");
    assert_eq!(entry.tags.len(), MAX_TAGS_PER_CONNECTION);
    assert!(entry.favorite);
}

#[tokio::test]
async fn concurrent_stale_indexes_merge_distinct_records() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    save_to(&path, &ConnectionOrganizationIndex::default()).await.unwrap();
    let mut first = load_from(&path).await.unwrap();
    let mut second = load_from(&path).await.unwrap();
    let first_id = Uuid::new_v4();
    let second_id = Uuid::new_v4();
    first.set(first_id, organization(Some("First"), &[], false)).unwrap();
    second.set(second_id, organization(Some("Second"), &[], false)).unwrap();
    let first_path = path.clone();
    let second_path = path.clone();

    let (first_result, second_result) = tokio::join!(save_to(&first_path, &first), save_to(&second_path, &second));

    first_result.unwrap();
    second_result.unwrap();
    let loaded = load_from(&path).await.unwrap();
    assert_eq!(loaded.get(first_id).group.as_deref(), Some("First"));
    assert_eq!(loaded.get(second_id).group.as_deref(), Some("Second"));
}

#[tokio::test]
async fn concurrent_stale_indexes_merge_distinct_fields_on_one_record() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    let id = Uuid::new_v4();
    let mut initial = ConnectionOrganizationIndex::default();
    initial.set(id, organization(None, &["base"], false)).unwrap();
    save_to(&path, &initial).await.unwrap();
    let mut grouped = load_from(&path).await.unwrap();
    let mut favorite = load_from(&path).await.unwrap();
    grouped.set(id, organization(Some("Prod"), &[], false)).unwrap();
    favorite.set_favorite(id, true).unwrap();
    let grouped_path = path.clone();
    let favorite_path = path.clone();

    let (grouped_result, favorite_result) =
        tokio::join!(save_to(&grouped_path, &grouped), save_to(&favorite_path, &favorite));

    grouped_result.unwrap();
    favorite_result.unwrap();
    let loaded = load_from(&path).await.unwrap().get(id);
    assert_eq!(loaded.group.as_deref(), Some("Prod"));
    assert!(loaded.favorite);
}

#[test]
fn a_colour_outside_the_palette_is_not_stored() {
    let entry = organization(None, &[], false).with_color(Some("#ff0000"));
    assert_eq!(entry.color, None);
    assert!(entry.is_empty());
}

#[test]
fn a_palette_colour_is_stored_normalised() {
    let entry = organization(None, &[], false).with_color(Some(" Blue "));
    assert_eq!(entry.color.as_deref(), Some("blue"));
    assert!(!entry.is_empty());
}

#[tokio::test]
async fn a_colour_tag_round_trips_through_the_sidecar() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    let id = Uuid::new_v4();
    let mut index = ConnectionOrganizationIndex::default();
    index
        .set(id, organization(Some("Prod"), &[], false).with_color(Some("red")))
        .unwrap();
    save_to(&path, &index).await.unwrap();

    let loaded = load_from(&path).await.unwrap().get(id);
    assert_eq!(loaded.color.as_deref(), Some("red"));
    assert_eq!(loaded.group.as_deref(), Some("Prod"));
}

#[tokio::test]
async fn a_colour_outside_the_palette_on_disk_reads_as_no_colour() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    let id = Uuid::new_v4();
    let document = serde_json::json!({
        "version": 1,
        "connections": { id.to_string(): { "group": "Prod", "color": "url(javascript:alert(1))" } },
    });
    tokio::fs::write(&path, serde_json::to_vec(&document).unwrap())
        .await
        .unwrap();

    let loaded = load_from(&path).await.unwrap().get(id);
    assert_eq!(loaded.color, None);
    assert_eq!(loaded.group.as_deref(), Some("Prod"));
}

#[tokio::test]
async fn concurrent_indexes_merge_a_colour_against_a_group() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    let id = Uuid::new_v4();
    let mut initial = ConnectionOrganizationIndex::default();
    initial.set(id, organization(None, &["base"], false)).unwrap();
    save_to(&path, &initial).await.unwrap();
    let mut grouped = load_from(&path).await.unwrap();
    let mut coloured = load_from(&path).await.unwrap();
    grouped.set(id, organization(Some("Prod"), &["base"], false)).unwrap();
    coloured
        .set(id, organization(None, &["base"], false).with_color(Some("teal")))
        .unwrap();

    save_to(&path, &grouped).await.unwrap();
    save_to(&path, &coloured).await.unwrap();

    let loaded = load_from(&path).await.unwrap().get(id);
    assert_eq!(loaded.group.as_deref(), Some("Prod"));
    assert_eq!(loaded.color.as_deref(), Some("teal"));
}

#[tokio::test]
async fn a_malformed_organization_file_survives_a_write() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connection-organization.json");
    let malformed = b"{not valid json";
    tokio::fs::write(&path, malformed).await.unwrap();
    let mut index = ConnectionOrganizationIndex::default();
    index
        .set(Uuid::new_v4(), organization(Some("Prod"), &[], false))
        .unwrap();

    assert!(save_to(&path, &index).await.is_err());
    assert_eq!(tokio::fs::read(&path).await.unwrap(), malformed);
}
