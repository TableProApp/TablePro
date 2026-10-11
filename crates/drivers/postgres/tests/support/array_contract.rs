#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{Connection, OperationControl, QueryResult, Value};
use tokio_util::sync::CancellationToken;

pub async fn assert_array_contract(connection: &dyn Connection) {
    let control = OperationControl::new(CancellationToken::new(), None);
    let mut session = connection.open_session().await.unwrap();
    session
        .query_params_controlled("SET TIME ZONE 'Asia/Kathmandu'", &[], &control)
        .await
        .unwrap();
    for (kind, expression) in [
        ("int4[]", "NULL::int4[]"),
        ("int4[]", "ARRAY[]::int4[]"),
        ("int4[]", "'{{{{{{1,NULL}}}}}}'::int4[]"),
        (
            "name[]",
            "ARRAY['alpha'::name, ''::name, NULL::name, 'NULL'::name, 'a,b'::name, \
             'a\"b'::name, E'slash\\\\path'::name, '東京'::name, (repeat('x',61) || 'é')::name]",
        ),
        ("oid[]", "ARRAY[0,4294967295,NULL]::oid[]"),
        ("int4[]", "ARRAY[1,NULL,-2147483648,2147483647]"),
        ("int2[]", "ARRAY[-32768,0,32767]::int2[]"),
        ("int8[]", "ARRAY[-9223372036854775808,9223372036854775807]::int8[]"),
        ("int4[]", "'[0:1][-2:0]={{1,NULL,3},{4,5,6}}'::int4[]"),
        (
            "text[]",
            "ARRAY[NULL,'NULL','null','','{}','a,b',' leading ', '漢字 😀', $$a\"b$$, $$a\\b$$, E'line\nnext', $$x'); DROP TABLE t; --$$]",
        ),
        ("text[]", "ARRAY[['a',NULL],['','NULL']]"),
        (
            "xml[]",
            "ARRAY[XMLPARSE(CONTENT '<a>one,two</a>'), \
             XMLPARSE(CONTENT '<b attr=\"quoted\">東京 &amp; 😀</b>'), NULL]::xml[]",
        ),
        ("xml[]", "NULL::xml[]"),
        ("xml[]", "ARRAY[]::xml[]"),
        ("xml[]", "$$[0:1]={\"<root/>\",NULL}$$::xml[]"),
        ("varchar[]", "ARRAY['x','',NULL]::varchar[]"),
        ("bpchar[]", "ARRAY['x',' y']::char(3)[]"),
        (
            "numeric[]",
            "ARRAY[1234567890123456789012345678901234567890,0.123456789012345678901234567891,1.2300,NULL,'NaN'::numeric,'Infinity'::numeric]",
        ),
        ("bool[]", "ARRAY[true,false,NULL]"),
        (
            "float4[]",
            "ARRAY[0.1,'-0','NaN','Infinity','-Infinity',NULL]::float4[]",
        ),
        (
            "float8[]",
            "ARRAY[1e-200,1.0000000000000002,'-0','NaN','Infinity',NULL]::float8[]",
        ),
        ("uuid[]", "ARRAY['12345678-1234-5678-90ab-1234567890ab',NULL]::uuid[]"),
        ("bytea[]", "ARRAY[decode('00ff275c','hex'),decode('','hex'),NULL]"),
        (
            "date[]",
            "ARRAY['0002-12-31 BC','10000-01-01','infinity','-infinity',NULL]::date[]",
        ),
        ("time[]", "ARRAY['00:00:00','24:00:00','23:59:59.999999',NULL]::time[]"),
        (
            "timetz[]",
            "ARRAY['00:00:00+15:59:59','24:00:00-15:59:59',NULL]::timetz[]",
        ),
        (
            "timestamp[]",
            "ARRAY['0001-01-01 00:00:00.000001 BC','10000-01-01 23:59:59.999999','infinity','-infinity',NULL]::timestamp[]",
        ),
        (
            "timestamptz[]",
            "ARRAY['2024-11-03 01:30:00-04','2024-11-03 01:30:00-05','0001-01-01 12:34:56+00 BC','infinity','-infinity',NULL]::timestamptz[]",
        ),
        (
            "date[]",
            "'[0:1][-1:0]={{2000-01-01,NULL},{infinity,-infinity}}'::date[]",
        ),
        (
            "interval[]",
            "ARRAY['-1 month +2 days +0.000001 seconds','+1 month -2 days -0.000001 seconds','-9223372036854.775808 seconds',NULL]::interval[]",
        ),
        (
            "pg_lsn[]",
            "'[0:4]={0/0,0/FFFFFFFF,1/0,FFFFFFFF/FFFFFFFF,NULL}'::pg_lsn[]",
        ),
        ("inet[]", "'[0:3]={192.0.2.1/24,NULL,2001:db8::1/64,192.0.2.1}'::inet[]"),
        (
            "cidr[]",
            "'[0:3]={0.0.0.0/0,192.0.2.0/24,2001:db8::/32,2001:db8::1/128}'::cidr[]",
        ),
        (
            "macaddr[]",
            "'[0:2]={08:00:2b:01:02:03,NULL,AA:BB:CC:DD:EE:FF}'::macaddr[]",
        ),
        (
            "macaddr8[]",
            "'[0:2]={08:00:2b:01:02:03:04:05,NULL,AA:BB:CC:DD:EE:FF:00:11}'::macaddr8[]",
        ),
    ] {
        let sql = format!("SELECT ({expression}) AS value, encode(array_send({expression}), 'hex') AS wire");
        let result = connection.query(&sql).await.unwrap();
        assert_array_value(kind, &result);
        crate::wire_round_trip::assert_wire_round_trip(
            session.as_mut(),
            &control,
            kind,
            &result.columns[0],
            &result.rows[0][0],
            &result.rows[0][1],
        )
        .await;
        let session_result = session.query_params_controlled(&sql, &[], &control).await.unwrap();
        assert_eq!(session_result.rows, result.rows, "{kind}: session");
        assert_eq!(session_result.columns[0].data_type, result.columns[0].data_type);
        let bound = session
            .query_params_controlled(
                &format!("SELECT encode(array_send($1::text::{kind}), 'hex')"),
                &result.rows[0][..1],
                &control,
            )
            .await
            .unwrap();
        assert_eq!(bound.rows[0][0], result.rows[0][1], "{kind}: non-UTC session import");
    }
}

include!("array_contract_parts/result_consumers_text.rs");
include!("array_contract_parts/xml_array_file_exports.rs");
include!("array_contract_parts/result_consumers_numeric.rs");
include!("array_contract_parts/result_consumers_temporal.rs");
include!("array_contract_parts/result_consumers_timestamp_dmy.rs");
include!("array_contract_parts/result_consumers_timestamptz_timezone.rs");
include!("array_contract_parts/network_array_consumers.rs");
include!("array_contract_parts/citext_array_consumers.rs");
include!("array_contract_parts/bit_array_consumers.rs");

include!("array_contract_parts/enum_consumers.rs");
include!("array_contract_parts/enum_array_slices.rs");

include!("array_contract_parts/enum_catalog_changes.rs");

include!("array_contract_parts/enum_array_file_consumers.rs");

pub async fn assert_array_grid_edit(connection: &dyn Connection) {
    connection
        .execute("CREATE TABLE array_grid_edit (id integer PRIMARY KEY, value integer[])")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO array_grid_edit VALUES (1, ARRAY[1,2])")
        .await
        .unwrap();
    let mut row = connection.query("SELECT * FROM array_grid_edit").await.unwrap();
    row.columns[0].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "array_grid_edit",
        &row.columns,
        &[(1, Value::Text("{3,NULL,5}".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);
    let updated = connection
        .query("SELECT value = ARRAY[3,NULL,5]::integer[] FROM array_grid_edit WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(updated.rows, vec![vec![Value::Bool(true)]]);

    const TEXT_ARRAY: &str = r#"{"plain",NULL,"quote \" slash \\, comma"}"#;
    connection
        .execute("CREATE TABLE text_array_grid_edit (id integer PRIMARY KEY, value text[])")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO text_array_grid_edit VALUES (1, ARRAY['before']::text[])")
        .await
        .unwrap();
    let mut row = connection.query("SELECT * FROM text_array_grid_edit").await.unwrap();
    let id_index = row.columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = row.columns.iter().position(|column| column.name == "value").unwrap();
    row.columns[id_index].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "text_array_grid_edit",
        &row.columns,
        &[(value_index, Value::Text(TEXT_ARRAY.into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let elements = connection
        .query("SELECT ordinality, item IS NULL, item FROM text_array_grid_edit CROSS JOIN LATERAL unnest(text_array_grid_edit.value) WITH ORDINALITY AS element(item, ordinality) ORDER BY ordinality")
        .await
        .unwrap();
    assert_eq!(
        elements.rows,
        vec![
            vec![Value::Int(1), Value::Bool(false), Value::Text("plain".into())],
            vec![Value::Int(2), Value::Bool(true), Value::Null],
            vec![
                Value::Int(3),
                Value::Bool(false),
                Value::Text("quote \" slash \\, comma".into()),
            ],
        ]
    );

    const NAME_ARRAY: &str = r#"{"",NULL,"NULL","a,b","a\"b","slash\\path","東京"}"#;
    connection
        .execute("CREATE TABLE name_array_grid_edit (id integer PRIMARY KEY, value name[], sibling text NOT NULL)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO name_array_grid_edit VALUES \
             (1, ARRAY['before']::name[], 'target sibling'), \
             (2, ARRAY['keep']::name[], 'sibling row')",
        )
        .await
        .unwrap();
    let mut name_rows = connection
        .query("SELECT * FROM name_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    let id_index = name_rows.columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = name_rows
        .columns
        .iter()
        .position(|column| column.name == "value")
        .unwrap();
    name_rows.columns[id_index].primary_key = true;
    let sibling_wire_before = connection
        .query("SELECT encode(array_send(value), 'hex') FROM name_array_grid_edit WHERE id = 2")
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "name_array_grid_edit",
        &name_rows.columns,
        &[(value_index, Value::Text(NAME_ARRAY.into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(update_sql.contains("$1::text::pg_catalog.name[]"), "{update_sql}");
    assert_eq!(
        connection
            .execute_in_transaction(&[(update_sql, update_params)])
            .await
            .unwrap(),
        vec![1]
    );
    let native = connection
        .query(
            "SELECT pg_typeof(value)::text, value::text, encode(array_send(value), 'hex'), sibling \
             FROM name_array_grid_edit WHERE id = 1",
        )
        .await
        .unwrap();
    let oracle = connection
        .query(
            r#"SELECT pg_typeof(expected)::text, expected::text, encode(array_send(expected), 'hex'), 'target sibling'
               FROM (SELECT ARRAY[''::name, NULL, 'NULL'::name, 'a,b'::name, 'a"b'::name,
                                  'slash\path'::name, '東京'::name]::name[] AS expected) source"#,
        )
        .await
        .unwrap();
    assert_eq!(native.rows, oracle.rows);
    assert_eq!(native.rows[0][0], Value::Text("name[]".into()));
    let sibling = connection
        .query("SELECT encode(array_send(value), 'hex'), sibling FROM name_array_grid_edit WHERE id = 2")
        .await
        .unwrap();
    assert_eq!(sibling.rows[0][1], Value::Text("sibling row".into()));
    assert_eq!(sibling.rows[0][0], sibling_wire_before);

    const XML_ARRAY: &str = r#"{"<a>one,two</a>","<b attr=\"quoted\">東京 &amp; 😀</b>",NULL}"#;
    connection
        .execute("CREATE TABLE xml_array_grid_edit (id integer PRIMARY KEY, value xml[], sibling text NOT NULL)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO xml_array_grid_edit VALUES \
             (1, ARRAY[XMLPARSE(CONTENT '<old/>')], 'target sibling'), \
             (2, ARRAY[XMLPARSE(CONTENT '<keep/>')], 'sibling row')",
        )
        .await
        .unwrap();
    let mut xml_rows = connection
        .query("SELECT * FROM xml_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    let id_index = xml_rows.columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = xml_rows
        .columns
        .iter()
        .position(|column| column.name == "value")
        .unwrap();
    xml_rows.columns[id_index].primary_key = true;
    let sibling_wire_before = connection
        .query("SELECT encode(array_send(value), 'hex') FROM xml_array_grid_edit WHERE id = 2")
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "xml_array_grid_edit",
        &xml_rows.columns,
        &[(value_index, Value::Text(XML_ARRAY.into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(update_sql.contains("$1::text::pg_catalog.xml[]"), "{update_sql}");
    assert_eq!(
        connection
            .execute_in_transaction(&[(update_sql.clone(), update_params)])
            .await
            .unwrap(),
        vec![1]
    );
    let native = connection
        .query(
            "SELECT pg_typeof(value)::text, value::text, encode(array_send(value), 'hex'), sibling \
             FROM xml_array_grid_edit WHERE id = 1",
        )
        .await
        .unwrap();
    let oracle = connection
        .query(
            "SELECT pg_typeof(expected)::text, expected::text, encode(array_send(expected), 'hex'), 'target sibling' \
             FROM (SELECT ARRAY[XMLPARSE(CONTENT '<a>one,two</a>'), \
                               XMLPARSE(CONTENT '<b attr=\"quoted\">東京 &amp; 😀</b>'), NULL]::xml[] AS expected) source",
        )
        .await
        .unwrap();
    assert_eq!(native.rows, oracle.rows);
    assert_eq!(native.rows[0][0], Value::Text("xml[]".into()));
    let sibling = connection
        .query("SELECT encode(array_send(value), 'hex'), sibling FROM xml_array_grid_edit WHERE id = 2")
        .await
        .unwrap();
    assert_eq!(sibling.rows[0][1], Value::Text("sibling row".into()));
    assert_eq!(sibling.rows[0][0], sibling_wire_before);

    let invalid_xml = connection
        .query_params(
            "UPDATE xml_array_grid_edit SET value = $1 WHERE id = 1",
            &[Value::Text(r#"{"<broken>"}"#.into())],
        )
        .await
        .unwrap_err();
    assert!(
        matches!(&invalid_xml, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "2200N"),
        "expected native XML parse refusal, got {invalid_xml:?}"
    );
    let after_refusal = connection
        .query("SELECT encode(array_send(value), 'hex'), sibling FROM xml_array_grid_edit WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(
        after_refusal.rows,
        native
            .rows
            .iter()
            .map(|row| vec![row[2].clone(), row[3].clone()])
            .collect::<Vec<_>>()
    );

    assert_bool_array_grid_edit(connection).await;
    assert_bytea_array_grid_edit(connection).await;
    assert_uuid_array_grid_edit(connection).await;
    assert_timestamptz_array_grid_edit(connection).await;
    assert_oid_array_grid_edit(connection).await;
}

async fn assert_oid_array_grid_edit(connection: &dyn Connection) {
    connection
        .execute("CREATE TABLE oid_array_grid_edit (id integer PRIMARY KEY, value oid[], sibling text NOT NULL)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO oid_array_grid_edit VALUES \
             (1, ARRAY[1::oid], 'target sibling'), (2, ARRAY[7::oid], 'sibling row')",
        )
        .await
        .unwrap();
    let mut rows = connection
        .query("SELECT * FROM oid_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    let id_index = rows.columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = rows.columns.iter().position(|column| column.name == "value").unwrap();
    rows.columns[id_index].primary_key = true;
    let sibling_wire_before = connection
        .query("SELECT encode(array_send(value), 'hex') FROM oid_array_grid_edit WHERE id = 2")
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "oid_array_grid_edit",
        &rows.columns,
        &[(value_index, Value::Text("{0,4294967295,NULL}".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(update_sql.contains("$1::text::pg_catalog.oid[]"), "{update_sql}");
    assert_eq!(
        connection
            .execute_in_transaction(&[(update_sql, update_params)])
            .await
            .unwrap(),
        vec![1]
    );
    let native = connection
        .query(
            "SELECT pg_typeof(value)::text, value::text, encode(array_send(value), 'hex'), sibling \
             FROM oid_array_grid_edit WHERE id = 1",
        )
        .await
        .unwrap();
    let oracle = connection
        .query(
            "SELECT pg_typeof(expected)::text, expected::text, encode(array_send(expected), 'hex'), 'target sibling' \
             FROM (SELECT ARRAY[0::oid, 4294967295::oid, NULL]::oid[] AS expected) source",
        )
        .await
        .unwrap();
    assert_eq!(native.rows, oracle.rows);
    assert_eq!(native.rows[0][0], Value::Text("oid[]".into()));
    let sibling = connection
        .query("SELECT encode(array_send(value), 'hex'), sibling FROM oid_array_grid_edit WHERE id = 2")
        .await
        .unwrap();
    assert_eq!(sibling.rows[0][1], Value::Text("sibling row".into()));
    assert_eq!(sibling.rows[0][0], sibling_wire_before);
}

async fn assert_bool_array_grid_edit(connection: &dyn Connection) {
    connection
        .execute("CREATE TABLE bool_array_grid_edit (id integer PRIMARY KEY, value boolean[])")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO bool_array_grid_edit VALUES (1, ARRAY[true]::boolean[]), (2, ARRAY[false]::boolean[])")
        .await
        .unwrap();
    let mut rows = connection
        .query("SELECT * FROM bool_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    let sibling_wire = connection
        .query("SELECT encode(array_send(value), 'hex') FROM bool_array_grid_edit WHERE id = 2")
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let id_index = rows.columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = rows.columns.iter().position(|column| column.name == "value").unwrap();
    rows.columns[id_index].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "bool_array_grid_edit",
        &rows.columns,
        &[(value_index, Value::Text("{true,false,NULL}".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let expected = connection
        .query("SELECT ARRAY[true,false,NULL]::boolean[]::text, encode(array_send(ARRAY[true,false,NULL]::boolean[]), 'hex')")
        .await
        .unwrap();
    let actual = connection
        .query("SELECT id, value::text, encode(array_send(value), 'hex') FROM bool_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    assert_eq!(actual.rows[0][0], Value::Int(1));
    assert_eq!(actual.rows[0][1], expected.rows[0][0]);
    assert_eq!(actual.rows[0][2], expected.rows[0][1]);
    assert_eq!(actual.rows[1][0], Value::Int(2));
    assert_eq!(actual.rows[1][2], sibling_wire);
}

async fn assert_bytea_array_grid_edit(connection: &dyn Connection) {
    const ARRAY: &str = r#"{"\\x00ff","\\x5c5c","",NULL}"#;
    const ORACLE: &str = "ARRAY[decode('00ff','hex'),decode('5c5c','hex'),decode('','hex'),NULL]::bytea[]";

    connection
        .execute("CREATE TABLE bytea_array_grid_edit (id integer PRIMARY KEY, value bytea[])")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO bytea_array_grid_edit VALUES (1, ARRAY[decode('01','hex')]), (2, ARRAY[decode('1234','hex')])",
        )
        .await
        .unwrap();
    let mut rows = connection
        .query("SELECT * FROM bytea_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    let sibling_wire = connection
        .query("SELECT encode(array_send(value), 'hex') FROM bytea_array_grid_edit WHERE id = 2")
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let id_index = rows.columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = rows.columns.iter().position(|column| column.name == "value").unwrap();
    rows.columns[id_index].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "bytea_array_grid_edit",
        &rows.columns,
        &[(value_index, Value::Text(ARRAY.into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let expected = connection
        .query(&format!("SELECT encode(array_send({ORACLE}), 'hex')"))
        .await
        .unwrap();
    let actual = connection
        .query("SELECT id, encode(array_send(value), 'hex') FROM bytea_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    assert_eq!(actual.rows[0][0], Value::Int(1));
    assert_eq!(actual.rows[0][1], expected.rows[0][0]);
    assert_eq!(actual.rows[1][0], Value::Int(2));
    assert_eq!(actual.rows[1][1], sibling_wire);
}

async fn assert_uuid_array_grid_edit(connection: &dyn Connection) {
    const ARRAY: &str = "{550e8400-e29b-41d4-a716-446655440000,6ba7b810-9dad-11d1-80b4-00c04fd430c8,NULL}";
    const ORACLE: &str =
        "ARRAY['550e8400-e29b-41d4-a716-446655440000'::uuid,'6ba7b810-9dad-11d1-80b4-00c04fd430c8'::uuid,NULL]::uuid[]";

    connection
        .execute("CREATE TABLE uuid_array_grid_edit (id integer PRIMARY KEY, value uuid[])")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO uuid_array_grid_edit VALUES (1, ARRAY['00000000-0000-0000-0000-000000000001'::uuid]), (2, ARRAY['00000000-0000-0000-0000-000000000002'::uuid])")
        .await
        .unwrap();
    let mut rows = connection
        .query("SELECT * FROM uuid_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    let sibling_wire = connection
        .query("SELECT encode(array_send(value), 'hex') FROM uuid_array_grid_edit WHERE id = 2")
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let id_index = rows.columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = rows.columns.iter().position(|column| column.name == "value").unwrap();
    rows.columns[id_index].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "uuid_array_grid_edit",
        &rows.columns,
        &[(value_index, Value::Text(ARRAY.into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let expected = connection
        .query(&format!("SELECT encode(array_send({ORACLE}), 'hex')"))
        .await
        .unwrap();
    let actual = connection
        .query("SELECT id, encode(array_send(value), 'hex') FROM uuid_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    assert_eq!(actual.rows[0][0], Value::Int(1));
    assert_eq!(actual.rows[0][1], expected.rows[0][0]);
    assert_eq!(actual.rows[1][0], Value::Int(2));
    assert_eq!(actual.rows[1][1], sibling_wire);
}

async fn assert_timestamptz_array_grid_edit(connection: &dyn Connection) {
    const ARRAY: &str = r#"{"2026-09-30 12:34:56.123456+05:30","1999-12-31 23:59:59.000001-07:00",NULL}"#;
    const ORACLE: &str = "ARRAY['2026-09-30 12:34:56.123456+05:30'::timestamptz,'1999-12-31 23:59:59.000001-07:00'::timestamptz,NULL]::timestamptz[]";

    connection
        .execute("CREATE TABLE timestamptz_array_grid_edit (id integer PRIMARY KEY, value timestamptz[])")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO timestamptz_array_grid_edit VALUES (1, ARRAY['2000-01-01 00:00:00+00'::timestamptz]), (2, ARRAY['2001-01-01 00:00:00+00'::timestamptz])")
        .await
        .unwrap();
    let mut rows = connection
        .query("SELECT * FROM timestamptz_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    let sibling_wire = connection
        .query("SELECT encode(array_send(value), 'hex') FROM timestamptz_array_grid_edit WHERE id = 2")
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let id_index = rows.columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = rows.columns.iter().position(|column| column.name == "value").unwrap();
    rows.columns[id_index].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "timestamptz_array_grid_edit",
        &rows.columns,
        &[(value_index, Value::Text(ARRAY.into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let expected = connection
        .query(&format!("SELECT encode(array_send({ORACLE}), 'hex')"))
        .await
        .unwrap();
    let actual = connection
        .query("SELECT id, encode(array_send(value), 'hex') FROM timestamptz_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    assert_eq!(actual.rows[0][0], Value::Int(1));
    assert_eq!(actual.rows[0][1], expected.rows[0][0]);
    assert_eq!(actual.rows[1][0], Value::Int(2));
    assert_eq!(actual.rows[1][1], sibling_wire);
}

pub async fn assert_float8_array_grid_edit(connection: &dyn Connection) {
    const ARRAY: &str = "{1.0000000000000002,-0,5e-324,NaN,Infinity,-Infinity,NULL}";
    const ORACLE: &str = "ARRAY[1.0000000000000002::float8, '-0'::float8, '5e-324'::float8, \
        'NaN'::float8, 'Infinity'::float8, '-Infinity'::float8, NULL::float8]";

    connection
        .execute("CREATE TABLE float8_array_grid_edit (id integer PRIMARY KEY, value float8[])")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO float8_array_grid_edit VALUES (1, ARRAY[0]::float8[]), (2, ARRAY[77]::float8[]), (3, ARRAY[88]::float8[])")
        .await
        .unwrap();
    let mut row = connection
        .query("SELECT * FROM float8_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    let id_index = row.columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = row.columns.iter().position(|column| column.name == "value").unwrap();
    row.columns[id_index].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "float8_array_grid_edit",
        &row.columns,
        &[(value_index, Value::Text(ARRAY.into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let expected = connection
        .query(&format!(
            "SELECT ({ORACLE})::text, encode(array_send(({ORACLE})::float8[]), 'hex')"
        ))
        .await
        .unwrap();
    let actual = connection
        .query(
            "SELECT id, value, value::text, encode(array_send(value), 'hex') \
             FROM float8_array_grid_edit ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(actual.rows[0][0], Value::Int(1));
    let Value::Text(native_text) = &expected.rows[0][0] else {
        panic!("native float8[] text oracle must be text: {:?}", expected.rows[0][0]);
    };
    let Value::Text(decoded_text) = &actual.rows[0][1] else {
        panic!("float8[] result must remain exact text: {:?}", actual.rows[0][1]);
    };
    assert_eq!(&actual.rows[0][2..], expected.rows[0].as_slice());
    assert_eq!(
        actual.rows[1][0],
        Value::Int(2),
        "the sibling row identity remains intact"
    );
    assert!(matches!(actual.rows[1][1], Value::Text(_)));

    assert_float8_array_csv_round_trip(connection, &actual, native_text, decoded_text).await;
}

async fn assert_float8_array_csv_round_trip(
    connection: &dyn Connection,
    result: &QueryResult,
    native_text: &str,
    decoded_text: &str,
) {
    let columns = vec![result.columns[0].clone(), result.columns[1].clone()];
    let row = vec![result.rows[0][0].clone(), result.rows[0][1].clone()];
    let csv_text = tablepro_core::export::render_csv(
        &columns,
        std::slice::from_ref(&row),
        &tablepro_core::export::CsvOptions::default(),
    );
    let mut reader = csv::Reader::from_reader(csv_text.as_bytes());
    assert_eq!(reader.headers().unwrap().iter().collect::<Vec<_>>(), ["id", "value"]);
    let exported = reader.records().next().unwrap().unwrap();
    assert_eq!(
        &exported[1], decoded_text,
        "CSV must preserve the driver's exact float8[] value text"
    );
    assert!(reader.records().next().is_none());

    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv_text.as_bytes(), &options, None).unwrap();
    let imported =
        tablepro_core::import::row_to_values(&sheet.rows[0], &[Some(0), Some(1)], &columns, &options, 2).unwrap();
    assert_eq!(imported, row, "CSV import must retain the array as exact text");

    connection
        .execute("CREATE TABLE float8_array_csv_import (id integer PRIMARY KEY, value float8[])")
        .await
        .unwrap();
    let import_columns = connection.fetch_columns(None, "float8_array_csv_import").await.unwrap();
    let import_mapping = [Some(0), Some(1)];
    let mut import_row = row.clone();
    import_row[0] = Value::Int(4);
    let import_csv = tablepro_core::export::render_csv(
        &columns,
        std::slice::from_ref(&import_row),
        &tablepro_core::export::CsvOptions::default(),
    );
    let import_sheet = tablepro_core::import::read_csv(import_csv.as_bytes(), &options, None).unwrap();
    let insert_plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "float8_array_csv_import",
            columns: &import_columns,
            mapping: &import_mapping,
        },
        &import_sheet,
        &options,
    )
    .expect("float8[] CSV should build an import plan");
    connection
        .execute_params(&insert_plan.statement, &insert_plan.rows[0])
        .await
        .expect("typed float8[] CSV import must cast array text to the native column type");
    let csv_restored = connection
        .query("SELECT id, value::text, encode(array_send(value), 'hex') FROM float8_array_csv_import")
        .await
        .unwrap();
    assert_eq!(
        csv_restored.rows,
        vec![vec![
            Value::Int(4),
            Value::Text(native_text.into()),
            result.rows[0][3].clone(),
        ]],
        "CSV import must preserve PostgreSQL array text and native wire bytes"
    );

    let mut update_columns = columns;
    update_columns[0].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "float8_array_grid_edit",
        &update_columns,
        &[(1, imported[1].clone())],
        &[Value::Int(2)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);
    let restored = connection
        .query("SELECT id, value::text, encode(array_send(value), 'hex') FROM float8_array_grid_edit ORDER BY id")
        .await
        .unwrap();
    assert_eq!(restored.rows[0][0], Value::Int(1));
    assert_eq!(restored.rows[1][0], Value::Int(2));
    assert_eq!(restored.rows[1][1], Value::Text(native_text.into()));
    assert_eq!(restored.rows[1][2], restored.rows[0][2]);
    assert_eq!(restored.rows[2][0], Value::Int(3));
    assert_eq!(restored.rows[2][2], result.rows[2][3]);
}

async fn assert_array_csv_insert_contract(connection: &dyn Connection) {
    let cases = [
        ("bool[]", "ARRAY[true,false,NULL]::bool[]"),
        (
            "xml[]",
            "ARRAY[XMLPARSE(CONTENT '<a>one,two</a>'), \
             XMLPARSE(CONTENT '<b attr=\"quoted\">東京 &amp; 😀</b>'), NULL]::xml[]",
        ),
        ("xml[]", "$$[0:1]={\"<root/>\",NULL}$$::xml[]"),
        ("bytea[]", "ARRAY[decode('00ff275c','hex'),decode('','hex'),NULL]"),
        (
            "name[]",
            "ARRAY['alpha'::name, ''::name, NULL::name, 'NULL'::name, 'a,b'::name, \
             'a\"b'::name, E'slash\\\\path'::name, '東京'::name, (repeat('x',61) || 'é')::name]",
        ),
        ("int2[]", "ARRAY[-32768,0,32767]::int2[]"),
        ("int4[]", "ARRAY[-2147483648,0,2147483647]::int4[]"),
        ("int8[]", "ARRAY[-9223372036854775808,0,9223372036854775807]::int8[]"),
        ("oid[]", "ARRAY[0,4294967295,NULL]::oid[]"),
        ("text[]", "ARRAY[NULL,'NULL','','a,b','漢字 😀',E'line\\nnext']::text[]"),
        (
            "float4[]",
            "ARRAY[0.1,'-0','1e-45','NaN','Infinity','-Infinity',NULL]::float4[]",
        ),
        (
            "float8[]",
            "ARRAY[1e-200,1.0000000000000002,'-0','5e-324','NaN','Infinity','-Infinity',NULL]::float8[]",
        ),
        ("varchar[]", "ARRAY['x','',NULL]::varchar[]"),
        ("char(3)[]", "ARRAY['x',' y',NULL]::char(3)[]"),
        (
            "numeric[]",
            "ARRAY[1234567890123456789012345678901234567890,1.2300,'NaN'::numeric,'Infinity'::numeric,NULL]",
        ),
        ("uuid[]", "ARRAY['12345678-1234-5678-90ab-1234567890ab',NULL]::uuid[]"),
        (
            "date[]",
            "ARRAY['0002-12-31 BC','10000-01-01','infinity','-infinity',NULL]::date[]",
        ),
        ("time[]", "ARRAY['00:00:00','24:00:00','23:59:59.999999',NULL]::time[]"),
        (
            "timetz[]",
            "ARRAY['00:00:00+15:59:59','24:00:00-15:59:59',NULL]::timetz[]",
        ),
        (
            "timestamp[]",
            "ARRAY['0001-01-01 00:00:00.000001 BC','10000-01-01 23:59:59.999999','infinity','-infinity',NULL]::timestamp[]",
        ),
        (
            "timestamptz[]",
            "ARRAY['2024-11-03 01:30:00-04','2024-11-03 01:30:00-05','infinity','-infinity',NULL]::timestamptz[]",
        ),
        (
            "interval[]",
            "ARRAY['-1 month +2 days +0.000001 seconds','+1 month -2 days -0.000001 seconds',NULL]::interval[]",
        ),
        (
            "pg_lsn[]",
            "'[0:4]={0/0,0/FFFFFFFF,1/0,FFFFFFFF/FFFFFFFF,NULL}'::pg_lsn[]",
        ),
        ("inet[]", "'[0:3]={192.0.2.1/24,NULL,2001:db8::1/64,192.0.2.1}'::inet[]"),
        (
            "cidr[]",
            "'[0:3]={0.0.0.0/0,192.0.2.0/24,2001:db8::/32,2001:db8::1/128}'::cidr[]",
        ),
        (
            "macaddr[]",
            "'[0:2]={08:00:2b:01:02:03,NULL,AA:BB:CC:DD:EE:FF}'::macaddr[]",
        ),
        (
            "macaddr8[]",
            "'[0:2]={08:00:2b:01:02:03:04:05,NULL,AA:BB:CC:DD:EE:FF:00:11}'::macaddr8[]",
        ),
    ];
    let definitions = cases
        .iter()
        .enumerate()
        .map(|(index, (kind, _))| format!("value_{index} {kind}"))
        .collect::<Vec<_>>()
        .join(", ");
    let expressions = cases
        .iter()
        .enumerate()
        .map(|(index, (_, expression))| format!("({expression}) AS value_{index}"))
        .collect::<Vec<_>>()
        .join(", ");
    connection
        .execute(&format!("CREATE TABLE array_csv_source AS SELECT {expressions}"))
        .await
        .unwrap();
    connection
        .execute(&format!("CREATE TABLE array_csv_target ({definitions})"))
        .await
        .unwrap();

    let source = connection.query("SELECT * FROM array_csv_source").await.unwrap();
    let wire_columns = cases
        .iter()
        .enumerate()
        .map(|(index, _)| format!("encode(array_send(value_{index}), 'hex')"))
        .collect::<Vec<_>>()
        .join(", ");
    let source_wire = connection
        .query(&format!("SELECT {wire_columns} FROM array_csv_source"))
        .await
        .unwrap();
    let csv_text = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv_text.as_bytes(), &options, None).unwrap();
    let columns = connection.fetch_columns(None, "array_csv_target").await.unwrap();
    let mapping = (0..columns.len()).map(Some).collect::<Vec<_>>();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "array_csv_target",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &options,
    )
    .expect("every allowlisted built-in array should produce a typed CSV INSERT plan");
    assert_eq!(plan.rows, source.rows, "array CSV parsing preserves exact text cells");
    connection
        .execute_params(&plan.statement, &plan.rows[0])
        .await
        .expect("typed PostgreSQL array CSV INSERT must cast every text cell to its array type");

    let target_wire = connection
        .query(&format!("SELECT {wire_columns} FROM array_csv_target"))
        .await
        .unwrap();
    let target = connection.query("SELECT * FROM array_csv_target").await.unwrap();
    assert_eq!(
        target_wire.rows, source_wire.rows,
        "native array_send bytes after CSV INSERT"
    );
    assert_eq!(target.rows, source.rows, "native array text after CSV INSERT");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_builtin_array_families_survive_typed_csv_insert() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    assert_array_csv_insert_contract(connection.as_ref()).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_float8_array_grid_edit_preserves_special_and_adjacent_values() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    assert_float8_array_grid_edit(connection.as_ref()).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_array_grid_edit_preserves_array_elements() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    assert_array_grid_edit(connection.as_ref()).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_numeric_array_grid_edit_preserves_elements() {
    const NUMERIC_ARRAY: &str =
        "{1234567890123456789012345678901234567890.12345678901234567890,1.2300,NaN,Infinity,-Infinity,NULL}";
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE numeric_array_grid_edit (id integer PRIMARY KEY, value numeric[])")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO numeric_array_grid_edit VALUES (1, ARRAY[0]::numeric[])")
        .await
        .unwrap();
    let mut row = connection.query("SELECT * FROM numeric_array_grid_edit").await.unwrap();
    let id_index = row.columns.iter().position(|column| column.name == "id").unwrap();
    let value_index = row.columns.iter().position(|column| column.name == "value").unwrap();
    row.columns[id_index].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "numeric_array_grid_edit",
        &row.columns,
        &[(value_index, Value::Text(NUMERIC_ARRAY.into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let elements = connection
        .query("SELECT ordinality, item IS NULL, item::text FROM numeric_array_grid_edit CROSS JOIN LATERAL unnest(numeric_array_grid_edit.value) WITH ORDINALITY AS element(item, ordinality) ORDER BY ordinality")
        .await
        .unwrap();
    assert_eq!(
        elements.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Bool(false),
                Value::Text("1234567890123456789012345678901234567890.12345678901234567890".into()),
            ],
            vec![Value::Int(2), Value::Bool(false), Value::Text("1.2300".into())],
            vec![Value::Int(3), Value::Bool(false), Value::Text("NaN".into())],
            vec![Value::Int(4), Value::Bool(false), Value::Text("Infinity".into())],
            vec![Value::Int(5), Value::Bool(false), Value::Text("-Infinity".into())],
            vec![Value::Int(6), Value::Bool(true), Value::Null],
        ]
    );
}

fn assert_array_value(kind: &str, result: &QueryResult) {
    let value = &result.rows[0][0];
    assert!(matches!(value, Value::Null | Value::Text(_)), "{kind}: {value:?}");
    let expected_type = match kind {
        "bpchar[]" => "CHAR[]".into(),
        "pg_lsn[]" => "pg_lsn[]".into(),
        "xml[]" => "xml[]".into(),
        _ => kind.to_ascii_uppercase(),
    };
    assert_eq!(result.columns[0].data_type, expected_type);
    let json = tablepro_core::export::row_to_json(&result.columns, &result.rows[0]);
    match value {
        Value::Null => assert!(json["value"].is_null()),
        Value::Text(text) => assert_eq!(json["value"].as_str(), Some(text.as_str())),
        other => panic!("unexpected array value: {other:?}"),
    }
}
