use super::connection_lookup::resolve;
use crate::answers::{TableDdl, TableDescription, parse};
use crate::client::McpClient;
use crate::command_error::CommandError;
use crate::command_line::DescribeArgs;
use crate::console::Console;
use crate::host::Host;
use crate::output::{Cell, Table};
use crate::tool_arguments::TableArguments;

pub(super) async fn run(
    arguments: &DescribeArgs,
    host: &(impl Host + Clone + Send + Sync + 'static),
    console: &mut Console<'_>,
) -> Result<(), CommandError> {
    let client = McpClient::connect(host).await?;
    let connection = resolve(&client, &arguments.connection, console).await?;
    let request = TableArguments {
        connection_id: connection.id(),
        table: &arguments.table,
        database: arguments.database.as_deref(),
        schema: arguments.schema.as_deref(),
    };
    if arguments.ddl {
        let answer: TableDdl = parse(&connection.call(&client, console, "get_table_ddl", &request).await?)?;
        let mut text = answer.ddl;
        if !text.ends_with('\n') {
            text.push('\n');
        }
        return console.text(&text);
    }
    let answer: TableDescription = parse(&connection.call(&client, console, "describe_table", &request).await?)?;
    console.tables(&tables(answer), arguments.format)
}

// Three result sets, as a batch prints them: columns, indexes, foreign keys.
fn tables(description: TableDescription) -> [Table; 3] {
    let mut columns = Table::new(&[
        "name",
        "data_type",
        "is_nullable",
        "is_primary_key",
        "is_auto_increment",
        "is_generated",
        "default_value",
        "comment",
    ]);
    for column in description.columns {
        columns.push(vec![
            Cell::text(column.name),
            Cell::text(column.data_type),
            Cell::literal(column.is_nullable),
            Cell::literal(column.is_primary_key),
            Cell::literal(column.is_auto_increment),
            Cell::literal(column.is_generated),
            Cell::optional(column.default_value),
            Cell::optional(column.comment),
        ]);
    }
    let mut indexes = Table::new(&["name", "columns", "is_unique", "is_primary", "predicate"]);
    for index in description.indexes {
        indexes.push(vec![
            Cell::text(index.name),
            Cell::text(index.columns.join(", ")),
            Cell::literal(index.is_unique),
            Cell::literal(index.is_primary),
            Cell::optional(index.predicate),
        ]);
    }
    let mut foreign_keys = Table::new(&[
        "name",
        "columns",
        "referenced_schema",
        "referenced_table",
        "referenced_columns",
        "on_delete",
        "on_update",
    ]);
    for key in description.foreign_keys {
        foreign_keys.push(vec![
            Cell::text(key.name),
            Cell::text(key.columns.join(", ")),
            Cell::optional(key.referenced_schema),
            Cell::text(key.referenced_table),
            Cell::text(key.referenced_columns.join(", ")),
            Cell::optional(key.on_delete),
            Cell::optional(key.on_update),
        ]);
    }
    [columns, indexes, foreign_keys]
}
