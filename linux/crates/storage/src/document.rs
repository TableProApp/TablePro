use std::path::Path;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::document_problem::{DocumentProblem, DocumentProblemKind};

/// One step of a document's upgrade chain: a file at one version
/// rewritten into the shape of the next. Its `version` field is left for
/// the step to ignore, since the result is read without it. An `Err`
/// says what the step could not read. Object keys come out sorted, so a
/// document keeps anything ordered in arrays.
pub type Upgrade = fn(Value) -> Result<Value, String>;

/// A JSON document the app owns, carrying its own version.
pub trait VersionedDocument: Serialize + DeserializeOwned {
    const KIND: &'static str;
    const VERSION: u32;
    /// The steps that bring an older file up to `VERSION`, oldest first:
    /// the last turns `VERSION - 1` into `VERSION`, the one before it
    /// `VERSION - 2` into `VERSION - 1`. A file older than the first step
    /// is refused. A user can skip any number of releases, so a format
    /// bump appends a step and never drops one.
    const UPGRADES: &'static [Upgrade] = &[];
}

#[derive(serde::Deserialize)]
struct VersionProbe {
    version: Option<u32>,
}

/// Read the version first, so a file from a newer build is reported as
/// such instead of as a parse failure listing every unknown field.
pub fn decode_document<D: VersionedDocument>(path: &Path, bytes: &[u8]) -> Result<D, DocumentProblem> {
    let probe: VersionProbe = serde_json::from_slice(bytes).map_err(|error| corrupt(path, &error))?;
    let Some(version) = probe.version else {
        return Err(DocumentProblem::new(path, DocumentProblemKind::MissingVersion));
    };
    if version > D::VERSION {
        return Err(DocumentProblem::new(
            path,
            DocumentProblemKind::NewerVersion {
                found: version,
                expected: D::VERSION,
            },
        ));
    }
    if version < D::VERSION {
        return upgrade(path, version, bytes);
    }
    serde_json::from_slice(bytes).map_err(|error| corrupt(path, &error))
}

/// Runs the file through the steps it is behind, then reads the result
/// as the current version. The file on disk is left as it is: the next
/// save writes the current version.
fn upgrade<D: VersionedDocument>(path: &Path, found: u32, bytes: &[u8]) -> Result<D, DocumentProblem> {
    let unsupported = || {
        DocumentProblem::new(
            path,
            DocumentProblemKind::UnsupportedVersion {
                found,
                expected: D::VERSION,
            },
        )
    };
    let behind = usize::try_from(D::VERSION - found).map_err(|_| unsupported())?;
    let Some(first) = D::UPGRADES.len().checked_sub(behind) else {
        return Err(unsupported());
    };
    let failed = |detail: String| {
        DocumentProblem::new(
            path,
            DocumentProblemKind::UpgradeFailed {
                found,
                expected: D::VERSION,
                detail,
            },
        )
    };
    let mut document: Value = serde_json::from_slice(bytes).map_err(|error| corrupt(path, &error))?;
    for step in D::UPGRADES.iter().skip(first) {
        document = step(document).map_err(failed)?;
    }
    serde_json::from_value(document).map_err(|error| failed(error.to_string()))
}

fn corrupt(path: &Path, error: &serde_json::Error) -> DocumentProblem {
    DocumentProblem::new(
        path,
        DocumentProblemKind::Corrupt {
            detail: error.to_string(),
            line: error.line(),
            column: error.column(),
        },
    )
}

pub fn encode_document<D: VersionedDocument>(document: &D) -> Result<Vec<u8>, serde_json::Error> {
    #[derive(Serialize)]
    struct Versioned<'a, D> {
        version: u32,
        #[serde(flatten)]
        inner: &'a D,
    }

    serde_json::to_vec_pretty(&Versioned {
        version: D::VERSION,
        inner: document,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, PartialEq, Serialize, serde::Deserialize)]
    struct Sample {
        items: Vec<String>,
    }

    impl VersionedDocument for Sample {
        const KIND: &'static str = "sample";
        const VERSION: u32 = 1;
    }

    fn decode(bytes: &str) -> Result<Sample, DocumentProblem> {
        decode_document::<Sample>(Path::new("/tmp/sample.json"), bytes.as_bytes())
    }

    #[test]
    fn round_trips_through_encode() {
        let sample = Sample {
            items: vec!["a".to_owned()],
        };

        let bytes = encode_document(&sample).expect("encode");
        let decoded = decode_document::<Sample>(Path::new("/tmp/sample.json"), &bytes).expect("decode");

        assert_eq!(decoded, sample);
        assert!(String::from_utf8_lossy(&bytes).contains("\"version\": 1"));
    }

    #[test]
    fn missing_version_is_refused() {
        let problem = decode(r#"{"items": []}"#).expect_err("no version");

        assert_eq!(problem.kind, DocumentProblemKind::MissingVersion);
    }

    #[test]
    fn a_newer_version_is_named_as_such() {
        let problem = decode(r#"{"version": 2, "items": []}"#).expect_err("newer");

        assert_eq!(
            problem.kind,
            DocumentProblemKind::NewerVersion { found: 2, expected: 1 }
        );
        assert!(problem.is_newer_version());
    }

    #[test]
    fn an_older_version_is_unsupported() {
        let problem = decode(r#"{"version": 0, "items": []}"#).expect_err("older");

        assert_eq!(
            problem.kind,
            DocumentProblemKind::UnsupportedVersion { found: 0, expected: 1 }
        );
    }

    #[test]
    fn decode_document_reports_line_and_column() {
        let problem = decode("{\n  \"version\": 1,\n  \"items\": [,]\n}").expect_err("corrupt");

        match problem.kind {
            DocumentProblemKind::Corrupt { line, column, .. } => {
                assert_eq!(line, 3);
                assert!(column > 0, "column {column}");
            }
            other => panic!("expected Corrupt, got {other:?}"),
        }
    }

    #[test]
    fn a_valid_version_with_a_bad_body_is_corrupt() {
        let problem = decode(r#"{"version": 1, "items": 5}"#).expect_err("bad body");

        assert!(
            matches!(problem.kind, DocumentProblemKind::Corrupt { .. }),
            "{problem:?}"
        );
    }

    /// Version 1 held `names`, version 2 renamed it to `items`, and
    /// version 3 made each item an object.
    #[derive(Debug, PartialEq, Serialize, serde::Deserialize)]
    struct Shelf {
        items: Vec<ShelfItem>,
    }

    #[derive(Debug, PartialEq, Serialize, serde::Deserialize)]
    struct ShelfItem {
        name: String,
    }

    #[derive(serde::Deserialize)]
    struct ShelfV1 {
        names: Vec<String>,
    }

    /// Its items stay untyped, so a bad one reaches the final read.
    #[derive(Serialize, serde::Deserialize)]
    struct ShelfV2 {
        items: Vec<Value>,
    }

    #[derive(Serialize)]
    struct ShelfV3 {
        items: Vec<ShelfItemV3>,
    }

    #[derive(Serialize)]
    struct ShelfItemV3 {
        name: Value,
    }

    fn rename_names_to_items(document: Value) -> Result<Value, String> {
        let shelf: ShelfV1 = serde_json::from_value(document).map_err(|error| error.to_string())?;
        let items = shelf.names.into_iter().map(Value::String).collect();
        serde_json::to_value(ShelfV2 { items }).map_err(|error| error.to_string())
    }

    fn wrap_items(document: Value) -> Result<Value, String> {
        let shelf: ShelfV2 = serde_json::from_value(document).map_err(|error| error.to_string())?;
        let items = shelf.items.into_iter().map(|name| ShelfItemV3 { name }).collect();
        serde_json::to_value(ShelfV3 { items }).map_err(|error| error.to_string())
    }

    impl VersionedDocument for Shelf {
        const KIND: &'static str = "shelf";
        const VERSION: u32 = 3;
        const UPGRADES: &'static [Upgrade] = &[rename_names_to_items, wrap_items];
    }

    fn shelf(names: &[&str]) -> Shelf {
        Shelf {
            items: names
                .iter()
                .map(|name| ShelfItem {
                    name: (*name).to_owned(),
                })
                .collect(),
        }
    }

    fn decode_shelf(bytes: &str) -> Result<Shelf, DocumentProblem> {
        decode_document::<Shelf>(Path::new("/tmp/shelf.json"), bytes.as_bytes())
    }

    #[test]
    fn a_file_two_versions_behind_runs_both_steps_in_order() {
        let decoded = decode_shelf(r#"{"version": 1, "names": ["a", "b"]}"#).expect("upgraded");

        assert_eq!(decoded, shelf(&["a", "b"]));
    }

    #[test]
    fn a_file_one_version_behind_runs_only_the_last_step() {
        let decoded = decode_shelf(r#"{"version": 2, "items": ["a"]}"#).expect("upgraded");

        assert_eq!(decoded, shelf(&["a"]));
    }

    #[test]
    fn the_current_version_runs_no_step() {
        let decoded = decode_shelf(r#"{"version": 3, "items": [{"name": "a"}]}"#).expect("read");

        assert_eq!(decoded, shelf(&["a"]));
    }

    #[test]
    fn a_file_older_than_the_first_step_is_unsupported() {
        let problem = decode_shelf(r#"{"version": 0, "names": []}"#).expect_err("too old");

        assert_eq!(
            problem.kind,
            DocumentProblemKind::UnsupportedVersion { found: 0, expected: 3 }
        );
    }

    #[test]
    fn a_chain_missing_its_early_steps_refuses_those_versions() {
        #[derive(Debug, Serialize, serde::Deserialize)]
        struct Short {
            items: Vec<ShelfItem>,
        }

        impl VersionedDocument for Short {
            const KIND: &'static str = "short";
            const VERSION: u32 = 3;
            const UPGRADES: &'static [Upgrade] = &[wrap_items];
        }

        let path = Path::new("/tmp/short.json");
        let problem = decode_document::<Short>(path, br#"{"version": 1, "names": ["a"]}"#).expect_err("v1");
        let upgraded = decode_document::<Short>(path, br#"{"version": 2, "items": ["a"]}"#).expect("v2");

        assert_eq!(
            problem.kind,
            DocumentProblemKind::UnsupportedVersion { found: 1, expected: 3 }
        );
        assert_eq!(upgraded.items.len(), 1);
    }

    #[test]
    fn a_step_that_cannot_read_the_body_fails_the_upgrade() {
        let problem = decode_shelf(r#"{"version": 1, "items": []}"#).expect_err("no names");

        match problem.kind {
            DocumentProblemKind::UpgradeFailed {
                found: 1,
                expected: 3,
                detail,
            } => assert!(detail.contains("names"), "{detail}"),
            other => panic!("expected UpgradeFailed, got {other:?}"),
        }
    }

    #[test]
    fn an_upgraded_body_the_current_version_cannot_read_fails_the_upgrade() {
        let problem = decode_shelf(r#"{"version": 2, "items": [5]}"#).expect_err("a number for a name");

        assert!(
            matches!(
                problem.kind,
                DocumentProblemKind::UpgradeFailed {
                    found: 2,
                    expected: 3,
                    ..
                }
            ),
            "{problem:?}"
        );
    }
}
