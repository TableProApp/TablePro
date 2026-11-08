use super::connection_lookup::{list, resolve};
use crate::answers::{DatabaseList, SchemaList, TableList, parse};
use crate::client::McpClient;
use crate::command_error::CommandError;
use crate::command_line::{DatabasesArgs, FormatArgs, SchemasArgs, TablesArgs};
use crate::console::Console;
use crate::host::Host;
use crate::output::{Cell, Table};
use crate::tool_arguments::{ConnectionArguments, ScopeArguments};

// The name, id and type only, as on macOS: never a host, user or password.
pub(super) async fn connections(
    arguments: &FormatArgs,
    host: &dyn Host,
    console: &mut Console<'_>,
) -> Result<(), CommandError> {
    let client = McpClient::connect(host).await?;
    let mut table = Table::new(&["name", "id", "type"]);
    for connection in list(&client).await? {
        table.push(vec![
            Cell::text(connection.name),
            Cell::text(connection.id),
            Cell::text(connection.kind),
        ]);
    }
    console.tables(&[table], arguments.format)
}

pub(super) async fn databases(
    arguments: &DatabasesArgs,
    host: &dyn Host,
    console: &mut Console<'_>,
) -> Result<(), CommandError> {
    let client = McpClient::connect(host).await?;
    let connection = resolve(&client, &arguments.connection, console).await?;
    let request = ConnectionArguments {
        connection_id: connection.id(),
    };
    let answer: DatabaseList = parse(&connection.call(&client, console, "list_databases", &request).await?)?;
    let mut table = Table::new(&["name", "is_current"]);
    for database in answer.databases {
        table.push(vec![Cell::text(database.name), Cell::literal(database.is_current)]);
    }
    console.tables(&[table], arguments.format)
}

pub(super) async fn schemas(
    arguments: &SchemasArgs,
    host: &dyn Host,
    console: &mut Console<'_>,
) -> Result<(), CommandError> {
    let client = McpClient::connect(host).await?;
    let connection = resolve(&client, &arguments.connection, console).await?;
    let request = ScopeArguments {
        connection_id: connection.id(),
        database: arguments.database.as_deref(),
        schema: None,
    };
    let answer: SchemaList = parse(&connection.call(&client, console, "list_schemas", &request).await?)?;
    let mut table = Table::new(&["name", "is_default", "is_system"]);
    for schema in answer.schemas {
        table.push(vec![
            Cell::text(schema.name),
            Cell::literal(schema.is_default),
            Cell::literal(schema.is_system),
        ]);
    }
    console.tables(&[table], arguments.format)
}

pub(super) async fn tables(
    arguments: &TablesArgs,
    host: &dyn Host,
    console: &mut Console<'_>,
) -> Result<(), CommandError> {
    let client = McpClient::connect(host).await?;
    let connection = resolve(&client, &arguments.connection, console).await?;
    let request = ScopeArguments {
        connection_id: connection.id(),
        database: arguments.database.as_deref(),
        schema: arguments.schema.as_deref(),
    };
    let answer: TableList = parse(&connection.call(&client, console, "list_tables", &request).await?)?;
    let mut table = Table::new(&["name", "schema", "kind"]);
    for listed in answer.tables {
        table.push(vec![
            Cell::text(listed.name),
            Cell::optional(listed.schema),
            Cell::text(listed.kind),
        ]);
    }
    console.tables(&[table], arguments.format)
}
