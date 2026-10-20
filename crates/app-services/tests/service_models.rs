#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_app_services::{
    preferences::{ColorSchemePref, Preferences},
    quick_switcher::{QuickItem, QuickTarget, filter},
    reconnect::is_permanent_failure,
};

#[test]
fn older_preferences_keep_the_same_defaults_without_desktop_settings() {
    let prefs: Preferences =
        serde_json::from_str(r#"{"default_page_size":50,"confirm_destructive":true,"editor_font_size":12}"#).unwrap();
    assert_eq!(prefs.color_scheme, ColorSchemePref::System);
    assert!(prefs.open_tables_in_preview_tab);
    assert_eq!(prefs.query_timeout_secs, 60);
}

#[test]
fn quick_switching_keeps_commands_out_of_the_empty_search() {
    let items = vec![QuickItem {
        target: QuickTarget::Command("open-editor"),
        title: "New SQL tab".into(),
        subtitle: "Command".into(),
    }];
    assert!(filter(&items, "").is_empty());
    assert_eq!(filter(&items, ">sql"), items);
}

#[test]
fn reconnect_classification_preserves_permanent_and_retryable_failures() {
    use tablepro_transport::TransportError;
    assert!(is_permanent_failure(&TransportError::Driver(
        tablepro_core::DriverError::AuthFailed
    )));
    assert!(!is_permanent_failure(&TransportError::Cancelled));
}
