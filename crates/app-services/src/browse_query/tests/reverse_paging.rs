use super::*;

#[test]
fn invalid_filter_refuses_both_page_and_count() {
    let filter = FilterSet {
        rules: vec![FilterRule {
            column: "missing".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("x".into())),
        }],
        ..Default::default()
    };
    let target = BrowseTarget {
        driver_id: "postgres",
        schema: None,
        table: "items",
        columns: &[],
        filter: &filter,
        hidden_columns: None,
    };
    assert!(target.count().unwrap_err().contains("missing"));
    assert!(target.page(0, 100, None, None).unwrap_err().contains("missing"));
}

#[test]
fn page_and_count_share_filter_and_keyset_parameters_follow_it() {
    let columns = vec![column("id", true), column("name", false)];
    let filter = FilterSet {
        rules: vec![FilterRule {
            column: "name".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("Ada".into())),
        }],
        ..Default::default()
    };
    let target = BrowseTarget {
        driver_id: "postgres",
        schema: Some("odd\"schema"),
        table: "items",
        columns: &columns,
        filter: &filter,
        hidden_columns: None,
    };
    let count = target.count().unwrap();
    let PageQuery::Sql(page) = target.page(10_000, 100, None, Some(&[Value::Int(50)])).unwrap() else {
        panic!("expected SQL")
    };
    assert_eq!(
        count.sql,
        "SELECT COUNT(*) FROM \"odd\"\"schema\".\"items\" WHERE \"name\" = $1"
    );
    assert!(page.sql.contains("\"name\" = $1 AND \"id\" > $2"));
    assert!(!page.sql.contains("10000"));
    assert_eq!(page.params, vec![Value::Text("Ada".into()), Value::Int(50)]);
    assert_eq!(count.params, vec![Value::Text("Ada".into())]);
}

#[test]
fn previous_deep_page_uses_reverse_keyset_and_marks_rows_for_display_reversal() {
    let columns = vec![column("tenant_id", true), column("id", true), column("name", false)];
    let filter = FilterSet {
        rules: vec![FilterRule {
            column: "name".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("Ada".into())),
        }],
        ..Default::default()
    };
    let target = BrowseTarget {
        driver_id: "postgres",
        schema: Some("app"),
        table: "people",
        columns: &columns,
        filter: &filter,
        hidden_columns: None,
    };
    let PageQuery::Sql(page) = target
        .page_before(10_000, 100, None, Some(&[Value::Int(2), Value::Int(5)]))
        .unwrap()
    else {
        panic!("expected SQL")
    };

    assert!(
        page.sql
            .contains("\"name\" = $1 AND (\"tenant_id\", \"id\") < ($2, $3)")
    );
    assert!(
        page.sql
            .contains("ORDER BY \"tenant_id\" DESC, \"id\" DESC LIMIT 100 OFFSET 0")
    );
    assert_eq!(
        page.params,
        vec![Value::Text("Ada".into()), Value::Int(2), Value::Int(5)]
    );
    assert!(page.reverse_rows);
}

#[test]
fn last_deep_page_uses_a_descending_key_window_without_offset() {
    let columns = vec![column("id", true), column("name", false)];
    let target = BrowseTarget {
        driver_id: "postgres",
        schema: None,
        table: "people",
        columns: &columns,
        filter: &FilterSet::default(),
        hidden_columns: None,
    };
    let PageQuery::Sql(page) = target.page_last(1_000_000, 100, None).unwrap() else {
        panic!("expected SQL")
    };

    assert!(page.sql.contains("ORDER BY \"id\" DESC LIMIT 100 OFFSET 0"));
    assert!(!page.sql.contains("1000000"));
    assert!(page.reverse_rows);
}

#[test]
fn unsupported_native_pagers_keep_their_native_offset_path() {
    let columns = vec![column("_id", true)];
    let target = BrowseTarget {
        driver_id: "mongodb",
        schema: Some("app"),
        table: "items",
        columns: &columns,
        filter: &FilterSet::default(),
        hidden_columns: None,
    };

    assert!(matches!(
        target
            .page_before(20_000, 100, None, Some(&[Value::Int(20_100)]))
            .unwrap(),
        PageQuery::Native
    ));
    assert!(matches!(
        target.page_last(50_000, 100, None).unwrap(),
        PageQuery::Native
    ));
}

#[test]
fn explicit_sort_ignores_a_keyset_cursor_and_keeps_offset_pagination() {
    let columns = vec![column("id", true), column("rank", false)];
    let target = BrowseTarget {
        driver_id: "postgres",
        schema: None,
        table: "items",
        columns: &columns,
        filter: &FilterSet::default(),
        hidden_columns: None,
    };
    let PageQuery::Sql(page) = target
        .page(KEYSET_OFFSET_THRESHOLD, 25, Some((1, true)), Some(&[Value::Int(5)]))
        .unwrap()
    else {
        panic!("expected offset SQL")
    };
    assert!(page.sql.contains("ORDER BY \"rank\" ASC, \"id\" ASC"));
    assert!(
        page.sql
            .ends_with(&format!("LIMIT 25 OFFSET {KEYSET_OFFSET_THRESHOLD}"))
    );
    assert!(!page.sql.contains(" > "));
    assert!(page.params.is_empty());
}

#[test]
fn incomplete_composite_cursor_is_ignored_and_keeps_offset_pagination() {
    let columns = vec![column("tenant", true), column("id", true), column("name", false)];
    let target = BrowseTarget {
        driver_id: "postgres",
        schema: None,
        table: "items",
        columns: &columns,
        filter: &FilterSet::default(),
        hidden_columns: None,
    };
    let PageQuery::Sql(page) = target
        .page(KEYSET_OFFSET_THRESHOLD, 25, None, Some(&[Value::Int(5)]))
        .unwrap()
    else {
        panic!("expected offset SQL")
    };
    assert!(
        page.sql
            .ends_with(&format!("LIMIT 25 OFFSET {KEYSET_OFFSET_THRESHOLD}"))
    );
    assert!(!page.sql.contains(" > "));
    assert!(page.params.is_empty());
}

#[test]
fn keyset_cursor_is_ignored_when_the_table_has_no_primary_key() {
    let columns = vec![column("name", false)];
    let target = BrowseTarget {
        driver_id: "postgres",
        schema: None,
        table: "items",
        columns: &columns,
        filter: &FilterSet::default(),
        hidden_columns: None,
    };
    let PageQuery::Sql(page) = target
        .page_by_row_id(KEYSET_OFFSET_THRESHOLD, 25, None, Some(&[Value::Int(5)]))
        .unwrap()
    else {
        panic!("PostgreSQL unkeyed browse pages require ordered SQL")
    };
    assert!(
        page.sql
            .ends_with(&format!("ORDER BY ctid ASC LIMIT 25 OFFSET {KEYSET_OFFSET_THRESHOLD}"))
    );
    assert!(page.params.is_empty());
}
