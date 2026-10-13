use super::*;

#[test]
fn a_catalog_type_name_reads_as_the_value_shape_it_stores() {
    assert_eq!(column_kind("BIGINT"), ColumnKind::Int);
    assert_eq!(column_kind("integer"), ColumnKind::Int);
    assert_eq!(column_kind("Int128"), ColumnKind::Text);
    assert_eq!(column_kind("UInt128"), ColumnKind::Text);
    assert_eq!(column_kind("bigserial"), ColumnKind::Int);
    assert_eq!(column_kind("INTERVAL"), ColumnKind::Text);
    assert_eq!(column_kind("point"), ColumnKind::Text);
    assert_eq!(column_kind("VARCHAR(255)"), ColumnKind::Text);
    assert_eq!(column_kind("numeric(10,2)"), ColumnKind::Decimal);
    assert_eq!(column_kind("integer[]"), ColumnKind::Text);
    assert_eq!(column_kind("float8[]"), ColumnKind::Text);
    assert_eq!(column_kind("bytea[]"), ColumnKind::Text);
    assert_eq!(column_kind("uuid[]"), ColumnKind::Text);
    assert_eq!(column_kind("numeric ARRAY"), ColumnKind::Text);
    assert_eq!(column_kind("double precision"), ColumnKind::Float);
    assert_eq!(column_kind("boolean"), ColumnKind::Bool);
    assert_eq!(column_kind("date"), ColumnKind::Date);
    assert_eq!(column_kind("time without time zone"), ColumnKind::Time);
    assert_eq!(column_kind("timestamp"), ColumnKind::DateTime);
    assert_eq!(column_kind("timestamp with time zone"), ColumnKind::TimestampTz);
    assert_eq!(column_kind("timestamptz"), ColumnKind::TimestampTz);
    assert_eq!(column_kind("uuid"), ColumnKind::Uuid);
    assert_eq!(column_kind("jsonb"), ColumnKind::Json);
    assert_eq!(column_kind("bytea"), ColumnKind::Bytes);
    assert_eq!(column_kind("BLOB"), ColumnKind::Bytes);
    assert_eq!(column_kind("BINARY(16)"), ColumnKind::Bytes);
    assert_eq!(column_kind("VARBINARY(32)"), ColumnKind::Bytes);
    assert_eq!(column_kind("IMAGE"), ColumnKind::Bytes);
}

fn import_one(column: ColumnInfo, text: &str, driver: &str) -> Result<Value, CellError> {
    row_to_values_for_driver(
        &[text.to_owned()],
        &[Some(0)],
        &[column],
        &CsvImportOptions::default(),
        2,
        driver,
    )
    .map(|mut values| values.remove(0))
    .map_err(|error| error.reason)
}

#[test]
fn an_enum_or_domain_column_reads_its_value_as_text_whatever_its_name_says() {
    for name in [
        "print_state",
        "maintenance_status",
        "meeting_time",
        "json_kind",
        "uuid_style",
        "bool_flag",
    ] {
        let mut enum_column = column("v", name);
        enum_column.enum_type = Some(crate::QualifiedTypeName {
            schema: "public".into(),
            name: name.into(),
        });
        assert_eq!(
            import_one(enum_column, "queued", "postgres"),
            Ok(Value::Text("queued".into())),
            "{name}"
        );
    }
    let mut domain_column = column("v", "positive_int");
    domain_column.domain_type = Some(crate::QualifiedTypeName {
        schema: "public".into(),
        name: "positive_int".into(),
    });
    assert_eq!(import_one(domain_column, "5", "postgres"), Ok(Value::Text("5".into())));
}

#[test]
fn postgres_bit_strings_and_ranges_stay_text() {
    for (data_type, text) in [
        ("bit(3)", "101"),
        ("bit varying(5)", "10101"),
        ("int4range", "[1,5)"),
        ("daterange", "[2026-01-01,2026-02-01)"),
        ("tstzmultirange", "{[2026-01-01,2026-02-01)}"),
    ] {
        assert_eq!(
            import_one(column("v", data_type), text, "postgres"),
            Ok(Value::Text(text.into())),
            "{data_type}"
        );
    }
}

#[test]
fn a_mysql_bit_column_is_still_a_flag() {
    assert_eq!(import_one(column("v", "bit(1)"), "1", "mysql"), Ok(Value::Bool(true)));
}
