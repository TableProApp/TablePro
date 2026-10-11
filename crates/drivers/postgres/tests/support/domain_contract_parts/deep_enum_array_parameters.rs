async fn assert_enum_array_parameter_depth_boundary(
    connection: &dyn Connection,
    schema: &str,
    base_type: &str,
    levels: usize,
) {
    let base_domain = format!("{schema}.{base_type}");
    let array_type = format!("{schema}.{base_type}[]");
    connection
        .execute(&format!(
            "CREATE TABLE {schema}.array_parameters \
             (id INT PRIMARY KEY, labels {array_type})"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {schema}.array_parameters VALUES \
             (1, ARRAY['ready'::{base_domain}, NULL::{base_domain}])"
        ))
        .await
        .unwrap();
    let stored = connection
        .query(&format!(
            "SELECT labels::text, pg_typeof(labels)::text, \
             encode(array_send(labels), 'hex') \
             FROM {schema}.array_parameters WHERE id = 1"
        ))
        .await
        .unwrap();

    for (parameter, native_array) in [
        (Value::Text(r#"{"ready",NULL}"#.into()), r#"'{"ready",NULL}'"#),
        (Value::Text("{}".into()), "'{}'"),
        (Value::Null, "NULL"),
    ] {
        let sql = format!(
            "SELECT id, labels = $1, pg_typeof($1)::text, encode(array_send($1), 'hex') \
             FROM {schema}.array_parameters ORDER BY id"
        );
        if levels == 63 {
            let expected = connection
                .query(&format!(
                    "SELECT id, labels = {native_array}::{array_type}, \
                     pg_typeof({native_array}::{array_type})::text, \
                     encode(array_send({native_array}::{array_type}), 'hex') \
                     FROM {schema}.array_parameters ORDER BY id"
                ))
                .await
                .unwrap();
            let actual = connection.query_params(&sql, &[parameter]).await.unwrap();
            assert_eq!(actual.rows, expected.rows, "63-level array parameter {native_array}");
        } else {
            let error = connection
                .query_params(&sql, &[parameter])
                .await
                .expect_err("64-level enum array parameters must refuse at the depth boundary");
            assert!(
                matches!(&error, tablepro_core::DriverError::Unsupported(message)
                    if message.contains("resolvable depth")),
                "64-level array parameter {native_array}: {error:?}"
            );
        }
    }
    if levels == 63 {
        let invalid = connection
            .query_params(
                &format!(
                    "SELECT labels = $1 FROM {schema}.array_parameters WHERE id = 1"
                ),
                &[Value::Text(r#"{"unknown"}"#.into())],
            )
            .await
            .expect_err("invalid labels must reach PostgreSQL at the supported depth");
        assert!(
            matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. }
                if code == "22P02"),
            "63-level invalid enum label: {invalid:?}"
        );
    }
    let after = connection
        .query(&format!(
            "SELECT labels::text, pg_typeof(labels)::text, \
             encode(array_send(labels), 'hex') \
             FROM {schema}.array_parameters WHERE id = 1"
        ))
        .await
        .unwrap();
    assert_eq!(after.rows, stored.rows, "{levels}-level enum array target changed");
}
