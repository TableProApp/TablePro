use tablepro_core::keymap::{self, Platform};
use tablepro_foreign_import::{ForeignApp, ForeignPlatform};

fn foreign(platform: Platform) -> ForeignPlatform {
    match platform {
        Platform::MacOs => ForeignPlatform::MacOs,
        Platform::Linux => ForeignPlatform::Linux,
        Platform::Windows => ForeignPlatform::Windows,
    }
}

// A preset is picked by the id of the app the user imported from, so the two lists name the same apps.
#[test]
fn every_preset_is_an_import_source_named_as_the_importer_names_it() {
    let presets = keymap::presets().expect("the bundled presets");
    let ids: Vec<&str> = presets.iter().map(|preset| preset.id.as_str()).collect();
    let apps: Vec<&str> = ForeignApp::ALL.into_iter().map(ForeignApp::id).collect();
    assert_eq!(ids, apps);
    for preset in &presets {
        let app = ForeignApp::from_id(&preset.id).expect("an import source");
        assert_eq!(preset.name, app.display_name(), "{}", preset.id);
        let runs_on: Vec<Platform> = [Platform::MacOs, Platform::Linux, Platform::Windows]
            .into_iter()
            .filter(|platform| app.runs_on(foreign(*platform)))
            .collect();
        assert_eq!(preset.platforms, runs_on, "{}", preset.id);
    }
}
