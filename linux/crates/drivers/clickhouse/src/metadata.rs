use tablepro_core::DriverError;
use tablepro_core::meta::{ObjectInfo, ObjectKind, ObjectScope, SchemaInfo};

use crate::call_client::CallClient;
use crate::result_reader::{CatalogRow, read_table};

/// The databases the server keeps for itself.
const SYSTEM_DATABASES: [&str; 3] = ["system", "INFORMATION_SCHEMA", "information_schema"];

/// Every database, with the session's own as the default.
pub(crate) async fn list_schemas(calls: &CallClient) -> Result<Vec<SchemaInfo>, DriverError> {
    let sql = "SELECT name, name = currentDatabase() FROM system.databases ORDER BY name";
    let result = read_table(calls.raw(sql)?, None).await?;
    result
        .rows
        .iter()
        .map(|row| {
            let row = CatalogRow(row);
            let name = row.text(0)?;
            Ok(SchemaInfo {
                is_system: SYSTEM_DATABASES.contains(&name.as_str()),
                is_default: row.flag(1)?,
                name,
            })
        })
        .collect()
}

/// Tables, views and dictionaries from `system.tables`, and the SQL
/// functions users defined. A function belongs to the server rather
/// than to a database, so it is listed with no schema, and only where
/// the scope is not one named database.
pub(crate) async fn list_objects(
    calls: &CallClient,
    scope: &ObjectScope,
    default_database: &str,
) -> Result<Vec<ObjectInfo>, DriverError> {
    let base = "SELECT database, name, engine FROM system.tables WHERE is_temporary = 0";
    let query = match scope {
        ObjectScope::DefaultSchema => calls
            .raw(&format!("{base} AND database = {{db:String}} ORDER BY name"))?
            .param("db", default_database),
        ObjectScope::Schema(database) => calls
            .raw(&format!("{base} AND database = {{db:String}} ORDER BY name"))?
            .param("db", database.as_str()),
        ObjectScope::AllSchemas => calls
            .raw(&format!(
                "{base} AND database NOT IN {{system:Array(String)}} ORDER BY database, name"
            ))?
            .param("system", SYSTEM_DATABASES),
    };
    let mut objects = Vec::new();
    for row in &read_table(query, None).await?.rows {
        let row = CatalogRow(row);
        objects.push(ObjectInfo {
            schema: Some(row.text(0)?),
            name: row.text(1)?,
            kind: kind_of_engine(&row.text(2)?),
        });
    }
    if !matches!(scope, ObjectScope::Schema(_)) {
        let sql = "SELECT name FROM system.functions WHERE origin = 'SQLUserDefined' ORDER BY name";
        for row in &read_table(calls.raw(sql)?, None).await?.rows {
            objects.push(ObjectInfo {
                schema: None,
                name: CatalogRow(row).text(0)?,
                kind: ObjectKind::Function,
            });
        }
    }
    Ok(objects)
}

fn kind_of_engine(engine: &str) -> ObjectKind {
    match engine {
        "View" | "LiveView" | "WindowView" => ObjectKind::View,
        "MaterializedView" => ObjectKind::MaterializedView,
        "Dictionary" => ObjectKind::Dictionary,
        _ => ObjectKind::Table,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engines_name_the_object_kind() {
        assert_eq!(kind_of_engine("MergeTree"), ObjectKind::Table);
        assert_eq!(kind_of_engine("ReplacingMergeTree"), ObjectKind::Table);
        assert_eq!(kind_of_engine("View"), ObjectKind::View);
        assert_eq!(kind_of_engine("MaterializedView"), ObjectKind::MaterializedView);
        assert_eq!(kind_of_engine("Dictionary"), ObjectKind::Dictionary);
    }
}
