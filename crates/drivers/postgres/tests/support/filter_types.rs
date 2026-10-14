#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;
use tablepro_core::filter::{FilterOp, FilterRule, FilterSet, FilterValue, build_filter_where};

use crate::{connect, start_pg};

const CASES: [(&str, &str); 9] = [
    ("tm", "10:30:00"),
    ("tz", "10:30:00+02"),
    ("iv", "1 day"),
    ("ip", "10.0.0.1"),
    ("b3", "101"),
    ("r", "[1,5)"),
    ("dr", "[2026-01-01,2026-02-01)"),
    ("e", "queued"),
    ("d", "5"),
];

#[tokio::test]
#[ignore = "requires docker"]
async fn filters_on_native_types_enums_and_domains_match_the_row_they_describe() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TYPE update_kind AS ENUM ('queued', 'done')")
        .await
        .unwrap();
    conn.execute("CREATE DOMAIN positive_int AS integer CHECK (VALUE > 0)")
        .await
        .unwrap();
    conn.execute(
        "CREATE TABLE f (id int PRIMARY KEY, tm time, tz timetz, iv interval, ip inet, b3 bit(3), r int4range, \
         dr daterange, e update_kind, d positive_int)",
    )
    .await
    .unwrap();
    conn.execute(
        "INSERT INTO f VALUES (1, '10:30:00', '10:30:00+02', '1 day', '10.0.0.1', B'101', '[1,5)', \
         '[2026-01-01,2026-02-01)', 'queued', 5), (2, '01:00:00', '01:00:00+00', '2 days', '10.0.0.2', B'010', \
         '[7,9)', '[2027-01-01,2027-02-01)', 'done', 9)",
    )
    .await
    .unwrap();
    let columns = conn.fetch_columns(Some("public"), "f").await.unwrap();

    for (name, value) in CASES {
        let set = FilterSet {
            rules: vec![FilterRule {
                column: name.into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single(value.into())),
            }],
            ..Default::default()
        };
        let (clause, params) = build_filter_where("postgres", &columns, &set).unwrap().unwrap();
        let sql = format!("SELECT id FROM f WHERE {clause}");
        let result = conn.query_params(&sql, &params).await;
        let rows = result.unwrap_or_else(|error| panic!("{name}: {sql}\n{error:?}")).rows;
        assert_eq!(rows, vec![vec![Value::Int(1)]], "{name}: {sql}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn filters_on_a_real_column_find_the_row_whose_value_was_typed() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE fr (id int PRIMARY KEY, v real, d double precision)")
        .await
        .unwrap();
    conn.execute("INSERT INTO fr VALUES (1, 0.1, 0.1), (2, 0.2, 0.2), (3, 16777216, 16777216)")
        .await
        .unwrap();
    let columns = conn.fetch_columns(Some("public"), "fr").await.unwrap();

    for column in ["v", "d"] {
        for (op, value, expected) in [
            (FilterOp::Eq, FilterValue::Single("0.1".into()), vec![1]),
            (FilterOp::NotEq, FilterValue::Single("0.1".into()), vec![2, 3]),
            (FilterOp::Lt, FilterValue::Single("0.15".into()), vec![1]),
            (FilterOp::GtEq, FilterValue::Single("0.2".into()), vec![2, 3]),
            (
                FilterOp::Between,
                FilterValue::Pair("0.05".into(), "0.15".into()),
                vec![1],
            ),
            (
                FilterOp::In,
                FilterValue::List(vec!["0.1".into(), "0.2".into()]),
                vec![1, 2],
            ),
            (FilterOp::Eq, FilterValue::Single("16777216".into()), vec![3]),
        ] {
            let set = FilterSet {
                rules: vec![FilterRule {
                    column: column.into(),
                    op,
                    value: Some(value),
                }],
                ..Default::default()
            };
            let (clause, params) = build_filter_where("postgres", &columns, &set).unwrap().unwrap();
            let sql = format!("SELECT id FROM fr WHERE {clause} ORDER BY id");
            let rows = conn
                .query_params(&sql, &params)
                .await
                .unwrap_or_else(|error| panic!("{column} {op:?}: {sql}\n{error:?}"))
                .rows;
            let ids: Vec<i64> = rows
                .iter()
                .map(|row| match row[0] {
                    Value::Int(id) => id,
                    ref other => panic!("{other:?}"),
                })
                .collect();
            assert_eq!(ids, expected, "{column} {op:?} {sql}");
        }
    }
}
