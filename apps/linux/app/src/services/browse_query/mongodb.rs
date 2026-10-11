use super::{BoundQuery, BrowseTarget};
use tablepro_core::Value;

pub(super) fn value_query(
    target: &BrowseTarget<'_>,
    column_index: usize,
    pk_values: &[Value],
) -> Result<BoundQuery, String> {
    let keys: Vec<_> = target.columns.iter().filter(|column| column.primary_key).collect();
    let Some(column) = target.columns.get(column_index) else {
        return Err("value column no longer exists".into());
    };
    if keys.len() != 1 || keys[0].name != "_id" || pk_values.len() != 1 {
        return Err("MongoDB value fetch requires its single _id key".into());
    }
    let quote = |name| tablepro_core::sql_dialect::quote_ident("mongodb", name);
    let collection = target
        .schema
        .map(|schema| format!("{}.{}", quote(schema), quote(target.table)))
        .unwrap_or_else(|| quote(target.table));
    Ok(BoundQuery {
        sql: format!(
            "SELECT {} FROM {collection} WHERE {} = ?",
            quote(&column.name),
            quote("_id")
        ),
        params: pk_values.to_vec(),
        projected_columns: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{ColumnInfo, FilterSet};

    #[test]
    fn mongo_value_query_binds_the_single_id_key() {
        let columns = [column("_id", true), column("payload", false)];
        let target = BrowseTarget {
            driver_id: "mongodb",
            schema: Some("appdb"),
            table: "records",
            columns: &columns,
            filter: &FilterSet::default(),
            hidden_columns: None,
        };
        let key = Value::Text("id' OR 1=1 --".into());
        let query = target.value_query(1, std::slice::from_ref(&key)).unwrap();
        assert_eq!(
            query.sql,
            "SELECT \"payload\" FROM \"appdb\".\"records\" WHERE \"_id\" = ?"
        );
        assert_eq!(query.params, vec![key]);
    }

    fn column(name: &str, primary_key: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "text".into(),
            nullable: false,
            primary_key,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }
}
