use tablepro_ffi::{KeymapPlatformTag, KeymapPresetInfo, keymap_preset, keymap_presets};

fn rows(id: &str, platform: KeymapPlatformTag) -> Vec<(String, String)> {
    keymap_preset(id.to_owned(), platform)
        .map(|bindings| {
            bindings
                .into_iter()
                .map(|binding| {
                    let modifiers = [
                        (binding.ctrl, "ctrl+"),
                        (binding.shift, "shift+"),
                        (binding.alt, "alt+"),
                        (binding.cmd, "cmd+"),
                    ];
                    let held: String = modifiers
                        .into_iter()
                        .filter(|(held, _)| *held)
                        .map(|(_, name)| name)
                        .collect();
                    (binding.action, format!("{held}{}", binding.key))
                })
                .collect()
        })
        .unwrap_or_default()
}

fn has(rows: &[(String, String)], action: &str, chord: &str) -> bool {
    rows.iter().any(|(name, key)| name == action && key == chord)
}

// The Windows app asks for Windows rows, and a test on any host gets the same answer.
#[test]
fn every_platform_s_rows_come_back_on_any_host() {
    let windows = rows("dbeaver", KeymapPlatformTag::Windows);
    let mac = rows("dbeaver", KeymapPlatformTag::MacOs);

    assert!(has(&windows, "executeQuery", "ctrl+enter"));
    assert!(has(&windows, "executeAllStatements", "ctrl+shift+enter"));
    assert!(has(&windows, "discardChanges", "ctrl+r"));
    assert!(has(&mac, "executeQuery", "cmd+enter"));
    assert!(
        !mac.iter()
            .any(|(action, _)| action == "executeAllStatements" || action == "discardChanges")
    );
    assert!(windows.iter().all(|(_, chord)| !chord.contains("cmd+")));
}

#[test]
fn derived_rows_are_marked_off_macos_only() {
    let windows = keymap_preset("tableplus".to_owned(), KeymapPlatformTag::Windows).unwrap_or_default();
    let mac = keymap_preset("tableplus".to_owned(), KeymapPlatformTag::MacOs).unwrap_or_default();

    assert!(!windows.is_empty() && windows.iter().all(|binding| binding.derived));
    assert!(!mac.is_empty() && mac.iter().all(|binding| !binding.derived));
}

#[test]
fn the_presets_a_platform_offers_leave_out_a_mac_only_app() {
    let ids = |platform| -> Vec<String> {
        keymap_presets(platform)
            .unwrap_or_default()
            .into_iter()
            .map(|preset| preset.id)
            .collect()
    };

    assert_eq!(
        ids(KeymapPlatformTag::Windows),
        ["tableplus", "dbeaver", "datagrip", "beekeeperstudio", "navicat", "dbx"]
    );
    assert_eq!(ids(KeymapPlatformTag::MacOs).len(), 7);
    assert_eq!(
        keymap_presets(KeymapPlatformTag::Linux)
            .ok()
            .and_then(|presets| presets.into_iter().next()),
        Some(KeymapPresetInfo {
            id: "tableplus".to_owned(),
            name: "TablePlus".to_owned(),
        })
    );
}

#[test]
fn a_preset_off_its_platform_or_unknown_fails_with_its_code() {
    let code = |id: &str, platform| {
        keymap_preset(id.to_owned(), platform)
            .err()
            .map(|error| error.code().to_owned())
    };

    assert_eq!(
        code("sequelace", KeymapPlatformTag::Windows).as_deref(),
        Some("keymap.not_on_platform")
    );
    assert_eq!(
        code("vscode", KeymapPlatformTag::Linux).as_deref(),
        Some("keymap.unknown_preset")
    );
}
