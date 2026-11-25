// The vectors in core/crates/keys/vectors (ADR 0056, Vectors): generated here from inputs drawn
// from each case's name, so a run gives the same files; `scripts/update-vectors.sh` writes them.

mod clauses;
mod fixtures;
mod gen_basic;
mod gen_bodies;
mod gen_flows;
mod gen_objects;
mod gen_sas;
mod gen_sealed;
mod out;
mod standard;
mod verify;

use std::path::PathBuf;

use crate::json::JsonValue;

const FILES: [&str; 15] = [
    "encoding.json",
    "recovery.json",
    "certificates.json",
    "scope_keys.json",
    "wraps.json",
    "envelopes.json",
    "history.json",
    "trust.json",
    "sas.json",
    "fingerprint.json",
    "state_mac.json",
    "dpop.json",
    "bodies.json",
    "flows.json",
    "limits.json",
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("vectors")
}

fn committed() -> Vec<(&'static str, Option<JsonValue>)> {
    FILES
        .iter()
        .map(|name| {
            let parsed = std::fs::read(dir().join(name))
                .ok()
                .map(|bytes| crate::json::parse(&bytes).expect("committed vectors parse"));
            (*name, parsed)
        })
        .collect()
}

fn generate() -> Vec<(&'static str, String)> {
    let previous: Vec<JsonValue> = committed().into_iter().filter_map(|(_, value)| value).collect();
    let cache = fixtures::HpkeCache::from_committed(&previous);
    let files = [
        gen_basic::encoding(),
        gen_basic::recovery(),
        gen_objects::certificates(),
        gen_objects::scope_keys(),
        gen_objects::wraps(&cache),
        gen_sealed::envelopes(),
        gen_sealed::history(),
        gen_sealed::trust(),
        gen_sas::sas(),
        gen_basic::fingerprints(),
        gen_basic::state_macs(),
        gen_basic::dpop_proofs(),
        gen_bodies::bodies(),
        gen_flows::flows(&cache),
        gen_sealed::limits(&cache),
    ];
    FILES
        .iter()
        .zip(files)
        .map(|(name, mut value)| {
            clauses::assign(name, &mut value);
            (*name, out::pretty(&value))
        })
        .collect()
}

// Every case in a file: an object with an `op`, in any array of the file.
fn cases(file: &JsonValue) -> Vec<&JsonValue> {
    let mut found = Vec::new();
    if let JsonValue::Object(members) = file {
        for (_, value) in members {
            if let JsonValue::Array(items) = value {
                for item in items {
                    if let JsonValue::Object(fields) = item
                        && fields.iter().any(|(name, _)| name == "op")
                    {
                        found.push(item);
                    }
                }
            }
        }
    }
    found
}

fn op_of(case: &JsonValue) -> String {
    let mut members = crate::json::Members::of(case).expect("case");
    members.string("op").expect("op").to_owned()
}

#[test]
#[ignore = "writes core/crates/keys/vectors; core/crates/keys/scripts/update-vectors.sh runs it"]
fn write_vectors() {
    std::fs::create_dir_all(dir()).expect("vectors directory");
    for (name, text) in generate() {
        std::fs::write(dir().join(name), text).expect("write vectors");
    }
}

#[test]
fn the_vectors_are_what_the_generator_writes() {
    for (name, text) in generate() {
        let committed = std::fs::read_to_string(dir().join(name)).unwrap_or_default();
        assert!(
            committed == text,
            "{name} is stale: run core/crates/keys/scripts/update-vectors.sh"
        );
    }
}

#[test]
fn every_committed_case_holds() {
    let mut count = 0;
    for (name, file) in committed() {
        let file = file.unwrap_or_else(|| panic!("{name} is missing"));
        for case in cases(&file) {
            if op_of(case) == "scenario" {
                gen_flows::check(name, case);
            } else {
                verify::check(name, case);
            }
            count += 1;
        }
    }
    assert!(count > 300, "{count} cases");
}

// Every row of ADR 0056's negative table has a case, and every case names a row of it or an entry
// of its Errors table, in the ADR's own words.
#[test]
fn every_negative_row_of_adr_0056_has_a_case() {
    let adr_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../docs/decisions/0056-end-to-end-keys-per-account-and-device.md");
    let adr = std::fs::read_to_string(adr_path).expect("ADR 0056");
    let start = adr.find("- **Negative.**").expect("the negative table");
    let end = adr[start..].find("- **Go side.**").expect("the end of the table") + start;
    let rows: Vec<String> = adr[start..end]
        .lines()
        .filter(|line| line.starts_with("| ") && !line.starts_with("| Case"))
        .filter_map(|line| {
            line.trim_matches('|')
                .split(" | ")
                .next()
                .map(|cell| cell.trim().to_owned())
        })
        .collect();
    assert!(rows.len() > 80, "{} rows", rows.len());

    // Every clause of every row, by a case or a scenario step that names both; every such case or
    // step says what the server answers.
    let mut named: Vec<(String, String)> = Vec::new();
    let text = |value: &JsonValue, name: &str| match value {
        JsonValue::Object(members) => members
            .iter()
            .find(|(member, _)| member == name)
            .and_then(|(_, value)| match value {
                JsonValue::String(text) => Some(text.clone()),
                _ => None,
            }),
        _ => None,
    };
    let has = |value: &JsonValue, name: &str| matches!(value, JsonValue::Object(members) if members.iter().any(|(member, _)| member == name));
    for (file_name, file) in committed() {
        for case in cases(&file.expect("vectors")) {
            let Some(row) = text(case, "row") else { continue };
            if let JsonValue::Object(members) = case
                && let Some((_, JsonValue::Array(steps))) = members.iter().find(|(name, _)| name == "steps")
            {
                for step in steps {
                    assert!(has(step, "server"), "{file_name}: a step of {row} has no server field");
                    if let Some(clause) = text(step, "clause") {
                        named.push((row.clone(), clause));
                    }
                }
            } else {
                assert!(has(case, "server"), "{file_name}: a case of {row} has no server field");
                named.push((
                    row.clone(),
                    text(case, "clause").unwrap_or_else(|| panic!("{file_name}: a case of {row} has no clause")),
                ));
            }
        }
    }
    for row in &rows {
        for clause in clauses::split(row) {
            assert!(
                named
                    .iter()
                    .any(|(named_row, named_clause)| named_row == row && named_clause == clause),
                "no case for the clause {clause:?} of the row: {row}"
            );
        }
    }
    for (row, _) in &named {
        assert!(
            rows.contains(row) || row.starts_with("Errors table: "),
            "not a row of the table: {row}"
        );
    }
}
