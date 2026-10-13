use super::*;

#[test]
fn postgres_table_without_pk_uses_ctid_for_default_order() {
    assert_eq!(
        resolved_order_by("postgres", &[column("name", false)], None).as_deref(),
        Some("ctid ASC")
    );
}

#[test]
fn postgres_table_without_pk_uses_ctid_as_sort_tie_breaker() {
    assert_eq!(
        resolved_order_by("postgres", &[column("name", false)], Some((0, false))).as_deref(),
        Some("\"name\" DESC, ctid ASC")
    );
}

#[test]
fn non_postgres_table_without_pk_or_sort_keeps_native_ordering() {
    assert_eq!(resolved_order_by("mysql", &[column("name", false)], None), None);
}

#[test]
fn postgres_unkeyed_browse_pages_have_a_stable_generated_order() {
    let columns = [column("group_name", false)];
    let filter = FilterSet::default();
    let target = BrowseTarget {
        driver_id: "postgres",
        schema: Some("public"),
        table: "items",
        columns: &columns,
        filter: &filter,
        hidden_columns: None,
    };
    let PageQuery::Sql(page) = target.page(50, 50, None, None).unwrap() else {
        panic!("PostgreSQL unkeyed browse pages require ordered SQL")
    };
    assert!(page.sql.ends_with("ORDER BY ctid ASC LIMIT 50 OFFSET 50"));
}
