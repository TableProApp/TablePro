use thiserror::Error;

use crate::import::cell::{CsvRowError, row_to_values_for_driver};
use crate::import::csv_import::{CsvImportOptions, CsvSheet};
use crate::query::{ColumnInfo, Value};
use crate::sql_dialect::{
    BuildSqlError, IdentError, build_insert_from_draft, placeholder_for, postgres_array_cast_type,
    postgres_numeric_cast_type, postgres_temporal_cast_type, quote_ident, validate_ident,
};

/// Rows committed per transaction. Small enough that a failure loses
/// little, large enough that the round trips do not dominate.
pub const DEFAULT_IMPORT_BATCH_ROWS: usize = 500;

/// Row failures the user is shown. The rest are counted, not listed.
pub const MAX_REPORTED_ROW_ERRORS: usize = 20;

#[derive(Debug, PartialEq, Eq, Error)]
pub enum PlanError {
    #[error("no column is mapped to a field in the file")]
    NoMappedColumns,

    #[error("the file has no rows to import")]
    NoRows,

    #[error("{0}")]
    Ident(#[from] IdentError),

    #[error("the insert could not be built: {0}")]
    Sql(String),

    #[error("{total} rows could not be read into the table")]
    Rows { total: usize, first: Vec<CsvRowError> },
}

/// Where the rows are going, and which field feeds each column.
pub struct ImportTarget<'a> {
    pub driver_id: &'a str,
    pub schema: Option<&'a str>,
    pub table: &'a str,
    pub columns: &'a [ColumnInfo],
    pub mapping: &'a [Option<usize>],
}

/// One INSERT shape and the bound values for every row, in that shape's
/// column order. Holding one statement for the whole file is what lets a
/// single approval cover it.
#[derive(Debug, Clone, PartialEq)]
pub struct InsertPlan {
    pub statement: String,
    pub columns: Vec<ColumnInfo>,
    pub rows: Vec<Vec<Value>>,
}

impl InsertPlan {
    pub fn row_count(&self) -> u64 {
        self.rows.len() as u64
    }

    pub fn batches(&self, size: usize) -> impl Iterator<Item = &[Vec<Value>]> {
        self.rows.chunks(size.max(1))
    }
}

/// Build the one statement and every row's values, or refuse with the
/// rows that could not be read. Nothing is executed here.
pub fn build_insert_plan(
    target: &ImportTarget<'_>,
    sheet: &CsvSheet,
    options: &CsvImportOptions,
) -> Result<InsertPlan, PlanError> {
    validate_ident(target.table)?;
    if let Some(schema) = target.schema {
        validate_ident(schema)?;
    }
    if sheet.rows.is_empty() {
        return Err(PlanError::NoRows);
    }
    let (columns, mapping) = insert_columns(target)?;
    let mut rows = bind_rows(sheet, &columns, &mapping, options, target.driver_id)?;
    let mysql_empty_string_columns = if target.driver_id.eq_ignore_ascii_case("mysql") {
        columns
            .iter()
            .enumerate()
            .filter(|(index, column)| {
                mysql_empty_string_type(&column.data_type)
                    && rows
                        .iter()
                        .any(|row| matches!(row.get(*index), Some(Value::Text(text)) if text.is_empty()))
            })
            .map(|(index, _)| index)
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let statement = insert_statement(target, &columns, &mysql_empty_string_columns)?;
    if !mysql_empty_string_columns.is_empty() {
        for row in &mut rows {
            let values = std::mem::take(row);
            let mut params = Vec::with_capacity(values.len() + mysql_empty_string_columns.len());
            for (index, value) in values.into_iter().enumerate() {
                if mysql_empty_string_columns.contains(&index) {
                    let is_empty = matches!(&value, Value::Text(text) if text.is_empty());
                    params.push(Value::Int(i64::from(is_empty)));
                    params.push(if is_empty { Value::Null } else { value });
                } else {
                    params.push(value);
                }
            }
            *row = params;
        }
    }
    Ok(InsertPlan {
        statement,
        columns,
        rows,
    })
}

/// The columns the statement writes: mapped, and not ones the engine
/// fills itself. An unmapped column is left out of the statement
/// entirely, so its own default applies.
fn insert_columns(target: &ImportTarget<'_>) -> Result<(Vec<ColumnInfo>, Vec<Option<usize>>), PlanError> {
    let mut columns = Vec::new();
    let mut mapping = Vec::new();
    for (column, field) in target.columns.iter().zip(target.mapping) {
        let Some(field) = field else {
            continue;
        };
        if column.is_auto_increment || column.is_generated {
            continue;
        }
        validate_ident(&column.name)?;
        columns.push(column.clone());
        mapping.push(Some(*field));
    }
    if columns.is_empty() {
        return Err(PlanError::NoMappedColumns);
    }
    Ok((columns, mapping))
}

/// One shape for every row. The statement is built from placeholder
/// values that are never NULL, so no column is dropped from it for one
/// row and kept for the next.
fn insert_statement(
    target: &ImportTarget<'_>,
    columns: &[ColumnInfo],
    mysql_empty_string_columns: &[usize],
) -> Result<String, PlanError> {
    if !mysql_empty_string_columns.is_empty() {
        let mut parameter_index = 0;
        let values = columns
            .iter()
            .enumerate()
            .map(|(column_index, _)| {
                if mysql_empty_string_columns.contains(&column_index) {
                    let empty = placeholder_for(target.driver_id, parameter_index);
                    let value = placeholder_for(target.driver_id, parameter_index + 1);
                    parameter_index += 2;
                    format!("CASE WHEN {empty} = 1 THEN SPACE(0) ELSE {value} END")
                } else {
                    let value = placeholder_for(target.driver_id, parameter_index);
                    parameter_index += 1;
                    value
                }
            })
            .collect::<Vec<_>>();
        let identifiers = columns
            .iter()
            .map(|column| quote_ident(target.driver_id, &column.name))
            .collect::<Vec<_>>();
        let table = match target.schema {
            Some(schema) => format!(
                "{}.{}",
                quote_ident(target.driver_id, schema),
                quote_ident(target.driver_id, target.table)
            ),
            None => quote_ident(target.driver_id, target.table),
        };
        return Ok(format!(
            "INSERT INTO {table} ({}) VALUES ({})",
            identifiers.join(", "),
            values.join(", ")
        ));
    }
    let shape_columns: Vec<ColumnInfo> = columns.to_vec();
    // PostgreSQL temporal CSV values use text parameters with an explicit
    // server cast. This supports exact sentinels such as +/-infinity while
    // keeping the parameter type consistent for every row in the import.
    let shape_values = shape_columns
        .iter()
        .map(|column| {
            if column.enum_type.is_some()
                || postgres_array_cast_type(&column.data_type).is_some()
                || postgres_numeric_cast_type(&column.data_type).is_some()
                || postgres_temporal_cast_type(&column.data_type).is_some()
            {
                Value::Text(String::new())
            } else {
                Value::Int(0)
            }
        })
        .collect::<Vec<_>>();
    let (statement, _) = build_insert_from_draft(
        target.driver_id,
        target.schema,
        target.table,
        &shape_columns,
        &shape_values,
    )
    .map_err(|error: BuildSqlError| PlanError::Sql(error.to_string()))?;
    Ok(statement)
}

fn mysql_empty_string_type(data_type: &str) -> bool {
    [
        "enum(",
        "set(",
        "char",
        "varchar",
        "tinytext",
        "text",
        "mediumtext",
        "longtext",
    ]
    .iter()
    .any(|prefix| {
        data_type
            .trim()
            .get(..prefix.len())
            .is_some_and(|head| head.eq_ignore_ascii_case(prefix))
    })
}

fn bind_rows(
    sheet: &CsvSheet,
    columns: &[ColumnInfo],
    mapping: &[Option<usize>],
    options: &CsvImportOptions,
    driver_id: &str,
) -> Result<Vec<Vec<Value>>, PlanError> {
    let header_offset = usize::from(options.has_header);
    let mut rows = Vec::with_capacity(sheet.rows.len());
    let mut failures = Vec::new();
    let mut total_failures = 0;
    for (index, row) in sheet.rows.iter().enumerate() {
        match row_to_values_for_driver(row, mapping, columns, options, index + header_offset + 1, driver_id) {
            Ok(mut values) => {
                if driver_id == "postgres" {
                    for (value, column) in values.iter_mut().zip(columns) {
                        if postgres_temporal_cast_type(&column.data_type).is_some() {
                            match value {
                                Value::Date(date) => *value = Value::Text(date.to_string()),
                                Value::Time(time) => *value = Value::Text(time.to_string()),
                                Value::DateTime(datetime) => *value = Value::Text(datetime.to_string()),
                                Value::TimestampTz(datetime) => *value = Value::Text(datetime.to_rfc3339()),
                                _ => {}
                            }
                        }
                    }
                }
                rows.push(values);
            }
            Err(error) => {
                total_failures += 1;
                if failures.len() < MAX_REPORTED_ROW_ERRORS {
                    failures.push(error);
                }
            }
        }
    }
    if total_failures > 0 {
        return Err(PlanError::Rows {
            total: total_failures,
            first: failures,
        });
    }
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str, data_type: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            data_type: data_type.to_owned(),
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

    fn sheet(rows: &[&[&str]], headers: &[&str]) -> CsvSheet {
        CsvSheet {
            headers: headers.iter().map(|header| (*header).to_owned()).collect(),
            rows: rows
                .iter()
                .map(|row| row.iter().map(|cell| (*cell).to_owned()).collect())
                .collect(),
            truncated: false,
        }
    }

    fn target<'a>(columns: &'a [ColumnInfo], mapping: &'a [Option<usize>]) -> ImportTarget<'a> {
        ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "people",
            columns,
            mapping,
        }
    }

    #[test]
    fn every_row_binds_to_the_same_statement() {
        let columns = vec![column("id", "bigint"), column("name", "text")];
        let mapping = vec![Some(0), Some(1)];
        let sheet = sheet(&[&["1", "ada"], &["2", "grace"]], &["id", "name"]);

        let plan = build_insert_plan(&target(&columns, &mapping), &sheet, &CsvImportOptions::default()).expect("plan");

        assert_eq!(
            plan.statement,
            "INSERT INTO \"people\" (\"id\", \"name\") VALUES ($1, $2)"
        );
        assert_eq!(plan.row_count(), 2);
        assert_eq!(plan.rows.len(), 2);
        assert_eq!(plan.rows[0], vec![Value::Int(1), Value::Text("ada".to_owned())]);
    }

    #[test]
    fn mysql_empty_enum_set_and_varchar_csv_cells_are_reconstructed_without_binding_empty_text() {
        let columns = vec![
            column("id", "INT"),
            column("state", "enum('', 'ready', 'NULL')"),
            column("permissions", "set('read', 'write')"),
            column("note", "varchar(30)"),
        ];
        let mapping = vec![Some(0), Some(1), Some(2), Some(3)];
        let sheet = sheet(
            &[
                &["1", "", "", ""],
                &["2", "ready", "read", "plain"],
                &["3", "\\N", "\\N", "\\N"],
            ],
            &["id", "state", "permissions", "note"],
        );
        let options = CsvImportOptions {
            null_marker: "\\N".into(),
            ..CsvImportOptions::default()
        };
        let target = ImportTarget {
            driver_id: "mysql",
            schema: None,
            table: "enum_rows",
            columns: &columns,
            mapping: &mapping,
        };

        let plan = build_insert_plan(&target, &sheet, &options).expect("plan");

        assert_eq!(
            plan.statement,
            "INSERT INTO `enum_rows` (`id`, `state`, `permissions`, `note`) VALUES (?, CASE WHEN ? = 1 THEN SPACE(0) ELSE ? END, CASE WHEN ? = 1 THEN SPACE(0) ELSE ? END, CASE WHEN ? = 1 THEN SPACE(0) ELSE ? END)"
        );
        assert_eq!(
            plan.rows,
            vec![
                vec![
                    Value::Int(1),
                    Value::Int(1),
                    Value::Null,
                    Value::Int(1),
                    Value::Null,
                    Value::Int(1),
                    Value::Null,
                ],
                vec![
                    Value::Int(2),
                    Value::Int(0),
                    Value::Text("ready".into()),
                    Value::Int(0),
                    Value::Text("read".into()),
                    Value::Int(0),
                    Value::Text("plain".into()),
                ],
                vec![
                    Value::Int(3),
                    Value::Int(0),
                    Value::Null,
                    Value::Int(0),
                    Value::Null,
                    Value::Int(0),
                    Value::Null,
                ],
            ]
        );
    }

    #[test]
    fn mysql_empty_string_reconstruction_is_limited_to_text_destinations() {
        for data_type in [
            "enum('', 'ready')",
            "set('read', 'write')",
            "char(8)",
            "varchar(30)",
            "tinytext",
            "text",
            "mediumtext",
            "longtext",
        ] {
            assert!(mysql_empty_string_type(data_type), "{data_type}");
        }
        for data_type in ["json", "varbinary", "int"] {
            assert!(!mysql_empty_string_type(data_type), "{data_type}");
        }
    }

    #[test]
    fn mysql_text_import_without_empty_cells_keeps_the_simple_insert_plan() {
        let columns = vec![column("note", "text")];
        let mapping = vec![Some(0)];
        let sheet = sheet(&[&["plain"]], &["note"]);
        let target = ImportTarget {
            driver_id: "mysql",
            schema: None,
            table: "people",
            columns: &columns,
            mapping: &mapping,
        };

        let plan = build_insert_plan(&target, &sheet, &CsvImportOptions::default()).expect("plan");

        assert_eq!(plan.statement, "INSERT INTO `people` (`note`) VALUES (?)");
        assert_eq!(plan.rows, vec![vec![Value::Text("plain".into())]]);
    }

    #[test]
    fn postgres_enum_import_plan_uses_catalog_type_for_text_rows() {
        let mut status = column("status", "value_contract_enum_schema.value_contract_status");
        status.enum_type = Some(crate::query::QualifiedTypeName {
            schema: "value_contract_enum_schema".into(),
            name: "value_contract_status".into(),
        });
        let columns = vec![status];
        let mapping = vec![Some(0)];
        let sheet = sheet(&[&["NULL"]], &["status"]);

        let plan = build_insert_plan(&target(&columns, &mapping), &sheet, &CsvImportOptions::default()).expect("plan");

        assert!(
            plan.statement
                .contains("$1::text::\"value_contract_enum_schema\".\"value_contract_status\"")
        );
        assert_eq!(plan.rows, vec![vec![Value::Text("NULL".into())]]);
    }

    #[test]
    fn postgres_enum_import_requires_a_null_marker_for_empty_fields() {
        let mut status = column("status", "value_contract_status");
        status.enum_type = Some(crate::query::QualifiedTypeName {
            schema: "value_contract_enum_schema".into(),
            name: "value_contract_status".into(),
        });
        let columns = vec![status];
        let mapping = vec![Some(0)];
        let blank_sheet = sheet(&[&[""]], &["status"]);

        let error = build_insert_plan(&target(&columns, &mapping), &blank_sheet, &CsvImportOptions::default())
            .expect_err("a blank could be either NULL or an empty enum label");
        let PlanError::Rows { total, first } = error else {
            panic!("expected the ambiguous blank to be refused");
        };
        assert_eq!(total, 1);
        assert_eq!(first[0].reason, crate::import::CellError::AmbiguousEnumNullOrEmpty);

        let options = CsvImportOptions {
            null_marker: "\\N".into(),
            ..CsvImportOptions::default()
        };
        let explicit_sheet = sheet(&[&[""], &["\\N"], &["NULL"]], &["status"]);
        let plan = build_insert_plan(&target(&columns, &mapping), &explicit_sheet, &options).expect("explicit marker");
        assert_eq!(
            plan.rows,
            vec![
                vec![Value::Text(String::new())],
                vec![Value::Null],
                vec![Value::Text("NULL".into())],
            ]
        );
    }

    #[test]
    fn postgres_enum_array_import_distinguishes_blank_null_from_empty_array() {
        let mut labels = column("labels", "enum_array_schema.label[]");
        labels.enum_type = Some(crate::query::QualifiedTypeName {
            schema: "enum_array_schema".into(),
            name: "label".into(),
        });
        let columns = vec![labels];
        let mapping = vec![Some(0)];
        let sheet = sheet(&[&[""], &["{}"]], &["labels"]);
        let plan = build_insert_plan(&target(&columns, &mapping), &sheet, &CsvImportOptions::default())
            .expect("blank is an unambiguous NULL array; an empty array is `{}`");
        assert_eq!(plan.rows, vec![vec![Value::Null], vec![Value::Text("{}".into())]]);
        assert!(plan.statement.contains("$1::text::\"enum_array_schema\".\"label\"[]"));
    }

    #[test]
    fn value_contract_postgres_temporal_csv_rows_share_text_cast_parameters() {
        let columns = vec![
            column("date_value", "date"),
            column("time_value", "time"),
            column("timetz_value", "timetz"),
            column("timestamp_value", "timestamp"),
            column("timestamptz_value", "timestamptz"),
        ];
        let mapping = vec![Some(0), Some(1), Some(2), Some(3), Some(4)];
        let rows = sheet(
            &[
                &[
                    "'-infinity",
                    "24:00:00",
                    "01:02:03+05:45:12",
                    "2001-02-03 04:05:06.000007",
                    "2001-02-03T04:05:06.000007+00:00",
                ],
                &[
                    "2001-02-03",
                    "12:13:14.000015",
                    "01:02:03-03:30:12",
                    "2001-02-03 04:05:06.000007",
                    "2001-02-03T04:05:06.000007+00:00",
                ],
            ],
            &["date", "time", "timetz", "timestamp", "timestamptz"],
        );
        let plan = build_insert_plan(&target(&columns, &mapping), &rows, &CsvImportOptions::default()).unwrap();

        assert_eq!(
            plan.statement,
            "INSERT INTO \"people\" (\"date_value\", \"time_value\", \"timetz_value\", \"timestamp_value\", \"timestamptz_value\") VALUES ($1::text::pg_catalog.date, $2::text::pg_catalog.time, $3::text::pg_catalog.timetz, $4::text::pg_catalog.timestamp, $5::text::pg_catalog.timestamptz)"
        );
        assert_eq!(
            plan.rows,
            vec![
                vec![
                    Value::Text("-infinity".into()),
                    Value::Text("24:00:00".into()),
                    Value::Text("01:02:03+05:45:12".into()),
                    Value::Text("2001-02-03 04:05:06.000007".into()),
                    Value::Text("2001-02-03T04:05:06.000007+00:00".into()),
                ],
                vec![
                    Value::Text("2001-02-03".into()),
                    Value::Text("12:13:14.000015".into()),
                    Value::Text("01:02:03-03:30:12".into()),
                    Value::Text("2001-02-03 04:05:06.000007".into()),
                    Value::Text("2001-02-03T04:05:06.000007+00:00".into()),
                ],
            ]
        );

        let mysql_columns = vec![column("date_value", "date")];
        let mysql_mapping = [Some(0)];
        let mysql_rows = sheet(&[&["2001-02-03"]], &["date"]);
        let mysql_target = ImportTarget {
            driver_id: "mysql",
            schema: None,
            table: "people",
            columns: &mysql_columns,
            mapping: &mysql_mapping,
        };
        let mysql_plan = build_insert_plan(&mysql_target, &mysql_rows, &CsvImportOptions::default()).unwrap();
        assert_eq!(mysql_plan.statement, "INSERT INTO `people` (`date_value`) VALUES (?)");
        assert_eq!(
            mysql_plan.rows,
            vec![vec![Value::Date(chrono::NaiveDate::from_ymd_opt(2001, 2, 3).unwrap())]]
        );
    }

    #[test]
    fn value_contract_postgres_array_csv_insert_uses_allowlisted_native_cast() {
        let columns = vec![column("id", "integer"), column("value", "double precision[]")];
        let mapping = vec![Some(0), Some(1)];
        let rows = sheet(&[&["4", "{1.0000000000000002,-0,5e-324,NULL}"]], &["id", "value"]);
        let plan = build_insert_plan(&target(&columns, &mapping), &rows, &CsvImportOptions::default()).unwrap();

        assert_eq!(
            plan.statement,
            "INSERT INTO \"people\" (\"id\", \"value\") VALUES ($1, $2::text::pg_catalog.float8[])"
        );
        assert_eq!(
            plan.rows,
            vec![vec![
                Value::Int(4),
                Value::Text("{1.0000000000000002,-0,5e-324,NULL}".into())
            ]]
        );
    }

    #[test]
    fn value_contract_postgres_wide_numeric_csv_rows_share_text_cast_parameters() {
        let columns = vec![column("amount", "numeric(65,0)")];
        let mapping = vec![Some(0)];
        let wide = "1234567890123456789012345678901234567890";
        let rows = sheet(&[&["12"], &[wide], &[""]], &["amount"]);
        let plan = build_insert_plan(&target(&columns, &mapping), &rows, &CsvImportOptions::default()).unwrap();

        assert_eq!(
            plan.statement,
            "INSERT INTO \"people\" (\"amount\") VALUES ($1::text::pg_catalog.numeric)"
        );
        assert_eq!(
            plan.rows,
            vec![
                vec![Value::Text("12".into())],
                vec![Value::Text(wide.into())],
                vec![Value::Null],
            ]
        );
    }

    /// The statement builder drops a column whose value is NULL when the
    /// column has a server default. One approved import must send one
    /// shape, so the plan builds the statement from values that are never
    /// NULL and keeps every mapped column in it.
    #[test]
    fn a_mapped_column_with_a_server_default_stays_in_the_statement_for_every_row() {
        let mut columns = vec![column("id", "bigint"), column("created", "timestamp")];
        columns[1].default_value = Some("now()".into());
        let mapping = vec![Some(0), Some(1)];
        let sheet = sheet(&[&["1", ""], &["2", "2024-05-06 00:00:00"]], &["id", "created"]);

        let plan = build_insert_plan(&target(&columns, &mapping), &sheet, &CsvImportOptions::default()).expect("plan");

        assert!(plan.statement.contains("\"created\""));
        assert_eq!(plan.rows[0][1], Value::Null);
    }

    #[test]
    fn an_unmapped_column_is_left_out_so_its_own_default_applies() {
        let columns = vec![column("id", "bigint"), column("created", "timestamp")];
        let mapping = vec![Some(0), None];
        let sheet = sheet(&[&["1"]], &["id"]);

        let plan = build_insert_plan(&target(&columns, &mapping), &sheet, &CsvImportOptions::default()).expect("plan");

        assert!(!plan.statement.contains("created"));
        assert_eq!(plan.columns.len(), 1);
    }

    #[test]
    fn a_column_the_engine_fills_itself_is_never_written() {
        let mut columns = vec![
            column("id", "bigint"),
            column("computed", "text"),
            column("name", "text"),
        ];
        columns[0].is_auto_increment = true;
        columns[1].is_generated = true;
        let mapping = vec![Some(0), Some(1), Some(2)];
        let sheet = sheet(&[&["1", "must be skipped", "ada"]], &["id", "computed", "name"]);

        let plan = build_insert_plan(&target(&columns, &mapping), &sheet, &CsvImportOptions::default()).expect("plan");

        assert_eq!(plan.statement, "INSERT INTO \"people\" (\"name\") VALUES ($1)");
        assert_eq!(
            plan.columns
                .iter()
                .map(|column| column.name.as_str())
                .collect::<Vec<_>>(),
            vec!["name"]
        );
        assert_eq!(plan.rows, vec![vec![Value::Text("ada".into())]]);
    }

    #[test]
    fn an_identifier_that_carries_a_quote_is_escaped_rather_than_closed() {
        let columns = vec![column("na\"me", "text")];
        let mapping = vec![Some(0)];
        let mut target = target(&columns, &mapping);
        target.table = "peo\"ple\"; DROP TABLE people; --";
        let rows = sheet(&[&["ada"]], &["name"]);

        let plan = build_insert_plan(&target, &rows, &CsvImportOptions::default()).expect("plan");

        assert_eq!(
            plan.statement,
            "INSERT INTO \"peo\"\"ple\"\"; DROP TABLE people; --\" (\"na\"\"me\") VALUES ($1)"
        );
    }

    #[test]
    fn an_identifier_that_is_empty_or_carries_a_control_character_is_refused() {
        let columns = vec![column("id", "bigint")];
        let mapping = vec![Some(0)];
        let rows = sheet(&[&["1"]], &["id"]);
        let mut empty = target(&columns, &mapping);
        empty.table = "   ";
        assert_eq!(
            build_insert_plan(&empty, &rows, &CsvImportOptions::default()),
            Err(PlanError::Ident(IdentError::Empty))
        );

        let broken = vec![column("na\nme", "text")];
        assert_eq!(
            build_insert_plan(&target(&broken, &mapping), &rows, &CsvImportOptions::default()),
            Err(PlanError::Ident(IdentError::ControlCharacter))
        );
    }

    #[test]
    fn rows_that_cannot_be_read_stop_the_plan_and_are_reported_without_their_contents() {
        let columns = vec![column("id", "bigint")];
        let mapping = vec![Some(0)];
        let sheet = sheet(&[&["1"], &["not-a-number"], &["also-bad"]], &["id"]);

        let error =
            build_insert_plan(&target(&columns, &mapping), &sheet, &CsvImportOptions::default()).expect_err("refused");

        let PlanError::Rows { total, first } = error else {
            panic!("expected row failures");
        };
        assert_eq!(total, 2);
        assert_eq!(first[0].line, 3);
        assert!(!first.iter().any(|error| error.to_string().contains("not-a-number")));
    }

    #[test]
    fn numeric_affinity_text_fallback_is_sqlite_only() {
        let columns = vec![column("value", "NUMERIC")];
        let mapping = vec![Some(0)];
        let sheet = sheet(&[&["not-a-number"]], &["value"]);
        let sqlite = ImportTarget {
            driver_id: "sqlite",
            schema: None,
            table: "flexible",
            columns: &columns,
            mapping: &mapping,
        };
        let plan = build_insert_plan(&sqlite, &sheet, &CsvImportOptions::default()).expect("SQLite stores text");
        assert_eq!(plan.rows, vec![vec![Value::Text("not-a-number".to_owned())]]);

        let postgres = target(&columns, &mapping);
        assert!(matches!(
            build_insert_plan(&postgres, &sheet, &CsvImportOptions::default()),
            Err(PlanError::Rows { total: 1, .. })
        ));
    }

    #[test]
    fn only_the_first_failures_are_listed_and_the_rest_are_counted() {
        let columns = vec![column("id", "bigint")];
        let mapping = vec![Some(0)];
        let rows: Vec<Vec<String>> = (0..MAX_REPORTED_ROW_ERRORS + 5)
            .map(|_| vec!["bad".to_owned()])
            .collect();
        let sheet = CsvSheet {
            headers: vec!["id".to_owned()],
            rows,
            truncated: false,
        };

        let error =
            build_insert_plan(&target(&columns, &mapping), &sheet, &CsvImportOptions::default()).expect_err("refused");

        let PlanError::Rows { total, first } = error else {
            panic!("expected row failures");
        };
        assert_eq!(total, MAX_REPORTED_ROW_ERRORS + 5);
        assert_eq!(first.len(), MAX_REPORTED_ROW_ERRORS);
    }

    #[test]
    fn a_file_with_nothing_mapped_or_nothing_in_it_is_refused() {
        let columns = vec![column("id", "bigint")];
        let filled = sheet(&[&["1"]], &["id"]);
        assert_eq!(
            build_insert_plan(&target(&columns, &[None]), &filled, &CsvImportOptions::default()),
            Err(PlanError::NoMappedColumns)
        );
        assert_eq!(
            build_insert_plan(
                &target(&columns, &[Some(0)]),
                &sheet(&[], &["id"]),
                &CsvImportOptions::default()
            ),
            Err(PlanError::NoRows)
        );
    }

    #[test]
    fn the_batches_a_plan_offers_are_bounded_and_cover_every_row() {
        let columns = vec![column("id", "bigint")];
        let mapping = vec![Some(0)];
        let rows: Vec<Vec<String>> = (0..7).map(|index| vec![index.to_string()]).collect();
        let sheet = CsvSheet {
            headers: vec!["id".to_owned()],
            rows,
            truncated: false,
        };
        let plan = build_insert_plan(&target(&columns, &mapping), &sheet, &CsvImportOptions::default()).expect("plan");

        let batches: Vec<usize> = plan.batches(3).map(<[Vec<Value>]>::len).collect();

        assert_eq!(batches, vec![3, 3, 1]);
        assert_eq!(batches.iter().sum::<usize>(), 7);
    }
}
