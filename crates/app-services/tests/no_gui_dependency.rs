#[test]
fn the_crate_does_not_depend_on_a_gui_toolkit() {
    let manifest = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml")).unwrap();
    for forbidden in ["gtk4", "libadwaita", "glib", "relm4", "sourceview5", "gio"] {
        assert!(
            !manifest.contains(forbidden),
            "{forbidden} must not be a dependency of app-services"
        );
    }
}
