use super::parse_input_for_driver;
use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, TlsConfig, Value};
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::mssql_server::MssqlServer;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mssql_datetimeoffset_grid_edit_preserves_local_time_offset_and_siblings() {
    let container = MssqlServer::default().with_accept_eula().start().await.unwrap();
    let connection = drivers_mssql::MssqlDriver
        .connect(ConnectOptions {
            host: container.get_host().await.unwrap().to_string(),
            port: container.get_host_port_ipv4(1433).await.unwrap(),
            database: "master".into(),
            username: "sa".into(),
            password: secrecy::SecretString::new(MssqlServer::DEFAULT_SA_PASSWORD.to_string().into()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    connection
        .execute_controlled(
            "CREATE TABLE datetimeoffset_grid (id int PRIMARY KEY, value datetimeoffset(7) NOT NULL, note nvarchar(20)); \
             INSERT INTO datetimeoffset_grid VALUES \
             (1, '2024-01-02 03:04:05.1234567 +05:30', N'fraction and offset'), \
             (2, '2024-06-30 23:59:59.9999999 -08:00', N'negative offset'), \
             (3, '0001-01-01 00:00:00.0000000 -14:00', N'lower boundary'), \
             (4, '9999-12-31 23:59:59.9999999 +00:00', N'untouched sibling')",
            &control,
        )
        .await
        .unwrap();
    let columns = connection
        .fetch_columns_controlled(None, "datetimeoffset_grid", &control)
        .await
        .unwrap();
    let value_index = columns.iter().position(|column| column.name == "value").unwrap();
    let id_index = columns.iter().position(|column| column.name == "id").unwrap();
    assert_eq!(columns[value_index].data_type, "datetimeoffset(7)");
    assert!(columns[id_index].primary_key);

    let select = "SELECT id, value, DATEPART(TZOFFSET, value) AS offset_minutes, \
                  CONVERT(varbinary(20), value) AS wire, note \
                  FROM datetimeoffset_grid ORDER BY id";
    let before = connection.query_controlled(select, &control).await.unwrap();
    let expected = [
        ("2024-01-02 03:04:05.1234567 +05:30", 330),
        ("2024-06-30 23:59:59.9999999 -08:00", -480),
        ("0001-01-01 00:00:00.0000000 -14:00", -840),
        ("9999-12-31 23:59:59.9999999 +00:00", 0),
    ];
    for (row, (text, offset_minutes)) in before.rows.iter().zip(expected) {
        assert_eq!(row[1], Value::Text(text.into()));
        assert_eq!(row[2], Value::Int(offset_minutes));
        assert!(matches!(row[3], Value::Bytes(ref bytes) if bytes.len() == 11));
    }

    let workbook_result = connection
        .query_controlled("SELECT value FROM datetimeoffset_grid ORDER BY id", &control)
        .await
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let workbook_path = directory.path().join("datetimeoffset.xlsx");
    let csv_options = tablepro_core::export::CsvOptions::default();
    tablepro_core::export::write_result_file(
        &workbook_path,
        &workbook_result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut archive = zip::ZipArchive::new(std::fs::File::open(workbook_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet).unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    for (index, (stamp, _)) in expected.iter().enumerate() {
        assert!(sheet.contains(&format!("<c r=\"A{}\" t=\"s\">", index + 2)), "{sheet}");
        assert!(shared_strings.contains(&format!("<t>{stamp}</t>")), "{shared_strings}");
    }
    assert!(!sheet.contains("<f>"), "{sheet}");

    let mut updates = Vec::new();
    for row in &before.rows[..3] {
        let displayed = crate::ui::grid::value_to_display_text(&row[value_index]);
        let Value::Text(original) = &row[value_index] else {
            panic!("datetimeoffset results must retain their exact text carrier");
        };
        assert_eq!(&displayed, original);
        let parsed = parse_input_for_driver(&displayed, Some(&columns[value_index]), "mssql").unwrap();
        assert_eq!(
            parsed, row[value_index],
            "the local value, scale and offset must stay text-exact"
        );
        updates.push(
            tablepro_core::sql_dialect::build_keyed_update(
                "mssql",
                None,
                "datetimeoffset_grid",
                &columns,
                &[(value_index, parsed)],
                &[row[id_index].clone()],
            )
            .unwrap(),
        );
    }
    assert_eq!(
        connection
            .execute_in_transaction_controlled(&updates, &control)
            .await
            .unwrap(),
        vec![1, 1, 1]
    );
    let after = connection.query_controlled(select, &control).await.unwrap();
    assert_eq!(after.rows, before.rows, "edits changed offset, bytes or sibling data");
}
