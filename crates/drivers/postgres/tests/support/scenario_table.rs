#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;
use tablepro_core::sql_dialect::{build_insert_from_draft, build_keyed_delete, build_optimistic_keyed_update};

use crate::{connect, start_pg};

const KNOWN_UNDECODABLE: [&str; 3] = ["money", "int4range", "point"];

const SCENARIOS: &[(&str, &str, &str)] = &[
    ("integer", "1", "2"),
    ("bigint", "9007199254740993", "-5"),
    ("smallint", "7", "8"),
    ("numeric(12,4)", "12345.6789", "0.0001"),
    ("real", "0.1", "2.5"),
    ("double precision", "0.1", "1e100"),
    ("text", "alpha", "it's"),
    ("varchar(5)", "abc", "xyz"),
    ("char(3)", "ab", "cd"),
    ("boolean", "true", "false"),
    ("date", "2026-01-02", "1999-12-31"),
    ("time", "10:11:12", "23:59:59.5"),
    ("timetz", "10:11:12+02", "01:00:00-05"),
    ("timestamp", "2026-01-02 03:04:05.678", "1999-12-31 23:59:59"),
    ("timestamptz", "2026-01-02 03:04:05+00", "1999-12-31 23:59:59+05"),
    ("interval", "1 day", "2 days 03:00:00"),
    (
        "uuid",
        "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        "00000000-0000-0000-0000-000000000000",
    ),
    ("json", "{\"a\": 1}", "[1, 2]"),
    ("jsonb", "{\"a\": 1}", "{\"b\": [true]}"),
    ("inet", "10.0.0.1", "::1"),
    ("cidr", "10.0.0.0/8", "2001:db8::/32"),
    ("macaddr", "08:00:2b:01:02:03", "08:00:2b:01:02:04"),
    ("bit(3)", "101", "010"),
    ("varbit(5)", "10101", "1"),
    ("xml", "<a/>", "<b>x</b>"),
    ("tsvector", "'a' 'b'", "'c':1"),
    ("bytea", "\\xdeadbeef", "\\x00"),
    ("money", "$12.34", "$0.01"),
    ("int4range", "[1,5)", "empty"),
    ("integer[]", "{1,2,3}", "{}"),
    ("text[]", "{a,\"b c\"}", "{NULL}"),
    ("point", "(1,2)", "(3,4)"),
    (
        "text[]",
        "{\"a,b\",\"c\\\"d\",\"NULL\",\"\",\"x\\\\y\"}",
        "{\"{braces}\",\" lead\"}",
    ),
    (
        "numeric",
        "999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999",
        "NaN",
    ),
    ("numeric", "1e-200", "-0.5"),
    (
        "numeric[]",
        "{99999999999999999999999999999999999999999999999999,NaN,NULL}",
        "{}",
    ),
    ("numeric(18,0)", "123456789012345678", "0"),
    ("integer[]", "{{1,2,3},{4,5,6}}", "{}"),
    ("integer[]", "[0:1]={1,2}", "{7}"),
    ("uuid[]", "{6ba7b810-9dad-11d1-80b4-00c04fd430c8,NULL}", "{}"),
    ("timestamptz", "-infinity", "infinity"),
    ("date", "0044-03-15 BC", "infinity"),
    ("timestamp", "0001-01-01 00:00:00 BC", "4713-01-01 00:00:00 BC"),
    ("interval", "1 year 2 mons 3 days 04:05:06.789", "-1 days -02:00:00"),
    (
        "timestamptz(6)",
        "2026-01-02 03:04:05.123456+00",
        "1999-12-31 23:59:59.5+05",
    ),
];

async fn decode(conn: &dyn tablepro_core::Connection, ty: &str, literal: &str) -> Value {
    let sql = format!("SELECT '{}'::{ty}", literal.replace('\'', "''"));
    conn.query(&sql).await.unwrap().rows.remove(0).remove(0)
}

async fn run_scenario(
    conn: &dyn tablepro_core::Connection,
    index: usize,
    ty: &str,
    a: &str,
    b: &str,
) -> Result<(), String> {
    let table = format!("sc{index}");
    let table = table.as_str();
    conn.execute(&format!("DROP TABLE IF EXISTS {table}"))
        .await
        .map_err(|e| format!("drop: {e:?}"))?;
    conn.execute(&format!("CREATE TABLE {table} (id int PRIMARY KEY, v {ty})"))
        .await
        .map_err(|e| format!("create: {e:?}"))?;
    let columns = conn
        .fetch_columns(None, table)
        .await
        .map_err(|e| format!("columns: {e:?}"))?;
    let va = decode(conn, ty, a).await;
    let vb = decode(conn, ty, b).await;
    let (sql, params) = build_insert_from_draft("postgres", None, table, &columns, &[Value::Int(1), va.clone()])
        .map_err(|e| format!("build insert: {e:?}"))?;
    conn.execute_params(&sql, &params)
        .await
        .map_err(|e| format!("insert [{sql}]: {e:?}"))?;
    let read = conn
        .query(&format!("SELECT v FROM {table} WHERE id = 1"))
        .await
        .map_err(|e| format!("read: {e:?}"))?
        .rows
        .remove(0)
        .remove(0);
    if read != va {
        return Err(format!("round trip: wrote {va:?}, read {read:?}"));
    }
    let steps = [
        (va.clone(), vb.clone(), "A to B"),
        (vb.clone(), Value::Null, "B to NULL"),
        (Value::Null, va.clone(), "NULL to A"),
    ];
    for (old, new, label) in steps {
        let (sql, params) =
            build_optimistic_keyed_update("postgres", None, table, &columns, &[(1, old, new)], &[Value::Int(1)])
                .map_err(|e| format!("{label} build: {e:?}"))?;
        let outcome = conn
            .execute_params(&sql, &params)
            .await
            .map_err(|e| format!("{label} [{sql}]: {e:?}"))?;
        if outcome.rows_affected != 1 {
            return Err(format!("{label}: {} rows affected [{sql}]", outcome.rows_affected));
        }
    }
    let (sql, params) = build_insert_from_draft("postgres", None, table, &columns, &[Value::Int(2), Value::Null])
        .map_err(|e| format!("null insert build: {e:?}"))?;
    conn.execute_params(&sql, &params)
        .await
        .map_err(|e| format!("explicit NULL insert [{sql}]: {e:?}"))?;
    let (sql, params) = build_keyed_delete("postgres", None, table, &columns, &[Value::Int(1)])
        .map_err(|e| format!("delete build: {e:?}"))?;
    let deleted = conn
        .execute_params(&sql, &params)
        .await
        .map_err(|e| format!("delete: {e:?}"))?;
    if deleted.rows_affected != 1 {
        return Err(format!("delete affected {}", deleted.rows_affected));
    }
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn every_scenario_type_survives_insert_edit_null_and_delete_through_the_builders() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    let mut failures = Vec::new();
    for (index, (ty, a, b)) in SCENARIOS.iter().enumerate() {
        if let Err(message) = run_scenario(conn.as_ref(), index, ty, a, b).await {
            failures.push((ty.to_string(), message));
        }
    }
    let failed: Vec<&str> = failures.iter().map(|(ty, _)| ty.as_str()).collect();
    assert_eq!(
        failed, KNOWN_UNDECODABLE,
        "only the scalar types that still read back as Undecodable (#694) may fail:\n{failures:#?}"
    );
}
