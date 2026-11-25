use uuid::Uuid;

use super::*;
use crate::record_id::column_layout_category;

#[test]
fn the_mac_registry_names_each_category_it_syncs() {
    let registry = registry(Kind::MacosSettings).expect("the Mac's registry");
    for category in [
        "general",
        "appearance",
        "editor",
        "dataGrid",
        "history",
        "tabs",
        "keyboard",
        "ai",
        "notifications",
        "formatter",
        "valueColors",
        "customSlashCommands",
        "theme.user.0a1b2c3d",
    ] {
        assert!(registry.names(category), "{category}");
    }
    let layout = column_layout_category(Uuid::nil(), Some("shop"), Some("public"), "orders");
    assert!(registry.names(&layout));
    for device_only in ["sync", "mcp", "appearanceMode", "typography"] {
        assert!(!registry.names(device_only), "{device_only}");
    }
}

// 0044, Conflict rules: keyboard, AI and each theme go whole.
#[test]
fn keyboard_ai_and_themes_go_whole_and_the_rest_merge_by_option() {
    let registry = registry(Kind::MacosSettings).expect("the Mac's registry");
    let whole: Vec<CategoryId> = registry
        .categories
        .iter()
        .filter(|category| category.merge == Merge::Whole)
        .map(|category| category.id)
        .collect();

    assert_eq!(
        whole,
        [
            CategoryId::Named("keyboard"),
            CategoryId::Named("ai"),
            CategoryId::Theme
        ]
    );
}

#[test]
fn the_other_platforms_name_no_category_yet() {
    for kind in [Kind::IosSettings, Kind::LinuxSettings, Kind::WindowsSettings] {
        assert_eq!(
            registry(kind).map(|registry| registry.categories.len()),
            Some(0),
            "{kind}"
        );
    }
    assert_eq!(registry(Kind::Connection), None);
}

#[test]
fn ai_options_that_send_a_provider_more_wait_for_approval() {
    let registry = registry(Kind::MacosSettings).expect("the Mac's registry");
    let ai = registry.category("ai").expect("ai");
    let class = |key: &str| {
        ai.document
            .options()
            .iter()
            .find(|option| option.key == key)
            .map(|option| option.class)
            .expect("an option")
    };
    for key in [
        "includeSchema",
        "includeQueryResults",
        "defaultConnectionPolicy",
        "providers",
        "enabled",
    ] {
        assert!(matches!(class(key), crate::schema::Class::Approval(_)), "{key}");
    }
    assert_eq!(class("composerHighlightEnabled"), crate::schema::Class::Inert);
}

#[test]
fn a_column_layout_belongs_to_its_connection() {
    let connection = Uuid::from_u128(7);
    let category = column_layout_category(connection, None, None, "t");

    assert_eq!(owner(&category), Some(connection));
    assert_eq!(owner("editor"), None);
}
