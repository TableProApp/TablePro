use super::*;

#[test]
fn postgres_table_without_pk_uses_ctid_for_default_order() {
    assert_eq!(
        resolved_order_by("postgres", &[column("name", false)], None, true).as_deref(),
        Some("ctid ASC")
    );
}

#[test]
fn postgres_table_without_pk_uses_ctid_as_sort_tie_breaker() {
    assert_eq!(
        resolved_order_by("postgres", &[column("name", false)], Some((0, false)), true).as_deref(),
        Some("\"name\" DESC, ctid ASC")
    );
}

#[test]
fn non_postgres_table_without_pk_or_sort_keeps_native_ordering() {
    assert_eq!(resolved_order_by("mysql", &[column("name", false)], None, true), None);
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
    let PageQuery::Sql(page) = target.page_by_row_id(50, 50, None, None).unwrap() else {
        panic!("PostgreSQL unkeyed browse pages require ordered SQL")
    };
    assert!(page.sql.ends_with("ORDER BY ctid ASC LIMIT 50 OFFSET 50"));
}

#[test]
fn a_page_without_the_row_id_order_never_mentions_ctid_so_a_view_still_browses() {
    let columns = [column("group_name", false)];
    let filter = FilterSet::default();
    let target = BrowseTarget {
        driver_id: "postgres",
        schema: Some("public"),
        table: "some_view",
        columns: &columns,
        filter: &filter,
        hidden_columns: None,
    };
    assert!(matches!(target.page(50, 50, None, None).unwrap(), PageQuery::Native));
    let PageQuery::Sql(sorted) = target.page(0, 50, Some((0, true)), None).unwrap() else {
        panic!("a sorted page runs as SQL")
    };
    assert!(!sorted.sql.contains("ctid"), "{}", sorted.sql);
}
