use tablepro_core::Value;

#[tokio::test]
async fn value_contract_query_preserves_uuid_kinds_in_mixed_multirow_projection() {
    let connection = super::native_connection().await;
    let result = connection
        .query(
            "SELECT 'first'::VARCHAR AS label, '12345678-9abc-def0-1122-334455667788'::UUID AS id, \
             NULL::UUID AS missing, '12345678-9abc-def0-1122-334455667788'::VARCHAR AS uuid_text \
             UNION ALL \
             SELECT 'second', '00000000-0000-0000-0000-000000000001'::UUID, NULL::UUID, \
             '00000000-0000-0000-0000-000000000001'::VARCHAR",
        )
        .await
        .unwrap();

    assert_eq!(
        result
            .columns
            .iter()
            .map(|column| column.data_type.as_str())
            .collect::<Vec<_>>(),
        vec!["Utf8", "UUID", "UUID", "Utf8"]
    );
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Text("first".into()),
                Value::Uuid("12345678-9abc-def0-1122-334455667788".parse().unwrap()),
                Value::Null,
                Value::Text("12345678-9abc-def0-1122-334455667788".into()),
            ],
            vec![
                Value::Text("second".into()),
                Value::Uuid("00000000-0000-0000-0000-000000000001".parse().unwrap()),
                Value::Null,
                Value::Text("00000000-0000-0000-0000-000000000001".into()),
            ],
        ]
    );
}

#[tokio::test]
async fn value_contract_zero_row_projection_preserves_uuid_metadata() {
    let connection = super::native_connection().await;
    let result = connection
        .query("SELECT NULL::UUID AS missing WHERE false")
        .await
        .unwrap();

    assert!(result.rows.is_empty());
    assert_eq!(result.columns.len(), 1);
    assert_eq!(result.columns[0].name, "missing");
    assert_eq!(result.columns[0].data_type, "UUID");
}
