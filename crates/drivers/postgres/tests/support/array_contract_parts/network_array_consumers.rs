#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_inet_and_cidr_array_bindings_and_keyed_edits_preserve_native_bytes() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let inet_expression = "'[-1:2]={192.0.2.1/24,NULL,2001:db8::1/64,192.0.2.1}'::inet[]";
    let cidr_expression = "'[0:3]={0.0.0.0/0,192.0.2.0/24,2001:db8::/32,2001:db8::1/128}'::cidr[]";
    let inet = connection
        .query(&format!(
            "SELECT {inet_expression} AS value, pg_typeof({inet_expression})::text, \
             {inet_expression}::text, array_to_json({inet_expression})::text, \
             encode(array_send({inet_expression}), 'hex')"
        ))
        .await
        .unwrap();
    let cidr = connection
        .query(&format!(
            "SELECT {cidr_expression} AS value, pg_typeof({cidr_expression})::text, \
             {cidr_expression}::text, array_to_json({cidr_expression})::text, \
             encode(array_send({cidr_expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(inet.rows[0][1], Value::Text("inet[]".into()));
    assert_eq!(inet.rows[0][0], Value::Text("[-1:2]={\"192.0.2.1/24\",NULL,\"2001:db8::1/64\",\"192.0.2.1\"}".into()));
    assert_eq!(inet.rows[0][3], Value::Text("[\"192.0.2.1/24\",null,\"2001:db8::1/64\",\"192.0.2.1\"]".into()));
    assert_eq!(cidr.rows[0][1], Value::Text("cidr[]".into()));
    assert_eq!(cidr.rows[0][0], Value::Text("[0:3]={\"0.0.0.0/0\",\"192.0.2.0/24\",\"2001:db8::/32\",\"2001:db8::1/128\"}".into()));
    assert_eq!(cidr.rows[0][3], Value::Text("[\"0.0.0.0/0\",\"192.0.2.0/24\",\"2001:db8::/32\",\"2001:db8::1/128\"]".into()));

    connection
        .execute("CREATE TABLE network_array_grid (id integer PRIMARY KEY, inet_value inet[], cidr_value cidr[], sibling text)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO network_array_grid VALUES (1, ARRAY['192.0.2.1/24'::inet], ARRAY['192.0.2.0/24'::cidr], 'target'), (2, ARRAY['192.0.2.2/24'::inet], ARRAY['192.0.2.0/25'::cidr], 'sibling')")
        .await
        .unwrap();
    connection
        .execute_params(
            "UPDATE network_array_grid SET inet_value = $1, cidr_value = $2 WHERE id = $3",
            &[inet.rows[0][0].clone(), cidr.rows[0][0].clone(), Value::Int(1)],
        )
        .await
        .expect("assignment context infers inet[] and cidr[] binary parameter types");
    let mut columns = connection.fetch_columns(None, "network_array_grid").await.unwrap();
    columns[0].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "network_array_grid",
        &columns,
        &[(1, inet.rows[0][0].clone()), (2, cidr.rows[0][0].clone())],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);
    let rows = connection
        .query("SELECT inet_value::text, encode(array_send(inet_value), 'hex'), cidr_value::text, encode(array_send(cidr_value), 'hex'), sibling FROM network_array_grid ORDER BY id")
        .await
        .unwrap();
    assert_eq!(rows.rows[0][0], inet.rows[0][2]);
    assert_eq!(rows.rows[0][1], inet.rows[0][4]);
    assert_eq!(rows.rows[0][2], cidr.rows[0][2]);
    assert_eq!(rows.rows[0][3], cidr.rows[0][4]);
    assert_eq!(rows.rows[0][4], Value::Text("target".into()));
    assert_eq!(rows.rows[1][4], Value::Text("sibling".into()));

    for (column, invalid) in [
        ("inet_value", "{192.0.2.1/33}"),
        ("cidr_value", "{192.0.2.1/24}"),
    ] {
        let error = connection
            .execute_params(
                &format!("UPDATE network_array_grid SET {column} = $1 WHERE id = $2"),
                &[Value::Text(invalid.into()), Value::Int(1)],
            )
            .await;
        assert!(error.is_err(), "invalid {column} value must be refused");
    }
    let after_invalid = connection
        .query("SELECT encode(array_send(inet_value), 'hex'), encode(array_send(cidr_value), 'hex') FROM network_array_grid WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(after_invalid.rows[0][0], inet.rows[0][4]);
    assert_eq!(after_invalid.rows[0][1], cidr.rows[0][4]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_inet_array_xlsx_preserves_native_network_text() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE inet_array_xlsx (value inet[])")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO inet_array_xlsx VALUES ('[-1:2]={192.0.2.1/24,NULL,2001:db8::1/64,192.0.2.1}'::inet[])")
        .await
        .unwrap();

    let result = connection.query("SELECT value FROM inet_array_xlsx").await.unwrap();
    assert_eq!(result.columns[0].data_type, "INET[]");
    let Value::Text(array_text) = &result.rows[0][0] else {
        panic!("inet[] XLSX source must remain text: {:?}", result.rows[0][0]);
    };
    assert_eq!(
        array_text,
        "[-1:2]={\"192.0.2.1/24\",NULL,\"2001:db8::1/64\",\"192.0.2.1\"}"
    );
    let native = connection
        .query("SELECT pg_typeof(value)::text, value::text, array_to_json(value)::text FROM inet_array_xlsx")
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text("inet[]".into()));
    assert_eq!(
        native.rows[0][1],
        Value::Text("[-1:2]={192.0.2.1/24,NULL,2001:db8::1/64,192.0.2.1}".into())
    );
    assert_eq!(native.rows[0][2], Value::Text("[\"192.0.2.1/24\",null,\"2001:db8::1/64\",\"192.0.2.1\"]".into()));

    let directory = tempfile::tempdir().unwrap();
    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("inet-array.xlsx"));
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut workbook = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut workbook.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet)
        .unwrap();
    let mut strings = String::new();
    std::io::Read::read_to_string(&mut workbook.by_name("xl/sharedStrings.xml").unwrap(), &mut strings).unwrap();
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">") && !sheet.contains("<f>"), "{sheet}");
    assert!(strings.contains(array_text), "{strings}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_cidr_array_xlsx_preserves_native_network_text() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE cidr_array_xlsx (value cidr[])")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO cidr_array_xlsx VALUES ('[-1:2]={0.0.0.0/0,NULL,192.0.2.0/24,2001:db8::/32}'::cidr[])")
        .await
        .unwrap();

    let result = connection.query("SELECT value FROM cidr_array_xlsx").await.unwrap();
    assert_eq!(result.columns[0].data_type, "CIDR[]");
    let Value::Text(array_text) = &result.rows[0][0] else {
        panic!("cidr[] XLSX source must remain text: {:?}", result.rows[0][0]);
    };
    assert_eq!(array_text, "[-1:2]={\"0.0.0.0/0\",NULL,\"192.0.2.0/24\",\"2001:db8::/32\"}");
    let native = connection
        .query("SELECT pg_typeof(value)::text, value::text, array_to_json(value)::text FROM cidr_array_xlsx")
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text("cidr[]".into()));
    assert_eq!(native.rows[0][1], Value::Text("[-1:2]={0.0.0.0/0,NULL,192.0.2.0/24,2001:db8::/32}".into()));
    assert_eq!(native.rows[0][2], Value::Text("[\"0.0.0.0/0\",null,\"192.0.2.0/24\",\"2001:db8::/32\"]".into()));

    let directory = tempfile::tempdir().unwrap();
    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("cidr-array.xlsx"));
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut workbook = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut workbook.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet)
        .unwrap();
    let mut strings = String::new();
    std::io::Read::read_to_string(&mut workbook.by_name("xl/sharedStrings.xml").unwrap(), &mut strings).unwrap();
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">") && !sheet.contains("<f>"), "{sheet}");
    assert!(strings.contains(array_text), "{strings}");
}
