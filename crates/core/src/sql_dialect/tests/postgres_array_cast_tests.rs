use super::*;

#[test]
fn postgres_array_update_casts_allowlist_type_metadata() {
    let supported = [
        ("bool[]", "pg_catalog.bool[]"),
        ("boolean[]", "pg_catalog.bool[]"),
        ("bytea[]", "pg_catalog.bytea[]"),
        ("name[]", "pg_catalog.name[]"),
        ("int2[]", "pg_catalog.int2[]"),
        ("smallint[]", "pg_catalog.int2[]"),
        ("int4[]", "pg_catalog.int4[]"),
        ("integer[]", "pg_catalog.int4[]"),
        ("int[]", "pg_catalog.int4[]"),
        ("int8[]", "pg_catalog.int8[]"),
        ("bigint[]", "pg_catalog.int8[]"),
        ("oid[]", "pg_catalog.oid[]"),
        ("text[]", "pg_catalog.text[]"),
        ("bit[]", "pg_catalog.bit[]"),
        ("bit(5)[]", "pg_catalog.bit[]"),
        ("bit varying[]", "pg_catalog.varbit[]"),
        ("bit varying(9)[]", "pg_catalog.varbit[]"),
        ("varbit[]", "pg_catalog.varbit[]"),
        ("float4[]", "pg_catalog.float4[]"),
        ("real[]", "pg_catalog.float4[]"),
        ("float8[]", "pg_catalog.float8[]"),
        ("double precision[]", "pg_catalog.float8[]"),
        ("varchar[]", "pg_catalog.varchar[]"),
        ("character varying(40)[]", "pg_catalog.varchar[]"),
        ("char[]", "pg_catalog.bpchar[]"),
        ("bpchar[]", "pg_catalog.bpchar[]"),
        ("character[]", "pg_catalog.bpchar[]"),
        ("numeric(80, 40)[]", "pg_catalog.numeric[]"),
        ("decimal[]", "pg_catalog.numeric[]"),
        ("uuid[]", "pg_catalog.uuid[]"),
        ("xml[]", "pg_catalog.xml[]"),
        ("pg_lsn[]", "pg_catalog.pg_lsn[]"),
        ("date[]", "pg_catalog.date[]"),
        ("time[]", "pg_catalog.time[]"),
        ("time without time zone[]", "pg_catalog.time[]"),
        ("timetz[]", "pg_catalog.timetz[]"),
        ("time with time zone[]", "pg_catalog.timetz[]"),
        ("timestamp[]", "pg_catalog.timestamp[]"),
        ("timestamp without time zone[]", "pg_catalog.timestamp[]"),
        ("timestamptz[]", "pg_catalog.timestamptz[]"),
        ("timestamp with time zone[]", "pg_catalog.timestamptz[]"),
        ("interval[]", "pg_catalog.interval[]"),
    ];

    for (data_type, cast_type) in supported {
        assert_eq!(postgres_array_cast_type(data_type), Some(cast_type), "{data_type}");
        let mut columns = [col("id", true), col("value", false)];
        columns[1].data_type = data_type.into();
        let (sql, params) = build_keyed_update(
            "postgres",
            None,
            "t",
            &columns,
            &[(1, Value::Text("{}".into()))],
            &[Value::Int(1)],
        )
        .unwrap();
        assert_eq!(
            sql,
            format!(r#"UPDATE "t" SET "value" = $1::text::{cast_type} WHERE "id" = $2"#),
            "{data_type} must generate only its static built-in cast"
        );
        assert_eq!(params, vec![Value::Text("{}".into()), Value::Int(1)]);
    }

    assert_eq!(postgres_array_cast_type("integer[]; DROP TABLE t"), None);
    assert_eq!(postgres_array_cast_type("custom_type[]"), None);
    assert_eq!(postgres_array_cast_type("numeric(x)[]"), None);
}
