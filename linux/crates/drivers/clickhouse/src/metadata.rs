use tablepro_core::meta::{ObjectInfo, ObjectKind, ObjectScope, SchemaInfo};
use tablepro_core::{DriverError, UnsupportedFeature};

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
        objects.push(ObjectInfo::new(
            Some(row.text(0)?),
            row.text(1)?,
            kind_of_engine(&row.text(2)?),
        ));
    }
    if !matches!(scope, ObjectScope::Schema(_)) {
        let sql = "SELECT name FROM system.functions WHERE origin = 'SQLUserDefined' ORDER BY name";
        for row in &read_table(calls.raw(sql)?, None).await?.rows {
            objects.push(ObjectInfo::new(None, CatalogRow(row).text(0)?, ObjectKind::Function));
        }
    }
    Ok(objects)
}

/// The `CREATE FUNCTION` the server stored for a user-defined function.
/// A function dropped since the list was read has no row.
pub(crate) async fn fetch_object_definition(calls: &CallClient, object: &ObjectInfo) -> Result<String, DriverError> {
    if object.kind != ObjectKind::Function {
        return Err(DriverError::Unsupported {
            feature: UnsupportedFeature::ObjectDefinitions,
        });
    }
    let query = calls
        .raw("SELECT create_query FROM system.functions WHERE origin = 'SQLUserDefined' AND name = {name:String}")?
        .param("name", object.name.as_str());
    match read_table(query, None).await?.rows.first() {
        Some(row) => CatalogRow(row).text(0).map(|text| terminated(&text)),
        None => Ok(String::new()),
    }
}

fn terminated(sql: &str) -> String {
    format!("{};", sql.trim_end().trim_end_matches(';'))
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

    #[test]
    fn a_stored_statement_ends_in_one_semicolon() {
        assert_eq!(
            terminated("CREATE FUNCTION f AS x -> (x + 1)\n"),
            "CREATE FUNCTION f AS x -> (x + 1);"
        );
        assert_eq!(
            terminated("CREATE FUNCTION f AS x -> x;"),
            "CREATE FUNCTION f AS x -> x;"
        );
    }
}
