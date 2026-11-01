//! The catalogue queries behind the sidebar, browse and the structure
//! tab. Each names its table by `OBJECT_ID` of the bracket-quoted name,
//! which resolves an unqualified name in the login's default schema the
//! way the server does everywhere else.

use tablepro_core::ddl::{InboundForeignKey, ReferentialAction, TableDefinition};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{
    IndexInfo, IndexKey, ObjectDefinition, ObjectInfo, ObjectKind, ObjectScope, RowCountEstimate, RowIdentity,
    SchemaInfo, TableEstimate, TableRef,
};
use tablepro_core::sql_syntax::{SqlGrammar, holds_client_directive, qualify_created_name};
use tablepro_core::{ColumnInfo, DriverError, ForeignKeyInfo, UnsupportedFeature, Value};
use tiberius::ColumnData;

use crate::catalog::{
    COLUMNS_SQL, Cells, INBOUND_FOREIGN_KEYS_SQL, MssqlColumnRow, PRIMARY_KEY_SQL, column_definition, column_info,
    inbound_foreign_keys, primary_key,
};
use crate::dialect::MssqlDialect;
use crate::in_band_request::{Interrupt, Watch};
use crate::physical::MssqlClient;
use crate::workspace_call::{catalogue_rows, text_param};

const SCHEMAS_SQL: &str = "SELECT s.name, \
        CAST(CASE WHEN s.schema_id = SCHEMA_ID() THEN 1 ELSE 0 END AS int), \
        CAST(CASE WHEN s.name IN ('sys', 'INFORMATION_SCHEMA', 'guest') OR s.schema_id >= 16384 \
             THEN 1 ELSE 0 END AS int) \
    FROM sys.schemas s ORDER BY s.name";

/// The online databases the login may open, the connection's own the
/// default and the four the server keeps for itself (`database_id` 1 to
/// 4) as system ones.
const DATABASES_SQL: &str = "SELECT d.name, \
        CAST(CASE WHEN d.name = DB_NAME() THEN 1 ELSE 0 END AS int), \
        CAST(CASE WHEN d.database_id <= 4 THEN 1 ELSE 0 END AS int) \
    FROM sys.databases d WHERE d.state = 0 AND HAS_DBACCESS(d.name) = 1 ORDER BY d.name";

/// One read for the objects and their triggers. `{objects}` and
/// `{triggers}` narrow each half to a schema. `parent_class` 1 keeps the
/// triggers of tables and views, not the database's DDL triggers.
const OBJECTS_SQL: &str = "SELECT SCHEMA_NAME(o.schema_id), o.name, RTRIM(o.type), NULL \
    FROM sys.objects o \
    WHERE o.type IN ('U', 'V', 'SO', 'FN', 'IF', 'TF', 'FS', 'FT', 'P', 'PC') AND o.is_ms_shipped = 0{objects} \
    UNION ALL \
    SELECT SCHEMA_NAME(p.schema_id), t.name, 'TR', p.name \
    FROM sys.triggers t JOIN sys.objects p ON p.object_id = t.parent_id \
    WHERE t.parent_class = 1 AND t.is_ms_shipped = 0{triggers} \
    ORDER BY 1, 2, 4";

/// A module's text with what tells why it may have none: a CLR one
/// keeps its code in an assembly, and an encrypted one keeps it hidden.
/// Then the two SET options the module was made under, which decide how
/// its body reads.
const ROUTINE_DEFINITION_SQL: &str = "SELECT OBJECT_DEFINITION(o.object_id), RTRIM(o.type), \
        CAST(OBJECTPROPERTY(o.object_id, 'IsEncrypted') AS int), \
        CAST(m.uses_ansi_nulls AS int), CAST(m.uses_quoted_identifier AS int) \
    FROM sys.objects o LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id \
    WHERE o.schema_id = SCHEMA_ID(COALESCE(@P1, SCHEMA_NAME())) AND o.name = @P2 AND RTRIM(o.type) IN ({types})";

const TRIGGER_DEFINITION_SQL: &str = "SELECT OBJECT_DEFINITION(t.object_id), RTRIM(t.type), \
        CAST(OBJECTPROPERTY(t.object_id, 'IsEncrypted') AS int), \
        CAST(m.uses_ansi_nulls AS int), CAST(m.uses_quoted_identifier AS int) \
    FROM sys.triggers t JOIN sys.objects p ON p.object_id = t.parent_id \
    LEFT JOIN sys.sql_modules m ON m.object_id = t.object_id \
    WHERE t.parent_class = 1 AND t.name = @P2 AND p.name = @P3 \
      AND p.schema_id = SCHEMA_ID(COALESCE(@P1, SCHEMA_NAME()))";

/// The module types whose code is a .NET assembly, not SQL.
const CLR_TYPES: [&str; 4] = ["FS", "FT", "PC", "TA"];

/// The catalogue gives the numbers in the sequence's own type, which can
/// be wider than any integer here, so they come as text.
const SEQUENCE_SQL: &str = "SELECT TYPE_NAME(s.system_type_id), CAST(s.start_value AS nvarchar(64)), \
        CAST(s.increment AS nvarchar(64)), CAST(s.minimum_value AS nvarchar(64)), \
        CAST(s.maximum_value AS nvarchar(64)), CAST(s.is_cycling AS int), CAST(s.is_cached AS int), \
        CAST(s.cache_size AS bigint), CAST(s.precision AS int) \
    FROM sys.sequences s \
    WHERE s.schema_id = SCHEMA_ID(COALESCE(@P1, SCHEMA_NAME())) AND s.name = @P2";

const INDEXES_SQL: &str = "SELECT i.name, CAST(i.is_unique AS int), CAST(i.is_primary_key AS int), c.name, \
        CAST(ic.is_descending_key AS int), i.filter_definition \
    FROM sys.indexes i \
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id \
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id \
    WHERE i.object_id = OBJECT_ID(@P1) AND i.type > 0 AND ic.key_ordinal > 0 \
    ORDER BY i.index_id, ic.key_ordinal";

const FOREIGN_KEYS_SQL: &str = "SELECT fk.name, pc.name, SCHEMA_NAME(rt.schema_id), rt.name, rc.name, \
        fk.delete_referential_action_desc, fk.update_referential_action_desc \
    FROM sys.foreign_keys fk \
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id \
    JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id \
    JOIN sys.objects rt ON rt.object_id = fk.referenced_object_id \
    JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id \
    WHERE fk.parent_object_id = OBJECT_ID(@P1) \
    ORDER BY fk.name, fkc.constraint_column_id";

/// The key that names a row: the primary key, else a unique index over
/// NOT NULL columns with no filter, which covers every row.
const IDENTITY_SQL: &str = "SELECT i.index_id, c.name \
    FROM sys.indexes i \
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0 \
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id \
    WHERE i.object_id = OBJECT_ID(@P1) AND i.is_disabled = 0 AND i.type IN (1, 2) \
      AND (i.is_primary_key = 1 OR (i.is_unique = 1 AND i.has_filter = 0 AND NOT EXISTS ( \
          SELECT 1 FROM sys.index_columns nic \
          JOIN sys.columns nc ON nc.object_id = nic.object_id AND nc.column_id = nic.column_id \
          WHERE nic.object_id = i.object_id AND nic.index_id = i.index_id AND nic.key_ordinal > 0 \
            AND nc.is_nullable = 1))) \
    ORDER BY i.is_primary_key DESC, i.index_id, ic.key_ordinal";

/// The rows of the heap or the clustered index, which every partition
/// counts from the last statistics update.
const ESTIMATE_SQL: &str = "SELECT CAST(SUM(p.rows) AS bigint) \
    FROM sys.partitions p WHERE p.object_id = OBJECT_ID(@P1) AND p.index_id IN (0, 1)";

pub(crate) async fn list_schemas(client: &mut MssqlClient, watch: &Watch) -> Result<Vec<SchemaInfo>, Interrupt> {
    let rows = catalogue_rows(client, watch, SCHEMAS_SQL, &[]).await?;
    rows.iter()
        .map(|row| {
            let cells = Cells::new(row, "sys.schemas");
            Ok(SchemaInfo {
                name: cells.required_text(0)?,
                is_default: cells.flag(1),
                is_system: cells.flag(2),
            })
        })
        .collect::<Result<_, DriverError>>()
        .map_err(Interrupt::Failed)
}

pub(crate) async fn list_databases(client: &mut MssqlClient, watch: &Watch) -> Result<Vec<SchemaInfo>, Interrupt> {
    let rows = catalogue_rows(client, watch, DATABASES_SQL, &[]).await?;
    rows.iter()
        .map(|row| {
            let cells = Cells::new(row, "sys.databases");
            Ok(SchemaInfo {
                name: cells.required_text(0)?,
                is_default: cells.flag(1),
                is_system: cells.flag(2),
            })
        })
        .collect::<Result<_, DriverError>>()
        .map_err(Interrupt::Failed)
}

pub(crate) async fn list_objects(
    client: &mut MssqlClient,
    watch: &Watch,
    scope: &ObjectScope,
) -> Result<Vec<ObjectInfo>, Interrupt> {
    let (objects, triggers, params) = match scope {
        ObjectScope::DefaultSchema => (
            " AND o.schema_id = SCHEMA_ID()",
            " AND p.schema_id = SCHEMA_ID()",
            Vec::new(),
        ),
        ObjectScope::Schema(schema) => (
            " AND o.schema_id = SCHEMA_ID(@P1)",
            " AND p.schema_id = SCHEMA_ID(@P1)",
            vec![text_param(schema)],
        ),
        ObjectScope::AllSchemas => ("", "", Vec::new()),
    };
    let sql = OBJECTS_SQL
        .replace("{objects}", objects)
        .replace("{triggers}", triggers);
    let rows = catalogue_rows(client, watch, &sql, &params).await?;
    let mut listed = Vec::with_capacity(rows.len());
    for row in &rows {
        let cells = Cells::new(row, "sys.objects");
        let Some(kind) = cells.text(2).as_deref().and_then(object_kind) else {
            continue;
        };
        listed.push(ObjectInfo {
            schema: cells.text(0),
            name: cells.required_text(1)?,
            kind,
            parent_table: cells.text(3),
        });
    }
    Ok(listed)
}

/// A dropped object has no row, and one whose text the login may not
/// read has a NULL text: both give `None`, which the server leaves no
/// way to tell apart. The text is kept as written, so a name written
/// without its schema is given it, and it follows the module's SET
/// options, each in a batch of its own, as the server's own scripting
/// writes them.
pub(crate) async fn fetch_object_definition(
    client: &mut MssqlClient,
    watch: &Watch,
    dialect: &MssqlDialect,
    object: &ObjectInfo,
) -> Result<Option<ObjectDefinition>, Interrupt> {
    let schema = optional_text_param(object.schema.as_deref());
    let name = text_param(&object.name);
    let (sql, params) = match (object.kind, object.parent_table.as_deref()) {
        (ObjectKind::Function, _) => (
            ROUTINE_DEFINITION_SQL.replace("{types}", "'FN', 'IF', 'TF', 'FS', 'FT'"),
            vec![schema, name],
        ),
        (ObjectKind::Procedure, _) => (
            ROUTINE_DEFINITION_SQL.replace("{types}", "'P', 'PC'"),
            vec![schema, name],
        ),
        (ObjectKind::Trigger, Some(table)) => {
            (TRIGGER_DEFINITION_SQL.to_owned(), vec![schema, name, text_param(table)])
        }
        (ObjectKind::Sequence, _) => return sequence_definition(client, watch, dialect, object).await,
        _ => {
            return Err(Interrupt::Failed(DriverError::Unsupported {
                feature: UnsupportedFeature::ObjectDefinitions,
            }));
        }
    };
    let rows = catalogue_rows(client, watch, &sql, &params).await?;
    let Some(row) = rows.first() else {
        return Ok(None);
    };
    let cells = Cells::new(row, "OBJECT_DEFINITION");
    let Some(text) = cells.text(0) else {
        let feature = if cells.text(1).is_some_and(|code| CLR_TYPES.contains(&code.as_str())) {
            UnsupportedFeature::ClrRoutine
        } else if cells.flag(2) {
            UnsupportedFeature::EncryptedDefinition
        } else {
            return Ok(None);
        };
        return Err(Interrupt::Failed(DriverError::Unsupported { feature }));
    };
    let opens_in_editor = !holds_client_directive(&text, SqlGrammar::MsSql);
    let module = match object.schema.as_deref() {
        Some(schema) => qualify_created_name(&text, SqlGrammar::MsSql, &dialect.quote_identifier(schema)),
        None => text,
    };
    let on_off = |at: usize| if cells.flag(at) { "ON" } else { "OFF" };
    Ok(Some(ObjectDefinition {
        sql: format!(
            "SET ANSI_NULLS {}\nGO\nSET QUOTED_IDENTIFIER {}\nGO\n{module}",
            on_off(3),
            on_off(4)
        ),
        database: None,
        opens_in_editor,
    }))
}

/// SQL Server has no function that prints a sequence, so the statement
/// is built from the catalogue.
async fn sequence_definition(
    client: &mut MssqlClient,
    watch: &Watch,
    dialect: &MssqlDialect,
    object: &ObjectInfo,
) -> Result<Option<ObjectDefinition>, Interrupt> {
    let params = [optional_text_param(object.schema.as_deref()), text_param(&object.name)];
    let rows = catalogue_rows(client, watch, SEQUENCE_SQL, &params).await?;
    let Some(row) = rows.first() else {
        return Ok(None);
    };
    let qualified = dialect.qualify(&TableRef::new(object.schema.clone(), object.name.clone()));
    let sequence = SequenceRow::from_cells(&Cells::new(row, "sys.sequences")).map_err(Interrupt::Failed)?;
    Ok(Some(ObjectDefinition {
        sql: sequence_statement(&qualified, &sequence),
        database: None,
        opens_in_editor: true,
    }))
}

struct SequenceRow {
    type_name: String,
    start: String,
    increment: String,
    minimum: String,
    maximum: String,
    cycles: bool,
    cached: bool,
    cache_size: Option<i64>,
    precision: i64,
}

impl SequenceRow {
    fn from_cells(cells: &Cells<'_>) -> Result<Self, DriverError> {
        Ok(Self {
            type_name: cells.required_text(0)?,
            start: cells.required_text(1)?,
            increment: cells.required_text(2)?,
            minimum: cells.required_text(3)?,
            maximum: cells.required_text(4)?,
            cycles: cells.flag(5),
            cached: cells.flag(6),
            cache_size: cells.int(7),
            precision: cells.int(8).unwrap_or(0),
        })
    }
}

fn sequence_statement(qualified: &str, row: &SequenceRow) -> String {
    let data_type = match row.type_name.as_str() {
        "decimal" | "numeric" => format!("{}({})", row.type_name, row.precision),
        other => other.to_owned(),
    };
    let cycle = if row.cycles { "CYCLE" } else { "NO CYCLE" };
    let cache = match (row.cached, row.cache_size) {
        (true, Some(size)) => format!("CACHE {size}"),
        (true, None) => "CACHE".to_owned(),
        (false, _) => "NO CACHE".to_owned(),
    };
    format!(
        "CREATE SEQUENCE {qualified} AS {data_type} START WITH {} INCREMENT BY {} MINVALUE {} MAXVALUE {} {cycle} {cache};",
        row.start, row.increment, row.minimum, row.maximum
    )
}

fn object_kind(code: &str) -> Option<ObjectKind> {
    match code {
        "U" => Some(ObjectKind::Table),
        "V" => Some(ObjectKind::View),
        "SO" => Some(ObjectKind::Sequence),
        "FN" | "IF" | "TF" | "FS" | "FT" => Some(ObjectKind::Function),
        "P" | "PC" => Some(ObjectKind::Procedure),
        "TR" => Some(ObjectKind::Trigger),
        _ => None,
    }
}

fn optional_text_param(text: Option<&str>) -> ColumnData<'static> {
    ColumnData::String(text.map(|text| text.to_owned().into()))
}

async fn column_rows(
    client: &mut MssqlClient,
    watch: &Watch,
    relation: &str,
) -> Result<Vec<MssqlColumnRow>, Interrupt> {
    let rows = catalogue_rows(client, watch, COLUMNS_SQL, &[text_param(relation)]).await?;
    rows.iter()
        .map(|row| MssqlColumnRow::from_values(row))
        .collect::<Result<_, DriverError>>()
        .map_err(Interrupt::Failed)
}

pub(crate) async fn fetch_columns(
    client: &mut MssqlClient,
    watch: &Watch,
    relation: &str,
) -> Result<Vec<ColumnInfo>, Interrupt> {
    Ok(column_rows(client, watch, relation)
        .await?
        .iter()
        .map(column_info)
        .collect())
}

pub(crate) async fn fetch_indexes(
    client: &mut MssqlClient,
    watch: &Watch,
    relation: &str,
) -> Result<Vec<IndexInfo>, Interrupt> {
    let rows = catalogue_rows(client, watch, INDEXES_SQL, &[text_param(relation)]).await?;
    Ok(indexes(&rows)?)
}

fn indexes(rows: &[Vec<Value>]) -> Result<Vec<IndexInfo>, DriverError> {
    let mut indexes: Vec<IndexInfo> = Vec::new();
    for row in rows {
        let cells = Cells::new(row, "sys.indexes");
        let name = cells.required_text(0)?;
        let key = IndexKey::Column {
            name: cells.required_text(3)?,
            descending: cells.flag(4),
        };
        match indexes.last_mut() {
            Some(index) if index.name == name => index.keys.push(key),
            _ => indexes.push(IndexInfo {
                name,
                keys: vec![key],
                unique: cells.flag(1),
                primary: cells.flag(2),
                predicate: cells.text(5),
            }),
        }
    }
    Ok(indexes)
}

pub(crate) async fn fetch_foreign_keys(
    client: &mut MssqlClient,
    watch: &Watch,
    relation: &str,
) -> Result<Vec<ForeignKeyInfo>, Interrupt> {
    let rows = catalogue_rows(client, watch, FOREIGN_KEYS_SQL, &[text_param(relation)]).await?;
    Ok(foreign_keys(&rows)?)
}

fn foreign_keys(rows: &[Vec<Value>]) -> Result<Vec<ForeignKeyInfo>, DriverError> {
    let mut keys: Vec<ForeignKeyInfo> = Vec::new();
    for row in rows {
        let cells = Cells::new(row, "sys.foreign_keys");
        let name = cells.required_text(0)?;
        let column = cells.required_text(1)?;
        let referenced = cells.required_text(4)?;
        match keys.last_mut() {
            Some(key) if key.name == name => {
                key.columns.push(column);
                key.ref_columns.push(referenced);
            }
            _ => keys.push(ForeignKeyInfo {
                name,
                columns: vec![column],
                ref_schema: cells.text(2),
                ref_table: cells.required_text(3)?,
                ref_columns: vec![referenced],
                on_delete: cells.text(5).as_deref().and_then(referential_action),
                on_update: cells.text(6).as_deref().and_then(referential_action),
            }),
        }
    }
    Ok(keys)
}

/// `sys.foreign_keys` spells each action as its `_desc` text.
fn referential_action(description: &str) -> Option<ReferentialAction> {
    match description {
        "NO_ACTION" => Some(ReferentialAction::NoAction),
        "CASCADE" => Some(ReferentialAction::Cascade),
        "SET_NULL" => Some(ReferentialAction::SetNull),
        "SET_DEFAULT" => Some(ReferentialAction::SetDefault),
        _ => None,
    }
}

pub(crate) async fn row_identity(
    client: &mut MssqlClient,
    watch: &Watch,
    relation: &str,
) -> Result<RowIdentity, Interrupt> {
    let rows = catalogue_rows(client, watch, IDENTITY_SQL, &[text_param(relation)]).await?;
    Ok(identity(&rows)?)
}

/// The first key's columns. SQL Server has no row address a later
/// statement could name again, so a table without such a key cannot
/// have its rows edited.
fn identity(rows: &[Vec<Value>]) -> Result<RowIdentity, DriverError> {
    let mut columns = Vec::new();
    let mut chosen = None;
    for row in rows {
        let cells = Cells::new(row, "sys.indexes");
        let index = cells.int(0);
        if chosen.is_some_and(|chosen| Some(chosen) != index) {
            break;
        }
        chosen = index;
        columns.push(cells.required_text(1)?);
    }
    Ok(match columns.is_empty() {
        true => RowIdentity::Unordered,
        false => RowIdentity::UniqueKey { columns },
    })
}

pub(crate) async fn table_estimate(
    client: &mut MssqlClient,
    watch: &Watch,
    relation: &str,
) -> Result<TableEstimate, Interrupt> {
    let rows = catalogue_rows(client, watch, ESTIMATE_SQL, &[text_param(relation)]).await?;
    let counted = rows.first().and_then(|row| Cells::new(row, "sys.partitions").int(0));
    Ok(TableEstimate {
        rows: match counted.and_then(|rows| u64::try_from(rows).ok()) {
            Some(rows) => RowCountEstimate::Approximate(rows),
            None => RowCountEstimate::Unknown,
        },
        heap_blocks: None,
    })
}

/// The table as a structure change plans against it, read in one call
/// on one connection.
pub(crate) async fn fetch_table_definition(
    client: &mut MssqlClient,
    watch: &Watch,
    table: &TableRef,
    relation: &str,
) -> Result<TableDefinition, Interrupt> {
    let columns = column_rows(client, watch, relation).await?;
    let primary = catalogue_rows(client, watch, PRIMARY_KEY_SQL, &[text_param(relation)]).await?;
    let indexes = fetch_indexes(client, watch, relation).await?;
    let foreign_keys = fetch_foreign_keys(client, watch, relation).await?;
    let inbound_foreign_keys = fetch_inbound_foreign_keys(client, watch, relation).await?;
    Ok(TableDefinition {
        table: table.clone(),
        columns: columns.iter().map(column_definition).collect(),
        primary_key: primary_key(&primary)?,
        indexes,
        foreign_keys,
        inbound_foreign_keys,
        source: None,
        options: None,
    })
}

pub(crate) async fn fetch_inbound_foreign_keys(
    client: &mut MssqlClient,
    watch: &Watch,
    relation: &str,
) -> Result<Vec<InboundForeignKey>, Interrupt> {
    let rows = catalogue_rows(client, watch, INBOUND_FOREIGN_KEYS_SQL, &[text_param(relation)]).await?;
    Ok(inbound_foreign_keys(&rows)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    fn sequence(type_name: &str) -> SequenceRow {
        SequenceRow {
            type_name: type_name.to_owned(),
            start: "100".to_owned(),
            increment: "5".to_owned(),
            minimum: "1".to_owned(),
            maximum: "9999".to_owned(),
            cycles: false,
            cached: true,
            cache_size: Some(20),
            precision: 18,
        }
    }

    #[test]
    fn a_sequence_statement_names_every_catalogue_setting() {
        assert_eq!(
            sequence_statement("[dbo].[invoices]", &sequence("bigint")),
            "CREATE SEQUENCE [dbo].[invoices] AS bigint START WITH 100 INCREMENT BY 5 MINVALUE 1 MAXVALUE 9999 \
             NO CYCLE CACHE 20;"
        );
    }

    #[test]
    fn a_sequence_statement_keeps_precision_cycling_and_the_default_cache() {
        let mut row = sequence("numeric");
        row.cycles = true;
        row.cache_size = None;
        let statement = sequence_statement("[s]", &row);
        assert!(statement.contains("AS numeric(18) "), "{statement}");
        assert!(statement.ends_with(" CYCLE CACHE;"), "{statement}");
        row.cached = false;
        assert!(sequence_statement("[s]", &row).ends_with(" CYCLE NO CACHE;"));
    }

    #[test]
    fn referential_actions_map_to_keywords() {
        assert_eq!(referential_action("CASCADE"), Some(ReferentialAction::Cascade));
        assert_eq!(referential_action("SET_NULL"), Some(ReferentialAction::SetNull));
        assert_eq!(referential_action("SET_DEFAULT"), Some(ReferentialAction::SetDefault));
        assert_eq!(referential_action("NO_ACTION"), Some(ReferentialAction::NoAction));
        assert_eq!(referential_action("?"), None);
    }

    #[test]
    fn object_codes_map_to_kinds() {
        assert_eq!(object_kind("U"), Some(ObjectKind::Table));
        assert_eq!(object_kind("SO"), Some(ObjectKind::Sequence));
        assert_eq!(object_kind("IF"), Some(ObjectKind::Function));
        assert_eq!(object_kind("TR"), Some(ObjectKind::Trigger));
        assert_eq!(object_kind("PC"), Some(ObjectKind::Procedure));
        assert_eq!(object_kind("D"), None);
    }

    #[test]
    fn index_rows_group_into_keys_with_direction_and_filter() {
        let rows = vec![
            vec![
                text("IX_a"),
                Value::Int(1),
                Value::Int(0),
                text("a"),
                Value::Int(0),
                text("([a]>(0))"),
            ],
            vec![
                text("IX_a"),
                Value::Int(1),
                Value::Int(0),
                text("b"),
                Value::Int(1),
                text("([a]>(0))"),
            ],
            vec![
                text("PK_t"),
                Value::Int(1),
                Value::Int(1),
                text("id"),
                Value::Int(0),
                Value::Null,
            ],
        ];

        let indexes = indexes(&rows).unwrap();

        assert_eq!(indexes.len(), 2);
        assert_eq!(indexes[0].keys.len(), 2);
        assert!(indexes[0].keys[1].descending());
        assert_eq!(indexes[0].predicate.as_deref(), Some("([a]>(0))"));
        assert!(!indexes[0].can_identify_rows());
        assert!(indexes[1].primary && indexes[1].can_identify_rows());
    }

    #[test]
    fn the_first_key_names_the_row() {
        let rows = vec![
            vec![Value::Int(1), text("tenant")],
            vec![Value::Int(1), text("id")],
            vec![Value::Int(3), text("email")],
        ];

        assert_eq!(
            identity(&rows).unwrap(),
            RowIdentity::UniqueKey {
                columns: vec!["tenant".to_owned(), "id".to_owned()]
            }
        );
        assert_eq!(identity(&[]).unwrap(), RowIdentity::Unordered);
    }

    #[test]
    fn foreign_key_rows_group_by_constraint() {
        let rows = vec![
            vec![
                text("FK_l_o"),
                text("order_id"),
                text("dbo"),
                text("orders"),
                text("id"),
                text("CASCADE"),
                text("NO_ACTION"),
            ],
            vec![
                text("FK_l_o"),
                text("tenant"),
                text("dbo"),
                text("orders"),
                text("tenant"),
                text("CASCADE"),
                text("NO_ACTION"),
            ],
        ];

        let keys = foreign_keys(&rows).unwrap();

        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].columns, ["order_id", "tenant"]);
        assert_eq!(keys[0].ref_columns, ["id", "tenant"]);
        assert_eq!(keys[0].on_delete, Some(ReferentialAction::Cascade));
        assert!(keys[0].references(Some("dbo"), "orders"));
    }
}
