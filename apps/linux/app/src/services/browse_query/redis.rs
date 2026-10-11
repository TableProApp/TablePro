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
    if target.schema.is_some()
        || target
            .table
            .strip_prefix("db")
            .is_none_or(|db| db.parse::<u8>().is_err())
        || keys.len() != 1
        || keys[0].name != "Key"
        || column.name != "Value"
        || pk_values.len() != 1
        || !matches!(pk_values[0], Value::Text(_) | Value::Bytes(_))
    {
        return Err("Redis value fetch requires a Value cell and one key from a database table".into());
    }
    Ok(BoundQuery {
        sql: format!("SELECT \"Value\" FROM \"{}\" WHERE \"Key\" = ?", target.table),
        params: pk_values.to_vec(),
        projected_columns: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{ColumnInfo, FilterSet};

    #[test]
    fn redis_value_query_binds_text_and_binary_keys() {
        let columns = [column("Key", true), column("Type", false), column("Value", false)];
        let target = BrowseTarget {
            driver_id: "redis",
            schema: None,
            table: "db3",
            columns: &columns,
            filter: &FilterSet::default(),
            hidden_columns: None,
        };
        let binary_key = Value::Bytes(vec![0xff, b'?', b'\n']);
        let query = target.value_query(2, std::slice::from_ref(&binary_key)).unwrap();
        assert_eq!(query.sql, "SELECT \"Value\" FROM \"db3\" WHERE \"Key\" = ?");
        assert_eq!(query.params, vec![binary_key]);
        assert!(target.value_query(1, &[Value::Text("key".into())]).is_err());
    }

    fn column(name: &str, primary_key: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "string".into(),
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
