use crate::import::cell::{ColumnKind, parse_cell};
use crate::import::csv_import::{CsvImportOptions, CsvSheet};
use crate::sql_ddl::DraftColumn;
use crate::sql_dialect::MAX_IDENT_BYTES;

/// Rows the type guess reads. A guess from a bounded sample is a guess,
/// which is why the dialog shows it and lets the user change it.
pub const INFER_SAMPLE_ROWS: usize = 200;

/// Narrowest to widest. A field takes the first kind every sampled value
/// fits; text fits everything and is the answer when nothing else does.
const CANDIDATES: [ColumnKind; 7] = [
    ColumnKind::Bool,
    ColumnKind::Int,
    ColumnKind::Decimal,
    ColumnKind::Date,
    ColumnKind::DateTime,
    ColumnKind::TimestampTz,
    ColumnKind::Uuid,
];

/// Guess one draft column per field in the file. Every column is
/// nullable and has no default: an import decides what a table holds, not
/// what it requires.
pub fn infer_columns(sheet: &CsvSheet, options: &CsvImportOptions, driver_id: &str) -> Vec<DraftColumn> {
    let mut names = Vec::with_capacity(sheet.headers.len());
    sheet
        .headers
        .iter()
        .enumerate()
        .map(|(index, header)| {
            let name = unique_name(column_name(header, index), &mut names);
            DraftColumn {
                original: None,
                name,
                data_type: type_name(driver_id, infer_kind(sheet, index, options)).to_owned(),
                nullable: true,
                primary_key: false,
                auto_increment: false,
                default_value: None,
                comment: None,
                collation: None,
            }
        })
        .collect()
}

fn infer_kind(sheet: &CsvSheet, field: usize, options: &CsvImportOptions) -> ColumnKind {
    let sample: Vec<&str> = sheet
        .rows
        .iter()
        .take(INFER_SAMPLE_ROWS)
        .filter_map(|row| row.get(field))
        .map(String::as_str)
        .filter(|text| !text.trim().is_empty() && *text != options.null_marker)
        .collect();
    if sample.is_empty() {
        return ColumnKind::Text;
    }
    CANDIDATES
        .into_iter()
        .find(|kind| sample.iter().all(|text| fits(text, *kind)))
        .unwrap_or(ColumnKind::Text)
}

/// `0` and `1` are both a boolean and a whole number. The value parser
/// takes either because the column already said which it is; a guess has
/// no such column, so here only the written words count as a boolean and
/// a file of ones and zeroes stays a number.
fn fits(text: &str, kind: ColumnKind) -> bool {
    if kind == ColumnKind::Bool {
        return matches!(
            text.trim().to_ascii_lowercase().as_str(),
            "true" | "false" | "t" | "f" | "yes" | "no" | "y" | "n"
        );
    }
    parse_cell(text, kind).is_ok()
}

/// A header is untrusted text. Strip what no identifier may carry, fall
/// back to a positional name when nothing usable is left, and keep it
/// inside the identifier length limit.
fn column_name(header: &str, index: usize) -> String {
    let cleaned: String = header
        .trim()
        .chars()
        .filter(|character| !character.is_control() && *character != '\u{2028}' && *character != '\u{2029}')
        .collect();
    let cleaned = cleaned.trim().to_owned();
    if cleaned.is_empty() {
        return format!("column_{}", index + 1);
    }
    truncate_to(cleaned, MAX_IDENT_BYTES)
}

fn truncate_to(mut name: String, limit: usize) -> String {
    while name.len() > limit {
        name.pop();
    }
    name
}

fn unique_name(name: String, taken: &mut Vec<String>) -> String {
    let mut candidate = name.clone();
    let mut suffix = 2;
    while taken.iter().any(|existing| existing.eq_ignore_ascii_case(&candidate)) {
        let suffix_text = format!("_{suffix}");
        let prefix = truncate_to(name.clone(), MAX_IDENT_BYTES.saturating_sub(suffix_text.len()));
        candidate = format!("{prefix}{suffix_text}");
        suffix += 1;
    }
    taken.push(candidate.clone());
    candidate
}

/// The engine's own spelling for a value shape. Unknown engines take the
/// ANSI-leaning set, which every supported engine parses.
pub fn supports_table_creation(driver_id: &str) -> bool {
    matches!(driver_id, "postgres" | "mysql" | "sqlite" | "mssql" | "duckdb")
}

pub fn type_name(driver_id: &str, kind: ColumnKind) -> &'static str {
    match driver_id {
        "duckdb" if kind == ColumnKind::Json => "JSON",
        "sqlite" => sqlite_type(kind),
        "mysql" => mysql_type(kind),
        "mssql" => mssql_type(kind),
        _ => postgres_type(kind),
    }
}

fn postgres_type(kind: ColumnKind) -> &'static str {
    match kind {
        ColumnKind::Bool => "BOOLEAN",
        ColumnKind::Int => "BIGINT",
        ColumnKind::Float => "DOUBLE PRECISION",
        ColumnKind::Decimal => "NUMERIC",
        ColumnKind::Date => "DATE",
        ColumnKind::Time => "TIME",
        ColumnKind::DateTime => "TIMESTAMP",
        ColumnKind::TimestampTz => "TIMESTAMPTZ",
        ColumnKind::Uuid => "UUID",
        ColumnKind::Json => "JSONB",
        ColumnKind::Bytes => "BYTEA",
        ColumnKind::Text => "TEXT",
    }
}

/// SQLite has no date, time, uuid or boolean storage class; those columns
/// hold the text the file carried and the driver reads them back as text.
fn sqlite_type(kind: ColumnKind) -> &'static str {
    match kind {
        ColumnKind::Bool | ColumnKind::Int => "INTEGER",
        ColumnKind::Float => "REAL",
        ColumnKind::Decimal => "NUMERIC",
        ColumnKind::Bytes => "BLOB",
        _ => "TEXT",
    }
}

fn mysql_type(kind: ColumnKind) -> &'static str {
    match kind {
        ColumnKind::Bool => "BOOLEAN",
        ColumnKind::Int => "BIGINT",
        ColumnKind::Float => "DOUBLE",
        ColumnKind::Decimal => "DECIMAL(38,10)",
        ColumnKind::Date => "DATE",
        ColumnKind::Time => "TIME",
        ColumnKind::DateTime => "DATETIME",
        ColumnKind::TimestampTz => "TIMESTAMP",
        ColumnKind::Uuid => "CHAR(36)",
        ColumnKind::Json => "JSON",
        ColumnKind::Bytes => "BLOB",
        ColumnKind::Text => "TEXT",
    }
}

fn mssql_type(kind: ColumnKind) -> &'static str {
    match kind {
        ColumnKind::Bool => "BIT",
        ColumnKind::Int => "BIGINT",
        ColumnKind::Float => "FLOAT",
        ColumnKind::Decimal => "DECIMAL(38,10)",
        ColumnKind::Date => "DATE",
        ColumnKind::Time => "TIME",
        ColumnKind::DateTime => "DATETIME2",
        ColumnKind::TimestampTz => "DATETIMEOFFSET",
        ColumnKind::Uuid => "UNIQUEIDENTIFIER",
        ColumnKind::Json | ColumnKind::Text => "NVARCHAR(MAX)",
        ColumnKind::Bytes => "VARBINARY(MAX)",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sheet(headers: &[&str], rows: &[&[&str]]) -> CsvSheet {
        CsvSheet {
            headers: headers.iter().map(|header| (*header).to_owned()).collect(),
            rows: rows
                .iter()
                .map(|row| row.iter().map(|cell| (*cell).to_owned()).collect())
                .collect(),
            truncated: false,
        }
    }

    fn inferred(headers: &[&str], rows: &[&[&str]]) -> Vec<DraftColumn> {
        infer_columns(&sheet(headers, rows), &CsvImportOptions::default(), "postgres")
    }

    #[test]
    fn a_field_whose_every_value_is_a_whole_number_is_an_integer() {
        let columns = inferred(&["id"], &[&["1"], &["2"], &["3"]]);

        assert_eq!(columns[0].data_type, "BIGINT");
    }

    #[test]
    fn one_value_that_does_not_fit_widens_the_whole_column_to_text() {
        let columns = inferred(&["id"], &[&["1"], &["2"], &["two"]]);

        assert_eq!(columns[0].data_type, "TEXT");
    }

    /// `0` and `1` round-trip as both a boolean and a number, and a
    /// column of flags-as-numbers read as BOOLEAN would refuse the 2 that
    /// turns up later in the file.
    #[test]
    fn a_field_of_ones_and_zeroes_is_a_number_not_a_boolean() {
        let columns = inferred(&["count"], &[&["0"], &["1"], &["1"]]);

        assert_eq!(columns[0].data_type, "BIGINT");
    }

    #[test]
    fn blank_and_null_marker_cells_do_not_widen_numeric_inference() {
        let options = CsvImportOptions {
            null_marker: "NULL".into(),
            ..Default::default()
        };
        let columns = infer_columns(
            &sheet(&["amount"], &[&["12.30"], &[""], &["NULL"], &["2.50"]]),
            &options,
            "postgres",
        );

        assert_eq!(columns[0].data_type, "NUMERIC");
    }

    #[test]
    fn an_empty_field_is_text_rather_than_a_guess_from_nothing() {
        let columns = inferred(&["note"], &[&[""], &[""]]);

        assert_eq!(columns[0].data_type, "TEXT");
    }

    #[test]
    fn the_narrowest_kind_that_fits_every_value_wins() {
        let columns = inferred(
            &["flag", "amount", "when", "at", "key"],
            &[
                &[
                    "true",
                    "1.50",
                    "2024-05-06",
                    "2024-05-06T13:45:01Z",
                    "8f14e45f-ceea-467a-9c2b-1f0b2c4d5e6a",
                ],
                &[
                    "false",
                    "2.25",
                    "2024-05-07",
                    "2024-05-07T13:45:01Z",
                    "9f14e45f-ceea-467a-9c2b-1f0b2c4d5e6b",
                ],
            ],
        );

        let types: Vec<&str> = columns.iter().map(|column| column.data_type.as_str()).collect();
        assert_eq!(types, vec!["BOOLEAN", "NUMERIC", "DATE", "TIMESTAMPTZ", "UUID"]);
    }

    #[test]
    fn only_the_sample_is_read_so_a_long_file_still_opens_at_once() {
        let mut rows: Vec<Vec<String>> = (0..INFER_SAMPLE_ROWS).map(|_| vec!["1".to_owned()]).collect();
        rows.push(vec!["not a number".to_owned()]);
        let sheet = CsvSheet {
            headers: vec!["id".to_owned()],
            rows,
            truncated: false,
        };

        let columns = infer_columns(&sheet, &CsvImportOptions::default(), "postgres");

        assert_eq!(columns[0].data_type, "BIGINT");
    }

    #[test]
    fn every_engine_gets_a_type_name_it_parses() {
        assert_eq!(type_name("sqlite", ColumnKind::DateTime), "TEXT");
        assert_eq!(type_name("mysql", ColumnKind::Uuid), "CHAR(36)");
        assert_eq!(type_name("mssql", ColumnKind::Text), "NVARCHAR(MAX)");
        assert_eq!(type_name("clickhouse", ColumnKind::Int), "BIGINT");
    }

    #[test]
    fn sqlite_import_types_preserve_storage_affinity_for_numeric_and_binary_kinds() {
        for (kind, expected) in [
            (ColumnKind::Bool, "INTEGER"),
            (ColumnKind::Int, "INTEGER"),
            (ColumnKind::Float, "REAL"),
            (ColumnKind::Decimal, "NUMERIC"),
            (ColumnKind::Bytes, "BLOB"),
        ] {
            assert_eq!(type_name("sqlite", kind), expected, "{kind:?}");
        }
    }

    #[test]
    fn a_header_that_is_not_a_usable_name_gets_a_positional_one() {
        let columns = inferred(&["  ", "na\u{7}me"], &[&["1", "2"]]);

        assert_eq!(columns[0].name, "column_1");
        assert_eq!(columns[1].name, "name");
    }

    #[test]
    fn repeated_headers_do_not_produce_two_columns_with_one_name() {
        let columns = inferred(&["id", "ID", "id"], &[&["1", "2", "3"]]);

        let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
        assert_eq!(names, vec!["id", "ID_2", "id_3"]);
    }

    #[test]
    fn a_header_longer_than_the_identifier_limit_is_cut_to_it() {
        let long = "x".repeat(MAX_IDENT_BYTES + 50);

        let columns = inferred(&[long.as_str()], &[&["1"]]);

        assert_eq!(columns[0].name.len(), MAX_IDENT_BYTES);
    }

    #[test]
    fn repeated_headers_at_the_identifier_limit_keep_a_unique_suffix() {
        let long = "x".repeat(MAX_IDENT_BYTES);
        let columns = infer_columns(
            &sheet(&[long.as_str(), long.as_str()], &[&["1", "2"]]),
            &CsvImportOptions::default(),
            "postgres",
        );

        assert_eq!(columns[0].name.len(), MAX_IDENT_BYTES);
        assert_eq!(columns[1].name.len(), MAX_IDENT_BYTES);
        assert!(columns[1].name.ends_with("_2"));
        assert_ne!(columns[0].name, columns[1].name);
    }

    #[test]
    fn an_inferred_column_never_constrains_what_the_file_can_hold() {
        let columns = inferred(&["id"], &[&["1"]]);

        assert!(columns[0].nullable);
        assert!(!columns[0].primary_key);
        assert!(!columns[0].auto_increment);
        assert_eq!(columns[0].default_value, None);
    }

    #[test]
    fn only_engines_with_plain_create_table_offer_table_creation_from_a_file() {
        for engine in ["postgres", "mysql", "sqlite", "mssql", "duckdb"] {
            assert!(supports_table_creation(engine), "{engine}");
        }
        for engine in ["clickhouse", "mongodb", "redis", "unknown"] {
            assert!(!supports_table_creation(engine), "{engine}");
        }
    }

    #[test]
    fn duckdb_spells_json_without_the_postgres_binary_suffix() {
        assert_eq!(type_name("duckdb", ColumnKind::Json), "JSON");
        assert_eq!(type_name("postgres", ColumnKind::Json), "JSONB");
        assert_eq!(type_name("duckdb", ColumnKind::Int), "BIGINT");
    }
}
