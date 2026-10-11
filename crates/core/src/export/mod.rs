//! Streaming export helpers. Every text format writes row-by-row without
//! holding a second copy of the result set.

#[cfg(test)]
use std::fs;
use std::io::{self, BufWriter, Write};
use std::path::Path;

use crate::query::Value;

mod csv;
mod error;
mod file;
mod html;
mod in_clause;
mod json;
mod markdown;
mod paged;
mod sql;
mod xlsx;
mod xml;

pub use csv::{
    CsvDecimal, CsvDelimiter, CsvLineBreak, CsvOptions, CsvQuote, render_csv, render_tsv, unique_csv_null_marker,
    write_csv_header, write_csv_header_with_options, write_csv_row, write_csv_row_with_columns_and_options,
    write_csv_row_with_options,
};
pub use error::ExportError;
pub use file::{ResultExport, ResultFormat, SqlTarget, write_result_file};
pub use in_clause::{InClause, render_in_clause};
pub use json::{json_field_names, render_json, row_to_json};
pub use markdown::render_markdown;
pub use paged::{RowPage, write_paged_file};
pub use xlsx::MAX_WORKBOOK_ROWS;

pub(crate) fn value_to_text(value: &Value) -> Option<String> {
    match value {
        Value::Null => None,
        Value::Bool(value) => Some(value.to_string()),
        Value::Int(value) => Some(value.to_string()),
        Value::Float(value) => Some(value.to_string()),
        Value::Text(value) => Some(value.clone()),
        Value::Bytes(value) => Some(format!("\\x{}", hex_encode(value))),
        Value::Date(value) => Some(value.to_string()),
        Value::Time(value) => Some(value.to_string()),
        Value::DateTime(value) => Some(value.to_string()),
        Value::TimestampTz(value) => Some(value.to_rfc3339()),
        Value::Decimal(value) => Some(value.to_string()),
        Value::Uuid(value) => Some(value.to_string()),
        Value::Json(value) => Some(value.to_string()),
        Value::Undecodable(type_name) => Some(undecodable_marker(type_name)),
    }
}

fn undecodable_marker(type_name: &str) -> String {
    format!("<undecodable {type_name}>")
}

pub(crate) fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn supports_sql_literals(driver_id: &str) -> bool {
    matches!(
        driver_id,
        "postgres" | "mysql" | "sqlite" | "mssql" | "clickhouse" | "duckdb"
    )
}

/// Write `path` so a reader never observes a half-written export. The
/// content goes to a sibling temporary file, is flushed and synced, then
/// renamed over the destination, which is atomic within a filesystem.
/// Writing straight to the destination meant another process could open
/// the file after the header and a few rows had reached the disk and read
/// a truncated export.
pub fn write_atomically<F>(path: &Path, fill: F) -> io::Result<()>
where
    F: FnOnce(&mut dyn Write) -> io::Result<()>,
{
    write_atomically_checked(path, fill, || Ok(()))
}

pub(crate) fn write_atomically_checked<E, F>(
    path: &Path,
    fill: F,
    before_publish: impl FnOnce() -> Result<(), E>,
) -> Result<(), E>
where
    E: From<io::Error>,
    F: FnOnce(&mut dyn Write) -> Result<(), E>,
{
    let directory = match path.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        Some(parent) => parent,
        None => Path::new("."),
    };
    let mut temporary = tempfile::Builder::new()
        .prefix(".tablepro-export-")
        .tempfile_in(directory)?;
    {
        let mut writer = BufWriter::new(temporary.as_file_mut());
        fill(&mut writer)?;
        writer.flush()?;
    }
    temporary.as_file().sync_all()?;
    before_publish()?;
    temporary.persist(path).map_err(|error| error.error)?;
    Ok(())
}

#[cfg(test)]
pub(crate) mod test_support {
    use crate::query::ColumnInfo;

    pub(crate) fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }
}

#[cfg(test)]
mod atomic_write_tests {
    use super::*;

    #[test]
    fn overlapping_exports_publish_complete_independent_files() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("page.csv");
        fs::write(&path, "original").expect("existing export");

        write_atomically(&path, |outer| {
            outer.write_all(b"outer export")?;
            write_atomically(&path, |inner| inner.write_all(b"inner"))?;
            assert_eq!(fs::read_to_string(&path)?, "inner");
            Ok(())
        })
        .expect("both exports complete");

        assert_eq!(fs::read_to_string(&path).expect("read export"), "outer export");
        assert_eq!(fs::read_dir(directory.path()).expect("list").count(), 1);
    }

    #[test]
    fn a_failed_export_preserves_an_existing_destination() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("page.csv");
        fs::write(&path, "original").expect("existing export");
        assert!(
            write_atomically(&path, |writer| {
                writer.write_all(b"replacement")?;
                Err(io::Error::other("export failed"))
            })
            .is_err()
        );
        assert_eq!(fs::read_to_string(&path).expect("read export"), "original");
        assert_eq!(fs::read_dir(directory.path()).expect("list").count(), 1);
    }

    #[test]
    fn export_staging_stays_on_the_destination_filesystem() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("page.csv");
        write_atomically(&path, |writer| {
            // Atomic rename requires staging beside the destination, even
            // when the destination is on a different mount from the cwd.
            assert_eq!(fs::read_dir(directory.path())?.count(), 1);
            assert!(!path.exists());
            writer.write_all(b"complete export")
        })
        .expect("export");
        assert_eq!(fs::read_to_string(path).expect("read export"), "complete export");
    }

    #[cfg(unix)]
    #[test]
    fn an_existing_temporary_symlink_cannot_redirect_an_export() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("page.csv");
        let unrelated = directory.path().join("unrelated.txt");
        fs::write(&unrelated, "keep me").expect("unrelated file");
        std::os::unix::fs::symlink(&unrelated, directory.path().join("page.csv.tablepro-part"))
            .expect("preexisting symlink");

        write_atomically(&path, |writer| writer.write_all(b"export")).expect("export");

        assert_eq!(fs::read_to_string(&unrelated).expect("unrelated file"), "keep me");
        assert_eq!(fs::read_to_string(&path).expect("export file"), "export");
        assert!(!path.is_symlink());
    }

    #[test]
    fn a_completed_write_lands_at_the_destination_and_leaves_no_leftovers() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("page.csv");

        write_atomically(&path, |writer| writer.write_all(b"id\n1\n2\n")).expect("write the export");

        assert_eq!(fs::read_to_string(&path).expect("read back"), "id\n1\n2\n");
        assert_eq!(
            fs::read_dir(directory.path()).expect("list").count(),
            1,
            "the temporary file must not survive"
        );
    }

    #[test]
    fn the_destination_never_exists_while_the_export_is_still_being_written() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("page.csv");
        let observed = std::cell::Cell::new(false);

        write_atomically(&path, |writer| {
            writer.write_all(b"id\n")?;
            for row in 0..500 {
                writeln!(writer, "{row}")?;
            }
            observed.set(path.exists());
            Ok(())
        })
        .expect("write the export");

        assert!(
            !observed.get(),
            "a reader must not be able to open a partially written export"
        );
        assert!(path.exists(), "the finished export must exist");
    }

    #[test]
    fn a_failed_write_leaves_neither_the_destination_nor_a_temporary_file() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("page.csv");

        let error = write_atomically(&path, |writer| {
            writer.write_all(b"id\n")?;
            Err(io::Error::other("driver stopped mid-export"))
        })
        .expect_err("the failure must be reported");

        assert_eq!(error.to_string(), "driver stopped mid-export");
        assert!(!path.exists(), "a failed export must not leave a destination file");
        assert_eq!(
            fs::read_dir(directory.path()).expect("list").count(),
            0,
            "a failed export must not leave a temporary file"
        );
    }

    #[test]
    fn a_second_export_replaces_the_first_without_a_partial_state() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("page.csv");

        write_atomically(&path, |writer| writer.write_all(b"first")).expect("first export");
        write_atomically(&path, |writer| writer.write_all(b"second")).expect("second export");

        assert_eq!(fs::read_to_string(&path).expect("read back"), "second");
        assert_eq!(fs::read_dir(directory.path()).expect("list").count(), 1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_undecodable_value_renders_as_a_visible_marker_not_an_empty_null() {
        let value = Value::Undecodable("NUMERIC".into());
        assert_eq!(value_to_text(&value), Some("<undecodable NUMERIC>".into()));
    }

    #[test]
    fn exported_bytes_are_complete_zero_padded_hex() {
        assert_eq!(value_to_text(&Value::Bytes(Vec::new())), Some("\\x".into()));
        assert_eq!(
            value_to_text(&Value::Bytes(vec![0x00, 0x0f, 0xf0, 0xff])),
            Some("\\x000ff0ff".into())
        );
        let blob: Vec<u8> = (0..=255u8).cycle().take(100_001).collect();
        let text = value_to_text(&Value::Bytes(blob.clone())).unwrap();
        assert_eq!(text.len(), 2 + 2 * blob.len());
        let decoded: Vec<u8> = text.as_bytes()[2..]
            .chunks(2)
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
            .collect();
        assert_eq!(decoded, blob);
    }

    #[test]
    fn value_to_text_preserves_non_json_value_representations() {
        assert_eq!(value_to_text(&Value::Bytes(vec![0xde, 0xad])), Some("\\xdead".into()));
        assert_eq!(value_to_text(&Value::Null), None);
        assert_eq!(
            value_to_text(&Value::Json(serde_json::json!({"a": 1}))),
            Some("{\"a\":1}".into())
        );
    }
}
