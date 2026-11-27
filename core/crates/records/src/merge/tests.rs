use serde::Deserialize;
use serde_json::{Value, json};

use super::*;
use crate::cloudkit::{from_wire, record_name, to_wire};

#[derive(Deserialize)]
struct Case {
    name: String,
    kind: String,
    mode: String,
    base: Option<Value>,
    local: Option<Value>,
    server: Option<Value>,
    merged: Value,
}

fn cases() -> Vec<Case> {
    serde_json::from_str(include_str!("../../fixtures/merge.json")).expect("the fixtures")
}

fn expected(case: &Case) -> Merged {
    match &case.merged {
        Value::String(word) if word == "deleted" => Merged::Deleted,
        other => {
            if let Some(record) = other.get("record") {
                return Merged::Record(record.clone());
            }
            if let Some(contested) = other.get("contested") {
                let fields = contested["fields"]
                    .as_array()
                    .expect("fields")
                    .iter()
                    .map(|field| field.as_str().expect("a name").to_owned())
                    .collect();
                return Merged::Contested {
                    record: contested["record"].clone(),
                    fields,
                };
            }
            let deletion = &other["deletion_contested"];
            Merged::DeletionContested {
                kept: deletion["kept"].clone(),
                deleted_here: deletion["deleted_here"] == json!(true),
            }
        }
    }
}

fn run(case: &Case, base: Option<&Value>, local: Option<&Value>, server: Option<&Value>) -> Merged {
    let kind = Kind::parse(&case.kind).expect("a kind").expect("a known kind");
    let mode = if case.mode == "team" {
        Mode::Team
    } else {
        Mode::Personal
    };
    merge(kind, mode, Sides { base, local, server })
}

#[test]
fn the_shared_fixtures_merge_as_written() {
    let cases = cases();
    assert!(cases.len() >= 15);
    for case in &cases {
        let merged = run(case, case.base.as_ref(), case.local.as_ref(), case.server.as_ref());
        assert_eq!(merged, expected(case), "{}", case.name);
    }
}

// The device that merged pushes its result; the other then holds that result as server copy and converges on it.
#[test]
fn the_shared_fixtures_converge_on_the_other_device() {
    for case in cases().iter().filter(|case| case.mode == "personal") {
        let Merged::Record(result) = run(case, case.base.as_ref(), case.local.as_ref(), case.server.as_ref()) else {
            continue;
        };
        let again = run(case, case.server.as_ref(), case.server.as_ref(), Some(&result));
        assert_eq!(again, Merged::Record(result), "{}", case.name);
    }
}

// The same fixtures on the CloudKit path: each copy goes to CloudKit fields and back before the merge.
#[test]
fn the_shared_fixtures_merge_the_same_after_a_trip_through_cloudkit() {
    let through = |kind: Kind, id: &str, fields: Option<&Value>| -> Option<Value> {
        let fields = fields?;
        let saved = from_wire(kind, id, fields, 1_700_000_000_000).expect("writes")?;
        let cloud: crate::cloudkit::CloudFields = saved
            .into_iter()
            .filter_map(|(name, value)| Some((name.to_owned(), value?)))
            .collect();
        let record_type = crate::cloudkit::record_type_of(kind)?;
        let name = record_name(kind, id)?;
        let mut wire = to_wire(record_type.name, &name, &cloud)
            .expect("the record reads back")
            .fields;
        if let (Value::Object(read), Value::Object(sent)) = (&mut wire, fields) {
            read.retain(|key, _| sent.contains_key(key));
        }
        Some(wire)
    };
    for case in cases().iter().filter(|case| case.mode == "personal") {
        let kind = Kind::parse(&case.kind).expect("a kind").expect("a known kind");
        let id = match kind {
            Kind::FavouriteTable => {
                crate::record_id::favourite_table(uuid::Uuid::nil(), Some("shop"), None, "orders").id
            }
            Kind::MacosSettings => case
                .local
                .as_ref()
                .or(case.base.as_ref())
                .and_then(|copy| copy.get("category"))
                .and_then(Value::as_str)
                .expect("a category")
                .to_owned(),
            _ => "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44".to_owned(),
        };
        let unknown = |copy: &Option<Value>| {
            copy.as_ref()
                .is_some_and(|copy| copy.get("future").is_some() || copy.get("from_a_newer_build").is_some())
        };
        if unknown(&case.base) || unknown(&case.server) {
            // CloudKit keeps a member this build does not know on its own copy; the projection does not carry it.
            continue;
        }
        let (base, local, server) = (
            through(kind, &id, case.base.as_ref()),
            through(kind, &id, case.local.as_ref()),
            through(kind, &id, case.server.as_ref()),
        );
        let merged = run(case, base.as_ref(), local.as_ref(), server.as_ref());
        assert_eq!(merged, expected(case), "{}", case.name);
    }
}

#[test]
fn a_content_change_is_any_change_outside_placement() {
    let connection = schema(Kind::Connection);
    let base = json!({"name": "a", "sort_order": 1, "schema_version": 1});

    assert!(!changes_content(
        &connection,
        &base,
        &json!({"name": "a", "sort_order": 2, "schema_version": 2})
    ));
    assert!(changes_content(
        &connection,
        &base,
        &json!({"name": "b", "sort_order": 1, "schema_version": 1})
    ));
    assert!(changes_content(
        &connection,
        &base,
        &json!({"name": "a", "sort_order": 1, "schema_version": 1, "x": 1})
    ));
    assert!(changes_content(
        &connection,
        &base,
        &json!({"sort_order": 1, "schema_version": 1})
    ));
}

// A secret edited here while another device rotated the key: the fields never mix (0051, Conflict rules).
#[test]
fn an_envelope_changed_here_is_sealed_again_rather_than_merged() {
    let base = json!({"suite": "tp1", "kv": 1, "nonce": "AAAA", "ct": "BBBB"});
    let local = json!({"suite": "tp1", "kv": 1, "nonce": "CCCC", "ct": "DDDD"});
    let rotated = json!({"suite": "tp1", "kv": 2, "nonce": "EEEE", "ct": "FFFF"});
    let sides = |base, local, server| Sides { base, local, server };

    assert_eq!(
        merge(
            Kind::SecretEnvelope,
            Mode::Personal,
            sides(Some(&base), Some(&local), Some(&rotated))
        ),
        Merged::Reseal
    );
    assert_eq!(
        merge(Kind::SecretEnvelope, Mode::Team, sides(Some(&base), Some(&local), None)),
        Merged::Reseal
    );
    assert_eq!(
        merge(
            Kind::SecretEnvelope,
            Mode::Personal,
            sides(Some(&base), Some(&base), Some(&rotated))
        ),
        Merged::Record(rotated.clone())
    );
    assert_eq!(
        merge(
            Kind::SecretEnvelope,
            Mode::Personal,
            sides(Some(&base), Some(&base), None)
        ),
        Merged::Deleted
    );
    assert_eq!(
        merge(
            Kind::SecretEnvelope,
            Mode::Personal,
            sides(Some(&base), None, Some(&rotated))
        ),
        Merged::Deleted
    );
    assert_eq!(
        merge(Kind::SecretEnvelope, Mode::Personal, sides(None, Some(&local), None)),
        Merged::Reseal
    );
}

#[test]
fn a_history_entry_or_key_object_keeps_the_stored_copy() {
    let stored = json!({"suite": "tp1", "kv": 2, "nonce": "AAAA", "ct": "BBBB"});
    let mine = json!({"suite": "tp1", "kv": 2, "nonce": "CCCC", "ct": "DDDD"});
    for kind in [Kind::HistoryEntry, Kind::KeyVersion] {
        let sides = |base, local, server| Sides { base, local, server };
        assert_eq!(
            merge(kind, Mode::Personal, sides(None, Some(&mine), Some(&stored))),
            Merged::Record(stored.clone())
        );
        assert_eq!(
            merge(kind, Mode::Personal, sides(None, Some(&mine), None)),
            Merged::Record(mine.clone())
        );
        assert_eq!(
            merge(kind, Mode::Personal, sides(Some(&stored), Some(&stored), None)),
            Merged::Deleted
        );
    }
}

// A later mover meets a copy another device moved: what the marker names is the base, by digest.
#[test]
fn against_a_marker_each_side_keeps_what_it_changed_from_the_marked_copy() {
    let moved = json!({"name": "Prod", "icon_name": "database", "sort_order": 1});
    let marker = MoveMarker::of(&moved, b"tag");
    let local = json!({"name": "Prod (iCloud)", "icon_name": "database", "sort_order": 1});
    let server = json!({"name": "Prod", "icon_name": "server", "sort_order": 1});
    let both = json!({"name": "Mine", "icon_name": "database", "sort_order": 1});
    let theirs = json!({"name": "Theirs", "icon_name": "database", "sort_order": 1});

    assert_eq!(
        merge_against_marker(Kind::Connection, Mode::Personal, &marker, Some(&local), Some(&server)),
        Merged::Record(json!({"name": "Prod (iCloud)", "icon_name": "server", "sort_order": 1}))
    );
    assert_eq!(
        merge_against_marker(Kind::Connection, Mode::Personal, &marker, Some(&both), Some(&theirs)),
        Merged::Record(both.clone())
    );
}

// A record a device on iCloud deleted after the move goes, unless the service copy's content changed since; a reorder
// alone never keeps it.
#[test]
fn against_a_marker_a_deletion_stands_unless_the_content_changed_since_the_move() {
    let moved = json!({"name": "Prod", "sort_order": 1});
    let marker = MoveMarker::of(&moved, b"tag");
    let reordered = json!({"name": "Prod", "sort_order": 4});
    let edited = json!({"name": "Prod 2", "sort_order": 1});

    assert_eq!(
        merge_against_marker(Kind::Connection, Mode::Personal, &marker, None, Some(&moved)),
        Merged::Deleted
    );
    assert_eq!(
        merge_against_marker(Kind::Connection, Mode::Personal, &marker, None, Some(&reordered)),
        Merged::Deleted
    );
    assert_eq!(
        merge_against_marker(Kind::Connection, Mode::Personal, &marker, None, Some(&edited)),
        Merged::Record(edited.clone())
    );
}

#[test]
fn against_a_marker_a_settings_document_merges_whole() {
    let moved = json!({"category": "editor", "options": {"fontSize": 12, "tabWidth": 4}});
    let marker = MoveMarker::of(&moved, b"tag");
    let local = json!({"category": "editor", "options": {"fontSize": 14, "tabWidth": 4}});
    let server = json!({"category": "editor", "options": {"fontSize": 12, "tabWidth": 2}});

    assert_eq!(
        merge_against_marker(
            Kind::MacosSettings,
            Mode::Personal,
            &marker,
            Some(&local),
            Some(&server)
        ),
        Merged::Record(local.clone())
    );
}
