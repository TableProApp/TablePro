use tablepro_core::ColumnInfo;

pub(super) fn resolved_order_by(
    driver_id: &str,
    columns: &[ColumnInfo],
    sort: Option<(usize, bool)>,
    row_id_order: bool,
) -> Option<String> {
    let mut terms = Vec::new();
    let selected = sort.and_then(|(index, ascending)| {
        columns.get(index).map(|column| {
            let direction = if ascending { "ASC" } else { "DESC" };
            terms.push(format!(
                "{} {direction}",
                tablepro_core::sql_dialect::quote_ident(driver_id, &column.name)
            ));
            column.name.as_str()
        })
    });
    for column in columns.iter().filter(|column| column.primary_key) {
        if selected == Some(column.name.as_str()) {
            continue;
        }
        terms.push(format!(
            "{} ASC",
            tablepro_core::sql_dialect::quote_ident(driver_id, &column.name)
        ));
    }
    if row_id_order && driver_id == "postgres" && !columns.iter().any(|column| column.primary_key) {
        terms.push("ctid ASC".to_owned());
    }
    (!terms.is_empty()).then(|| terms.join(", "))
}
