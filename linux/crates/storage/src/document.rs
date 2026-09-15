use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::document_problem::{DocumentProblem, DocumentProblemKind};

/// A JSON document the app owns, carrying its own version.
///
/// There are no upgraders: the switch is a clean break, so an older
/// version is refused rather than migrated.
pub trait VersionedDocument: Serialize + DeserializeOwned {
    const KIND: &'static str;
    const VERSION: u32;
}

#[derive(serde::Deserialize)]
struct VersionProbe {
    version: Option<u32>,
}

/// Read the version first, so a file from a newer build is reported as
/// such instead of as a parse failure listing every unknown field.
pub fn decode_document<D: VersionedDocument>(path: &std::path::Path, bytes: &[u8]) -> Result<D, DocumentProblem> {
    let probe: VersionProbe = serde_json::from_slice(bytes).map_err(|error| {
        DocumentProblem::new(
            path,
            DocumentProblemKind::Corrupt {
                detail: error.to_string(),
                line: error.line(),
                column: error.column(),
            },
        )
    })?;
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
        return Err(DocumentProblem::new(
            path,
            DocumentProblemKind::UnsupportedVersion {
                found: version,
                expected: D::VERSION,
            },
        ));
    }
    serde_json::from_slice(bytes).map_err(|error| {
        DocumentProblem::new(
            path,
            DocumentProblemKind::Corrupt {
                detail: error.to_string(),
                line: error.line(),
                column: error.column(),
            },
        )
    })
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
    use std::path::Path;

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
}
