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
