use std::str::FromStr;

use rust_decimal::Decimal;
use tablepro_core::{Connection, Value};

pub(super) async fn assert_contract(connection: &dyn Connection) {
    let positive_scale_38 = format!("0.{}1", "0".repeat(37));
    let zero_scale_38 = format!("0.{}0", "0".repeat(37));
    connection
        .execute(
            "CREATE TABLE numeric_source (id int PRIMARY KEY, wide decimal(38,0), \
             high_scale decimal(38,30), fitting decimal(28,4), nullable decimal(38,0), \
             scale_boundary decimal(38,28), max_scale decimal(38,38))",
        )
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO numeric_source VALUES \
             (1, 99999999999999999999999999999999999999, \
              12345678.123456789012345678901234567890, \
              123456789012345678901234.5678, NULL, \
              0.0000000000000000000000000001, {positive_scale_38}), \
             (2, -99999999999999999999999999999999999999, \
              -0.000000000000000000000000000001, -0.0001, 0, \
              -0.0000000000000000000000000001, -{positive_scale_38}), \
             (3, 0, 0.000000000000000000000000000000, 0.0000, 0, 0, {zero_scale_38})"
        ))
        .await
        .unwrap();
    let source = connection
        .query(
            "SELECT id, wide, high_scale, fitting, nullable, scale_boundary, max_scale \
             FROM numeric_source ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        source.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("99999999999999999999999999999999999999".into()),
                Value::Text("12345678.123456789012345678901234567890".into()),
                Value::Decimal(Decimal::from_str("123456789012345678901234.5678").unwrap()),
                Value::Null,
                Value::Decimal(Decimal::from_str("0.0000000000000000000000000001").unwrap()),
                Value::Text(positive_scale_38.clone()),
            ],
            vec![
                Value::Int(2),
                Value::Text("-99999999999999999999999999999999999999".into()),
                Value::Text("-0.000000000000000000000000000001".into()),
                Value::Decimal(Decimal::from_str("-0.0001").unwrap()),
                Value::Decimal(Decimal::ZERO),
                Value::Decimal(Decimal::from_str("-0.0000000000000000000000000001").unwrap()),
                Value::Text(format!("-{positive_scale_38}")),
            ],
            vec![
                Value::Int(3),
                Value::Decimal(Decimal::ZERO),
                Value::Text("0.000000000000000000000000000000".into()),
                Value::Decimal(Decimal::ZERO),
                Value::Decimal(Decimal::ZERO),
                Value::Decimal(Decimal::ZERO),
                Value::Text(zero_scale_38.clone()),
            ],
        ],
        "wide native decimals must fall back to exact text while representable values remain decimal",
    );
    assert_native_text(connection, "numeric_source").await;
    copy_bound_rows(connection, "numeric_bound", &source.rows).await;
    create_copy_table(connection, "numeric_csv").await;
    let columns = connection.fetch_columns(None, "numeric_csv").await.unwrap();
    let source_columns = connection.fetch_columns(None, "numeric_source").await.unwrap();
    assert_eq!(
        source_columns
            .iter()
            .map(|column| (column.name.as_str(), column.data_type.as_str()))
            .collect::<Vec<_>>(),
        [
            ("id", "int"),
            ("wide", "decimal(38,0)"),
            ("high_scale", "decimal(38,30)"),
            ("fitting", "decimal(28,4)"),
            ("nullable", "decimal(38,0)"),
            ("scale_boundary", "decimal(38,28)"),
            ("max_scale", "decimal(38,38)"),
        ],
        "SQL Server catalog metadata must retain decimal precision and scale"
    );
    let csv_rows = csv_round_trip(&source, &columns);
    insert_bound_rows(connection, "numeric_csv", &csv_rows).await;
    assert_native_text(connection, "numeric_csv").await;
}

async fn copy_bound_rows(connection: &dyn Connection, table: &str, rows: &[Vec<Value>]) {
    create_copy_table(connection, table).await;
    insert_bound_rows(connection, table, rows).await;
    assert_native_text(connection, table).await;
}

async fn create_copy_table(connection: &dyn Connection, table: &str) {
    connection
        .execute(&format!("SELECT TOP 0 * INTO {table} FROM numeric_source"))
        .await
        .unwrap();
}

async fn insert_bound_rows(connection: &dyn Connection, table: &str, rows: &[Vec<Value>]) {
    for row in rows {
        connection
            .execute_params(
                &format!("INSERT INTO {table} VALUES (@P1, @P2, @P3, @P4, @P5, @P6, @P7)"),
                row,
            )
            .await
            .unwrap();
    }
}

async fn assert_native_text(connection: &dyn Connection, table: &str) {
    let count = connection
        .query(&format!(
            "SELECT COUNT(*) FROM numeric_source s JOIN {table} c ON s.id = c.id \
             AND s.wide = c.wide AND s.high_scale = c.high_scale AND s.fitting = c.fitting \
             AND s.scale_boundary = c.scale_boundary AND s.max_scale = c.max_scale \
             AND (s.nullable = c.nullable OR (s.nullable IS NULL AND c.nullable IS NULL))"
        ))
        .await
        .unwrap();
    assert_eq!(count.rows, vec![vec![Value::Int(3)]]);
    let native = connection
        .query(&format!(
            "SELECT CONVERT(varchar(40), wide), CONVERT(varchar(40), high_scale), \
             CONVERT(varchar(40), fitting), CONVERT(varchar(40), nullable), \
             CONVERT(varchar(40), scale_boundary), CONVERT(varchar(50), max_scale) \
             FROM {table} ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(
        native.rows,
        vec![
            vec![
                Value::Text("99999999999999999999999999999999999999".into()),
                Value::Text("12345678.123456789012345678901234567890".into()),
                Value::Text("123456789012345678901234.5678".into()),
                Value::Null,
                Value::Text("0.0000000000000000000000000001".into()),
                Value::Text(format!("0.{}1", "0".repeat(37))),
            ],
            vec![
                Value::Text("-99999999999999999999999999999999999999".into()),
                Value::Text("-0.000000000000000000000000000001".into()),
                Value::Text("-0.0001".into()),
                Value::Text("0".into()),
                Value::Text("-0.0000000000000000000000000001".into()),
                Value::Text(format!("-0.{}1", "0".repeat(37))),
            ],
            vec![
                Value::Text("0".into()),
                Value::Text("0.000000000000000000000000000000".into()),
                Value::Text("0.0000".into()),
                Value::Text("0".into()),
                Value::Text("0.0000000000000000000000000000".into()),
                Value::Text(format!("0.{}0", "0".repeat(37))),
            ],
        ]
    );
}

fn csv_round_trip(source: &tablepro_core::QueryResult, columns: &[tablepro_core::ColumnInfo]) -> Vec<Vec<Value>> {
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let mapping = (0..source.columns.len()).map(Some).collect::<Vec<_>>();
    sheet
        .rows
        .iter()
        .enumerate()
        .map(|(index, fields)| {
            tablepro_core::import::row_to_values(fields, &mapping, columns, &options, index + 2).unwrap()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_keeps_wide_decimals_as_exact_text_and_null_distinct() {
        let source = tablepro_core::QueryResult {
            columns: vec![column("wide", "decimal(38,0)"), column("high_scale", "decimal(38,30)")],
            rows: vec![vec![
                Value::Text("99999999999999999999999999999999999999".into()),
                Value::Text("12345678.123456789012345678901234567890".into()),
            ]],
            truncated: false,
        };
        let restored = csv_round_trip(&source, &source.columns);
        assert_eq!(restored, source.rows);
    }

    fn column(name: &str, data_type: &str) -> tablepro_core::ColumnInfo {
        tablepro_core::ColumnInfo {
            name: name.into(),
            data_type: data_type.into(),
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
