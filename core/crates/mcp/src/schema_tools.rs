use serde::Serialize;
use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::BuildDdlError;
use tablepro_core::meta::{IndexKey, ObjectKind, ObjectScope, RowCountEstimate};
use tablepro_core::{ColumnInfo, ForeignKeyInfo, IndexInfo, TableRef};
use tablepro_session::{OperationError, OperationKind};

use crate::connection_tools::to_json;
use crate::tool_args::{ConnectionArgs, SchemaArgs, TableArgs};
use crate::tool_context::ToolContext;
use crate::tool_error::ToolError;

#[derive(Serialize)]
struct SchemaList {
    schemas: Vec<ListedSchema>,
}

#[derive(Serialize)]
struct ListedSchema {
    name: String,
    is_default: bool,
    is_system: bool,
}

pub async fn list_schemas(context: &ToolContext, args: ConnectionArgs) -> Result<String, ToolError> {
    let connection = context.connection(&args.connection_id)?;
    let session = context.session(&connection).await?;
    let schemas = session
        .schemas()
        .await
        .map_err(|error| ToolError::from_operation(&error))?;
    to_json(&SchemaList {
        schemas: schemas
            .iter()
            .map(|schema| ListedSchema {
                name: schema.name.clone(),
                is_default: schema.is_default,
                is_system: schema.is_system,
            })
            .collect(),
    })
}

#[derive(Serialize)]
struct TableList {
    tables: Vec<ListedTable>,
}

#[derive(Serialize)]
struct ListedTable {
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    schema: Option<String>,
    kind: &'static str,
}

/// Read again rather than from the window's catalog, so a table a
/// client just created is there; the read also refreshes the sidebar.
pub async fn list_tables(context: &ToolContext, args: SchemaArgs) -> Result<String, ToolError> {
    let connection = context.connection(&args.connection_id)?;
    let session = context.session(&connection).await?;
    let scope = match args.schema {
        Some(schema) => ObjectScope::Schema(schema),
        None => ObjectScope::DefaultSchema,
    };
    let objects = session
        .refresh_objects(scope)
        .await
        .map_err(|error| ToolError::from_operation(&error))?;
    to_json(&TableList {
        tables: objects
            .iter()
            .filter(|object| object.kind.is_browsable())
            .map(|object| ListedTable {
                name: object.name.clone(),
                schema: object.schema.clone(),
                kind: kind_name(object.kind),
            })
            .collect(),
    })
}

fn kind_name(kind: ObjectKind) -> &'static str {
    match kind {
        ObjectKind::Table => "table",
        ObjectKind::PartitionedTable => "partitioned_table",
        ObjectKind::View => "view",
        ObjectKind::MaterializedView => "materialized_view",
        ObjectKind::ForeignTable => "foreign_table",
        _ => "other",
    }
}

#[derive(Serialize)]
struct TableDescription {
    table: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    schema: Option<String>,
    columns: Vec<DescribedColumn>,
    indexes: Vec<DescribedIndex>,
    foreign_keys: Vec<DescribedForeignKey>,
    #[serde(skip_serializing_if = "Option::is_none")]
    row_count: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    row_count_is_exact: Option<bool>,
}

#[derive(Serialize)]
struct DescribedColumn {
    name: String,
    data_type: String,
    is_nullable: bool,
    is_primary_key: bool,
    is_auto_increment: bool,
    is_generated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    default_value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    comment: Option<String>,
}

#[derive(Serialize)]
struct DescribedIndex {
    name: String,
    columns: Vec<String>,
    is_unique: bool,
    is_primary: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    predicate: Option<String>,
}

#[derive(Serialize)]
struct DescribedForeignKey {
    name: String,
    columns: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    referenced_schema: Option<String>,
    referenced_table: String,
    referenced_columns: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    on_delete: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    on_update: Option<&'static str>,
}

type TableParts = (Vec<ColumnInfo>, Vec<IndexInfo>, Vec<ForeignKeyInfo>, RowCountEstimate);

pub async fn describe_table(context: &ToolContext, args: TableArgs) -> Result<String, ToolError> {
    let connection = context.connection(&args.connection_id)?;
    let session = context.session(&connection).await?;
    let table = TableRef::new(args.schema, args.table);
    let read: Result<TableParts, OperationError> = session
        .run(OperationKind::Metadata, |lease, call| {
            let table = table.clone();
            async move {
                let columns = lease.fetch_columns(&table, call.clone()).await?;
                if columns.is_empty() {
                    return Ok((columns, Vec::new(), Vec::new(), RowCountEstimate::Unknown));
                }
                let indexes = lease.fetch_indexes(&table, call.clone()).await?;
                let foreign_keys = lease.fetch_foreign_keys(&table, call.clone()).await?;
                // A count is a nicety; a table whose estimate cannot be
                // read is still described.
                let rows = lease
                    .table_estimate(&table, call)
                    .await
                    .map_or(RowCountEstimate::Unknown, |estimate| estimate.rows);
                Ok((columns, indexes, foreign_keys, rows))
            }
        })
        .await;
    let (columns, indexes, foreign_keys, rows) = read.map_err(|error| ToolError::from_operation(&error))?;
    if columns.is_empty() {
        return Err(no_such_table(&table));
    }
    to_json(&TableDescription {
        columns: columns.iter().map(described_column).collect(),
        indexes: indexes.iter().map(described_index).collect(),
        foreign_keys: foreign_keys.iter().map(described_foreign_key).collect(),
        row_count: rows.value(),
        row_count_is_exact: rows.value().map(|_| rows.is_exact()),
        table: table.name,
        schema: table.schema,
    })
}

fn described_column(column: &ColumnInfo) -> DescribedColumn {
    DescribedColumn {
        name: column.name.clone(),
        data_type: column.column_type.name.clone(),
        is_nullable: column.nullable,
        is_primary_key: column.primary_key,
        is_auto_increment: column.is_auto_increment,
        is_generated: column.is_generated,
        default_value: match &column.default {
            ColumnDefault::None => None,
            ColumnDefault::Literal(value) => {
                Some(tablepro_core::export::value_to_text(value).unwrap_or_else(|| "NULL".to_owned()))
            }
            ColumnDefault::Expression(expression) => Some(expression.as_sql().to_owned()),
        },
        comment: column.comment.clone().filter(|comment| !comment.is_empty()),
    }
}

fn described_index(index: &IndexInfo) -> DescribedIndex {
    DescribedIndex {
        name: index.name.clone(),
        columns: index
            .keys
            .iter()
            .map(|key| {
                let (text, descending) = match key {
                    IndexKey::Column { name, descending } => (name.clone(), *descending),
                    IndexKey::Expression { sql, descending } => (sql.clone(), *descending),
                };
                match descending {
                    true => format!("{text} DESC"),
                    false => text,
                }
            })
            .collect(),
        is_unique: index.unique,
        is_primary: index.primary,
        predicate: index.predicate.clone(),
    }
}

fn described_foreign_key(key: &ForeignKeyInfo) -> DescribedForeignKey {
    DescribedForeignKey {
        name: key.name.clone(),
        columns: key.columns.clone(),
        referenced_schema: key.ref_schema.clone(),
        referenced_table: key.ref_table.clone(),
        referenced_columns: key.ref_columns.clone(),
        on_delete: key.on_delete.map(|action| action.as_sql()),
        on_update: key.on_update.map(|action| action.as_sql()),
    }
}

#[derive(Serialize)]
struct TableDdl {
    table: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    schema: Option<String>,
    ddl: String,
}

/// The statements Show CREATE TABLE gives: the server's own text where
/// it keeps one, otherwise the table's definition written in its
/// dialect.
pub async fn get_table_ddl(context: &ToolContext, args: TableArgs) -> Result<String, ToolError> {
    let connection = context.connection(&args.connection_id)?;
    let session = context.session(&connection).await?;
    let table = TableRef::new(args.schema, args.table);
    let read = session
        .run(OperationKind::Metadata, |lease, call| {
            let table = table.clone();
            async move {
                let definition = lease.fetch_table_definition(&table, call).await?;
                Ok((definition, lease.dialect()))
            }
        })
        .await;
    let (definition, dialect) = read.map_err(|error| ToolError::from_operation(&error))?;
    if definition.columns.is_empty() {
        return Err(no_such_table(&table));
    }
    let ddl = dialect
        .ddl()
        .ok_or_else(|| ToolError::Unsupported("this engine cannot write its tables' DDL".to_owned()))?
        .create_table_script(&definition)
        .map_err(|error: BuildDdlError| ToolError::Unsupported(error.to_string()))?
        .preview();
    to_json(&TableDdl {
        table: table.name,
        schema: table.schema,
        ddl,
    })
}

pub fn no_such_table(table: &TableRef) -> ToolError {
    ToolError::NotFound(match &table.schema {
        Some(schema) => format!("no table or view named {} in schema {schema}", table.name),
        None => format!("no table or view named {} in the default schema", table.name),
    })
}
