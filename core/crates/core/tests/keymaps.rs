#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "the helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;

use serde_json::Value;
use tablepro_core::keymap::{self, Chord, Keymap, KeymapAction, KeymapError, Platform, SCHEMA_VERSION};

const FILE: &str = include_str!("../keymaps.json");
const PLATFORM_FIELDS: [&str; 4] = ["key", "mac", "linux", "windows"];

fn raw_presets() -> Vec<Value> {
    let file: Value = serde_json::from_str(FILE).expect("the bundled keymaps parse as JSON");
    file.get("presets")
        .and_then(Value::as_array)
        .cloned()
        .expect("a presets list")
}

fn text<'a>(value: &'a Value, field: &str) -> Option<&'a str> {
    value.get(field).and_then(Value::as_str)
}

fn parse_error(text: &str) -> KeymapError {
    match Keymap::parse(text) {
        Ok(_) => panic!("expected {text} to be refused"),
        Err(error) => error,
    }
}

#[test]
fn the_bundled_file_parses_at_the_schema_version() {
    let file: Value = serde_json::from_str(FILE).expect("JSON");
    assert_eq!(
        file.get("schemaVersion").and_then(Value::as_u64),
        Some(u64::from(SCHEMA_VERSION))
    );
    let ids: Vec<String> = keymap::presets()
        .expect("the bundled presets")
        .into_iter()
        .map(|preset| preset.id)
        .collect();
    assert_eq!(
        ids,
        [
            "tableplus",
            "sequelace",
            "dbeaver",
            "datagrip",
            "beekeeperstudio",
            "navicat",
            "dbx"
        ]
    );
}

// The data rules every app relies on, so an app applies only its own platform's refusals.
#[test]
fn every_preset_keeps_the_data_rules_on_every_platform() {
    for summary in keymap::presets().expect("the bundled presets") {
        for platform in summary.platforms.iter().copied() {
            let bindings = keymap::preset(&summary.id, platform).expect("a preset");
            let mut seen: HashMap<String, KeymapAction> = HashMap::new();
            for binding in &bindings {
                let chord = &binding.chord;
                let context = format!("{} {platform:?} {} {chord}", summary.id, binding.action.as_str());
                assert!(
                    chord.ctrl || chord.alt || chord.cmd || chord.is_function_key(),
                    "a bare key: {context}"
                );
                let only_command = (chord.ctrl ^ chord.cmd) && !chord.shift && !chord.alt;
                assert!(
                    !(only_command && ["c", "v", "x", "z", "a"].contains(&chord.key.as_str())),
                    "an edit command's key: {context}"
                );
                assert!(!chord.cmd || platform == Platform::MacOs, "cmd off macOS: {context}");
                assert!(
                    !binding.derived || platform != Platform::MacOs,
                    "derived on macOS: {context}"
                );
                if let Some(other) = seen.insert(chord.to_string(), binding.action) {
                    panic!("{context} is also {}", other.as_str());
                }
            }
        }
    }
}

#[test]
fn every_chord_is_written_in_canonical_order_with_cmd_only_on_mac() {
    for preset in raw_presets() {
        let id = text(&preset, "id").expect("an id");
        for binding in preset.get("bindings").and_then(Value::as_array).expect("bindings") {
            for field in PLATFORM_FIELDS {
                let Some(written) = text(binding, field) else {
                    continue;
                };
                let chord = Chord::parse(written).expect("a chord");
                assert_eq!(chord.to_string(), written, "{id} {field}");
                assert!(!chord.cmd || field == "mac", "{id} {field} {written}");
            }
        }
    }
}

#[test]
fn derived_marks_only_a_row_with_a_side_other_than_mac() {
    for preset in raw_presets() {
        let id = text(&preset, "id").expect("an id");
        for binding in preset.get("bindings").and_then(Value::as_array).expect("bindings") {
            if binding.get("derived").and_then(Value::as_bool) == Some(true) {
                assert!(
                    ["key", "linux", "windows"]
                        .iter()
                        .any(|field| text(binding, field).is_some()),
                    "{id} {binding}"
                );
            }
            assert!(
                PLATFORM_FIELDS.iter().any(|field| text(binding, field).is_some()),
                "{id} has a row with no key: {binding}"
            );
        }
    }
}

#[test]
fn mac_falls_back_to_key_and_linux_and_windows_take_their_own_first() {
    let keymap = Keymap::parse(
        r#"{"schemaVersion": 1, "presets": [{"id": "dbeaver", "name": "DBeaver",
            "platforms": ["macos", "linux", "windows"], "bindings": [
              {"action": "formatQuery", "key": "ctrl+shift+f"},
              {"action": "executeQuery", "key": "ctrl+enter", "mac": "cmd+enter"},
              {"action": "findAndReplace", "mac": "alt+cmd+f", "linux": "ctrl+h"},
              {"action": "executeAllStatements", "linux": "ctrl+shift+enter", "windows": "ctrl+shift+enter"},
              {"action": "discardChanges", "key": "ctrl+r", "derived": true}
            ]}]}"#,
    )
    .expect("a keymap");
    let rows = |platform| -> Vec<(KeymapAction, String, bool)> {
        keymap
            .preset("dbeaver", platform)
            .expect("a preset")
            .into_iter()
            .map(|binding| (binding.action, binding.chord.to_string(), binding.derived))
            .collect()
    };

    assert_eq!(
        rows(Platform::MacOs),
        [
            (KeymapAction::FormatQuery, "ctrl+shift+f".to_owned(), false),
            (KeymapAction::ExecuteQuery, "cmd+enter".to_owned(), false),
            (KeymapAction::FindAndReplace, "alt+cmd+f".to_owned(), false),
        ]
    );
    assert_eq!(
        rows(Platform::Linux),
        [
            (KeymapAction::FormatQuery, "ctrl+shift+f".to_owned(), false),
            (KeymapAction::ExecuteQuery, "ctrl+enter".to_owned(), false),
            (KeymapAction::FindAndReplace, "ctrl+h".to_owned(), false),
            (KeymapAction::ExecuteAllStatements, "ctrl+shift+enter".to_owned(), false),
            (KeymapAction::DiscardChanges, "ctrl+r".to_owned(), true),
        ]
    );
    assert_eq!(
        rows(Platform::Windows),
        [
            (KeymapAction::FormatQuery, "ctrl+shift+f".to_owned(), false),
            (KeymapAction::ExecuteQuery, "ctrl+enter".to_owned(), false),
            (KeymapAction::ExecuteAllStatements, "ctrl+shift+enter".to_owned(), false),
            (KeymapAction::DiscardChanges, "ctrl+r".to_owned(), true),
        ]
    );
}

#[test]
fn a_preset_lists_only_where_its_app_runs() {
    assert_eq!(
        keymap::preset_ids(Platform::Linux).expect("ids"),
        ["tableplus", "dbeaver", "datagrip", "beekeeperstudio", "navicat", "dbx"]
    );
    assert_eq!(keymap::preset_ids(Platform::MacOs).expect("ids").len(), 7);
    let refused = keymap::preset("sequelace", Platform::Windows).expect_err("refused");
    assert_eq!(refused.code(), "keymap.not_on_platform");
    let unknown = keymap::preset("tablepro", Platform::MacOs).expect_err("refused");
    assert_eq!(unknown.code(), "keymap.unknown_preset");
}

#[test]
fn the_decided_rows_are_in_the_file() {
    let chord = |id: &str, platform, action| {
        keymap::preset(id, platform)
            .expect("a preset")
            .into_iter()
            .find(|binding| binding.action == action)
            .map(|binding| binding.chord.to_string())
    };
    // One source key on two commands: the editor command keeps it.
    assert_eq!(
        chord("tableplus", Platform::MacOs, KeymapAction::Find).as_deref(),
        Some("cmd+f")
    );
    assert_eq!(chord("tableplus", Platform::MacOs, KeymapAction::ToggleFilters), None);
    assert_eq!(
        chord("tableplus", Platform::MacOs, KeymapAction::FormatQuery).as_deref(),
        Some("cmd+i")
    );
    assert_eq!(chord("tableplus", Platform::MacOs, KeymapAction::AddRow), None);
    assert_eq!(
        chord("sequelace", Platform::MacOs, KeymapAction::ExecuteQuery).as_deref(),
        Some("cmd+r")
    );
    assert_eq!(chord("sequelace", Platform::MacOs, KeymapAction::Refresh), None);
    // The source's one New key is also its new data source command, so New Connection keeps its default there.
    assert_eq!(chord("datagrip", Platform::MacOs, KeymapAction::AddRow), None);
    assert_eq!(
        chord("datagrip", Platform::Linux, KeymapAction::AddRow).as_deref(),
        Some("alt+insert")
    );
    // Run all where the source's own key is refused or missing.
    for id in ["dbeaver", "datagrip", "dbx"] {
        for platform in [Platform::Linux, Platform::Windows] {
            assert_eq!(
                chord(id, platform, KeymapAction::ExecuteAllStatements).as_deref(),
                Some("ctrl+shift+enter"),
                "{id} {platform:?}"
            );
        }
        assert_eq!(
            chord(id, Platform::MacOs, KeymapAction::ExecuteAllStatements),
            None,
            "{id}"
        );
    }
    // DBeaver's macOS Control chords stay Control.
    assert_eq!(
        chord("dbeaver", Platform::MacOs, KeymapAction::FormatQuery).as_deref(),
        Some("ctrl+shift+f")
    );
    // TablePlus publishes only its macOS keys; the others are Cmd read as Ctrl.
    let tableplus = keymap::preset("tableplus", Platform::Windows).expect("a preset");
    assert!(tableplus.iter().all(|binding| binding.derived));
    let mac = keymap::preset("tableplus", Platform::MacOs).expect("a preset");
    assert!(mac.iter().all(|binding| !binding.derived));
}

#[test]
fn the_two_actions_without_a_macos_command_have_no_binding_there() {
    for summary in keymap::presets().expect("presets") {
        if !summary.platforms.contains(&Platform::MacOs) {
            continue;
        }
        for binding in keymap::preset(&summary.id, Platform::MacOs).expect("a preset") {
            assert!(
                binding.action.has_macos_action(),
                "{} {}",
                summary.id,
                binding.action.as_str()
            );
        }
    }
    assert!(!KeymapAction::DiscardChanges.has_macos_action());
    assert!(!KeymapAction::ShowSettings.has_macos_action());
    assert!(KeymapAction::CommitTransaction.has_macos_action());
}

#[test]
fn every_action_name_round_trips() {
    for action in KeymapAction::ALL {
        assert_eq!(KeymapAction::from_name(action.as_str()), Some(action));
    }
    assert_eq!(KeymapAction::from_name("toggleComment"), None);
}

#[test]
fn chords_parse_in_any_modifier_order_and_print_in_one() {
    let chord = Chord::parse("cmd+alt+shift+ctrl+f").expect("a chord");
    assert_eq!(chord.to_string(), "ctrl+shift+alt+cmd+f");
    assert!(Chord::parse("f19").expect("a chord").is_function_key());
    assert!(!Chord::parse("ctrl+f").expect("a chord").is_function_key());
    assert!(!Chord::parse("ctrl+f20").is_ok_and(|chord| chord.is_function_key()));
    for refused in [
        "",
        "ctrl+",
        "+",
        "ctrl+ctrl+a",
        "meta+a",
        "ctrl+F",
        "ctrl+plus",
        "ctrl+a+b",
        "ctrl+f20",
        "cmd++",
    ] {
        let error = Chord::parse(refused).err();
        assert_eq!(
            error.map(|error| error.code()),
            Some("keymap.invalid_chord"),
            "{refused:?}"
        );
    }
    for accepted in [
        "ctrl+`",
        "ctrl+\\",
        "alt+'",
        "shift+cmd+=",
        "ctrl+pageup",
        "ctrl+shift+backspace",
        "alt+insert",
    ] {
        assert!(Chord::parse(accepted).is_ok(), "{accepted}");
    }
}

#[test]
fn a_file_the_parser_cannot_read_is_refused_with_its_code() {
    assert!(matches!(
        parse_error(r#"{"schemaVersion": 2, "presets": [], "future": true}"#),
        KeymapError::UnsupportedSchema(2)
    ));
    assert_eq!(parse_error("{").code(), "keymap.malformed");
    assert_eq!(
        parse_error(r#"{"schemaVersion": 1, "presets": [], "extra": 1}"#).code(),
        "keymap.malformed"
    );
    let unknown_action = r#"{"schemaVersion": 1, "presets": [{"id": "dbx", "name": "DBX", "platforms": ["linux"],
        "bindings": [{"action": "toggleComment", "key": "ctrl+/"}]}]}"#;
    assert_eq!(parse_error(unknown_action).code(), "keymap.malformed");
    let bad_chord = r#"{"schemaVersion": 1, "presets": [{"id": "dbx", "name": "DBX", "platforms": ["linux"],
        "bindings": [{"action": "find", "key": "ctrl+fn"}]}]}"#;
    match parse_error(bad_chord) {
        KeymapError::InvalidChord { preset, action, chord } => {
            assert_eq!(
                (preset.as_str(), action.as_str(), chord.as_str()),
                ("dbx", "find", "ctrl+fn")
            );
        }
        other => panic!("expected an invalid chord, got {other:?}"),
    }
    let cmd_off_mac = r#"{"schemaVersion": 1, "presets": [{"id": "dbx", "name": "DBX", "platforms": ["linux"],
        "bindings": [{"action": "find", "key": "cmd+f"}]}]}"#;
    assert_eq!(parse_error(cmd_off_mac).code(), "keymap.invalid_chord");
    let twice = r#"{"schemaVersion": 1, "presets": [
        {"id": "dbx", "name": "DBX", "platforms": ["linux"], "bindings": []},
        {"id": "dbx", "name": "DBX", "platforms": ["linux"], "bindings": []}]}"#;
    assert!(matches!(parse_error(twice), KeymapError::DuplicatePreset(id) if id == "dbx"));
}
