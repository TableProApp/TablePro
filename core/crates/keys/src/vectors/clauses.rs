// Each row of ADR 0056's negative table names its clauses in its Case cell, split at "; ". Every case
// and every scenario step that answers a row says which clause it answers, so the coverage test sees
// a missing clause and not only a missing row.

use crate::json::JsonValue;

pub(super) fn split(row: &str) -> Vec<&str> {
    row.split("; ").collect()
}

// The rows of more than one clause: which clause a case answers, by file and case name.
fn case_clause(file: &str, row: &str, name: &str) -> Option<usize> {
    const ENCODINGS: [&str; 9] = [
        "a key of 31 bytes",
        "padded base64url",
        "non-zero pad bits",
        "the standard alphabet",
        "signer_av 0",
        "signer_av 2^31",
        "a version of 0 in the id",
        "a version of 2^31 in the id",
        "a version with a leading zero in the id",
    ];
    if row.starts_with("Non-canonical base64url") {
        return Some(match file {
            "encoding.json" => 0,
            "trust.json" | "envelopes.json" => 2,
            _ if ENCODINGS.contains(&name) => 0,
            _ => 1,
        });
    }
    let clause = match name {
        "an av that goes back" | "an av that repeats" => 0,
        "an av that skips" => 1,
        "the certificate under the retired IK verifies a version record signed before the replace" => 1,
        "an envelope below the copy held" => 0,
        "an r_N that does not open c" => 0,
        "a commitment over other keys" => 1,
        "a trust wrap record of one compared pin more: past 1 MiB, nothing to leave out" => 0,
        _ if name.starts_with("alerts and replaced IKs alone pass the limit") => 0,
        _ if name.starts_with("first-use pins with no alert") => 1,
        _ => return None,
    };
    Some(clause)
}

// The scenarios of rows of more than one clause: which clause each step answers; None is a step that
// only sets the scene.
fn step_clause(scenario: &str, step: usize) -> Option<usize> {
    let clauses: &[Option<usize>] = match scenario {
        "a certificate under an IK seen replaced" => &[Some(0)],
        "a stopped device offered a rotation by a holder, and by a non-holder" => &[Some(0), Some(1)],
        "an envelope below the version in force at its place, and one before the rotation" => &[Some(0), Some(1)],
        "a nonce step from a device that is not approved, and a second nonce" => &[None, Some(0), None, Some(1)],
        "an approval built at an av a rotation passed, then again; a replace during a session" => {
            &[Some(0), Some(0), Some(1)]
        }
        "a rotation that keeps a device that is not an own-device pin" => &[Some(0), Some(1)],
        "two genesis change sets, and an identical retry" => &[None, Some(0), Some(1)],
        "a device left out of a rotation" => &[Some(0), Some(1)],
        "a reset while one is pending; kinds from the wrong caller" => &[None, Some(0)],
        "kinds from the wrong caller, with no reset pending" => &[Some(1), Some(1)],
        "a kind 3 proposal while lost devices' rows remain" => &[Some(0), Some(1)],
        "the proposing device signs out" => &[Some(0), Some(1)],
        "activations out of time or from another device" => &[Some(0), Some(1), Some(2)],
        "kind 3 and kind 2 activations" => &[Some(0), Some(1)],
        "a restart shown to a holder, and a restart while a holder is on the roster" => &[Some(0), Some(1)],
        "a restart shown to a device that held an earlier version, then accepted" => &[Some(0), Some(1)],
        "a restart by an account the server made up" => &[Some(0), Some(2)],
        _ => panic!("no clauses listed for the scenario {scenario}"),
    };
    clauses.get(step).copied().flatten()
}

fn member<'a>(value: &'a JsonValue, name: &str) -> Option<&'a JsonValue> {
    match value {
        JsonValue::Object(members) => members
            .iter()
            .find(|(member, _)| member == name)
            .map(|(_, value)| value),
        _ => None,
    }
}

fn text<'a>(value: &'a JsonValue, name: &str) -> Option<&'a str> {
    match member(value, name) {
        Some(JsonValue::String(text)) => Some(text),
        _ => None,
    }
}

fn push(value: &mut JsonValue, name: &str, item: JsonValue) {
    if let JsonValue::Object(members) = value {
        members.push((name.to_owned(), item));
    }
}

// Adds `clause` to every case and scenario step of a file that names a row.
pub(super) fn assign(file: &str, value: &mut JsonValue) {
    let JsonValue::Object(groups) = value else { return };
    for (_, group) in groups.iter_mut() {
        let JsonValue::Array(cases) = group else { continue };
        for case in cases.iter_mut() {
            let (Some(row), Some(name)) = (
                text(case, "row").map(str::to_owned),
                text(case, "name").map(str::to_owned),
            ) else {
                continue;
            };
            let clauses = split(&row);
            if text(case, "op") == Some("scenario") {
                let Some(JsonValue::Array(steps)) = (match case {
                    JsonValue::Object(members) => members
                        .iter_mut()
                        .find(|(member, _)| member == "steps")
                        .map(|(_, value)| value),
                    _ => None,
                }) else {
                    continue;
                };
                for (index, step) in steps.iter_mut().enumerate() {
                    let clause = if clauses.len() == 1 {
                        Some(0)
                    } else {
                        step_clause(&name, index)
                    };
                    if let Some(clause) = clause {
                        push(step, "clause", JsonValue::String(clauses[clause].to_owned()));
                    }
                }
            } else {
                let clause = if clauses.len() == 1 {
                    0
                } else {
                    case_clause(file, &row, &name).unwrap_or_else(|| panic!("{file}: no clause listed for {name}"))
                };
                push(case, "clause", JsonValue::String(clauses[clause].to_owned()));
            }
        }
    }
}
