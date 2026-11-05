use tablepro_core::DriverError;
use tokio_postgres::Row;

use crate::codec::TextArray;
use crate::metadata::{decode_error, in_tablespace, without_only};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Extension {
    pub(super) name: String,
    pub(super) schema: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Collation {
    pub(super) schema: String,
    pub(super) name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Domain {
    pub(super) base: String,
    pub(super) not_null: bool,
    pub(super) default: Option<String>,
    pub(super) collation: Option<Collation>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum TypeShape {
    Enum(Vec<String>),
    Domain(Domain),
    Composite,
    /// A range or a base type.
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct UserType {
    pub(super) schema: String,
    pub(super) name: String,
    pub(super) shape: TypeShape,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct DomainCheck {
    pub(super) schema: String,
    pub(super) domain: String,
    pub(super) name: String,
    pub(super) definition: String,
    pub(super) validated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Routine {
    pub(super) schema: String,
    pub(super) name: String,
    /// `pg_proc.prokind`.
    pub(super) kind: String,
    pub(super) definition: Option<String>,
    /// The body is standard SQL, which the server parses when the routine
    /// is created, so what it names must exist first.
    pub(super) sql_body: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct SequenceOwner {
    pub(super) identity: bool,
    pub(super) schema: String,
    pub(super) table: String,
    pub(super) column: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Sequence {
    pub(super) schema: String,
    pub(super) name: String,
    pub(super) data_type: String,
    pub(super) start: i64,
    pub(super) increment: i64,
    pub(super) min: i64,
    pub(super) max: i64,
    pub(super) cache: i64,
    pub(super) cycle: bool,
    pub(super) unlogged: bool,
    pub(super) last_value: Option<i64>,
    pub(super) owner: Option<SequenceOwner>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Partition {
    pub(super) parent_schema: String,
    pub(super) parent: String,
    pub(super) bound: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Table {
    pub(super) schema: String,
    pub(super) name: String,
    /// `pg_class.relkind`: `r`, `p` or `f`.
    pub(super) kind: String,
    pub(super) unlogged: bool,
    pub(super) partition_key: Option<String>,
    pub(super) partition: Option<Partition>,
    pub(super) inherits: bool,
    pub(super) options: Vec<String>,
    pub(super) access_method: Option<String>,
    pub(super) tablespace: Option<String>,
    pub(super) comment: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Column {
    pub(super) schema: String,
    pub(super) table: String,
    pub(super) name: String,
    pub(super) type_sql: String,
    pub(super) collation: Option<Collation>,
    /// The DEFAULT, or a generated column's expression.
    pub(super) default: Option<String>,
    /// `pg_attribute.attidentity`, empty when the column has none.
    pub(super) identity: String,
    /// `pg_attribute.attgenerated`, empty when the column is not.
    pub(super) generated: String,
    pub(super) not_null: bool,
    pub(super) comment: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Constraint {
    pub(super) schema: String,
    pub(super) table: String,
    pub(super) partitioned: bool,
    pub(super) name: String,
    /// `pg_constraint.contype`.
    pub(super) kind: String,
    pub(super) definition: String,
    pub(super) validated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Index {
    pub(super) schema: String,
    /// The table or materialized view it is on.
    pub(super) table: String,
    pub(super) name: String,
    pub(super) statement: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct View {
    pub(super) schema: String,
    pub(super) name: String,
    pub(super) materialized: bool,
    pub(super) definition: String,
    pub(super) options: Vec<String>,
    pub(super) populated: bool,
    pub(super) access_method: Option<String>,
    pub(super) tablespace: Option<String>,
    pub(super) comment: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Trigger {
    pub(super) schema: String,
    pub(super) table: String,
    pub(super) name: String,
    pub(super) definition: String,
    /// `pg_trigger.tgenabled`.
    pub(super) enabled: String,
}

fn collation(schema: Option<String>, name: Option<String>) -> Option<Collation> {
    Some(Collation {
        schema: schema?,
        name: name?,
    })
}

fn options(array: Option<TextArray>) -> Vec<String> {
    array.map(|array| array.0).unwrap_or_default()
}

pub(super) fn schema_name(row: &Row) -> Result<String, DriverError> {
    row.try_get(0).map_err(decode_error("pg_namespace"))
}

pub(super) fn extension(row: &Row) -> Result<Extension, DriverError> {
    let field = decode_error("pg_extension");
    Ok(Extension {
        name: row.try_get(0).map_err(&field)?,
        schema: row.try_get(1).map_err(&field)?,
    })
}

pub(super) fn user_type(row: &Row) -> Result<UserType, DriverError> {
    let field = decode_error("pg_type");
    let typtype: String = row.try_get(2).map_err(&field)?;
    let shape = match typtype.as_str() {
        "e" => TypeShape::Enum(row.try_get::<_, TextArray>(3).map_err(&field)?.0),
        "d" => TypeShape::Domain(Domain {
            base: row.try_get(4).map_err(&field)?,
            not_null: row.try_get(5).map_err(&field)?,
            default: row.try_get(6).map_err(&field)?,
            collation: collation(row.try_get(7).map_err(&field)?, row.try_get(8).map_err(&field)?),
        }),
        "c" => TypeShape::Composite,
        _ => TypeShape::Other,
    };
    Ok(UserType {
        schema: row.try_get(0).map_err(&field)?,
        name: row.try_get(1).map_err(&field)?,
        shape,
    })
}

pub(super) fn domain_check(row: &Row) -> Result<DomainCheck, DriverError> {
    let field = decode_error("pg_constraint");
    Ok(DomainCheck {
        schema: row.try_get(0).map_err(&field)?,
        domain: row.try_get(1).map_err(&field)?,
        name: row.try_get(2).map_err(&field)?,
        definition: row.try_get(3).map_err(&field)?,
        validated: row.try_get(4).map_err(&field)?,
    })
}

pub(super) fn routine(row: &Row) -> Result<Routine, DriverError> {
    let field = decode_error("pg_proc");
    Ok(Routine {
        schema: row.try_get(0).map_err(&field)?,
        name: row.try_get(1).map_err(&field)?,
        kind: row.try_get(2).map_err(&field)?,
        definition: row.try_get(3).map_err(&field)?,
        sql_body: row.try_get(4).map_err(&field)?,
    })
}

pub(super) fn sequence(row: &Row) -> Result<Sequence, DriverError> {
    let field = decode_error("pg_sequences");
    let persistence: String = row.try_get(9).map_err(&field)?;
    let dependency: Option<String> = row.try_get(11).map_err(&field)?;
    let owner_schema: Option<String> = row.try_get(12).map_err(&field)?;
    let owner_table: Option<String> = row.try_get(13).map_err(&field)?;
    let owner_column: Option<String> = row.try_get(14).map_err(&field)?;
    let owner = match (dependency, owner_schema, owner_table, owner_column) {
        (Some(dependency), Some(schema), Some(table), Some(column)) => Some(SequenceOwner {
            identity: dependency == "i",
            schema,
            table,
            column,
        }),
        _ => None,
    };
    Ok(Sequence {
        schema: row.try_get(0).map_err(&field)?,
        name: row.try_get(1).map_err(&field)?,
        data_type: row.try_get(2).map_err(&field)?,
        start: row.try_get(3).map_err(&field)?,
        increment: row.try_get(4).map_err(&field)?,
        min: row.try_get(5).map_err(&field)?,
        max: row.try_get(6).map_err(&field)?,
        cache: row.try_get(7).map_err(&field)?,
        cycle: row.try_get(8).map_err(&field)?,
        unlogged: persistence == "u",
        last_value: row.try_get(10).map_err(&field)?,
        owner,
    })
}

pub(super) fn table(row: &Row) -> Result<Table, DriverError> {
    let field = decode_error("pg_class");
    let persistence: String = row.try_get(3).map_err(&field)?;
    let bound: Option<String> = row.try_get(5).map_err(&field)?;
    let parent_schema: Option<String> = row.try_get(6).map_err(&field)?;
    let parent: Option<String> = row.try_get(7).map_err(&field)?;
    let partition = match (bound, parent_schema, parent) {
        (Some(bound), Some(parent_schema), Some(parent)) => Some(Partition {
            parent_schema,
            parent,
            bound,
        }),
        _ => None,
    };
    Ok(Table {
        schema: row.try_get(0).map_err(&field)?,
        name: row.try_get(1).map_err(&field)?,
        kind: row.try_get(2).map_err(&field)?,
        unlogged: persistence == "u",
        partition_key: row.try_get(4).map_err(&field)?,
        partition,
        inherits: row.try_get(8).map_err(&field)?,
        options: options(row.try_get(9).map_err(&field)?),
        access_method: row.try_get(10).map_err(&field)?,
        tablespace: row.try_get(11).map_err(&field)?,
        comment: row.try_get(12).map_err(&field)?,
    })
}

pub(super) fn column(row: &Row) -> Result<Column, DriverError> {
    let field = decode_error("pg_attribute");
    Ok(Column {
        schema: row.try_get(0).map_err(&field)?,
        table: row.try_get(1).map_err(&field)?,
        name: row.try_get(2).map_err(&field)?,
        type_sql: row.try_get(3).map_err(&field)?,
        collation: collation(row.try_get(4).map_err(&field)?, row.try_get(5).map_err(&field)?),
        default: row.try_get(6).map_err(&field)?,
        identity: row.try_get(7).map_err(&field)?,
        generated: row.try_get(8).map_err(&field)?,
        not_null: row.try_get(9).map_err(&field)?,
        comment: row.try_get(10).map_err(&field)?,
    })
}

pub(super) fn constraint(row: &Row) -> Result<Constraint, DriverError> {
    let field = decode_error("pg_constraint");
    let relkind: String = row.try_get(2).map_err(&field)?;
    Ok(Constraint {
        schema: row.try_get(0).map_err(&field)?,
        table: row.try_get(1).map_err(&field)?,
        partitioned: relkind == "p",
        name: row.try_get(3).map_err(&field)?,
        kind: row.try_get(4).map_err(&field)?,
        definition: row.try_get(5).map_err(&field)?,
        validated: row.try_get(6).map_err(&field)?,
    })
}

pub(super) fn index(row: &Row) -> Result<Index, DriverError> {
    let field = decode_error("pg_index");
    let mut statement: String = row.try_get(3).map_err(&field)?;
    if row.try_get(4).map_err(&field)? {
        let quoted_name: String = row.try_get(6).map_err(&field)?;
        statement = without_only(statement, row.try_get(5).map_err(&field)?, &quoted_name);
    }
    if let Some(tablespace) = row.try_get::<_, Option<String>>(7).map_err(&field)? {
        let predicate: Option<String> = row.try_get(8).map_err(&field)?;
        statement = in_tablespace(statement, &tablespace, predicate.as_deref());
    }
    Ok(Index {
        schema: row.try_get(0).map_err(&field)?,
        table: row.try_get(1).map_err(&field)?,
        name: row.try_get(2).map_err(&field)?,
        statement,
    })
}

pub(super) fn view(row: &Row) -> Result<View, DriverError> {
    let field = decode_error("pg_class");
    let relkind: String = row.try_get(2).map_err(&field)?;
    Ok(View {
        schema: row.try_get(0).map_err(&field)?,
        name: row.try_get(1).map_err(&field)?,
        materialized: relkind == "m",
        definition: row.try_get(3).map_err(&field)?,
        options: options(row.try_get(4).map_err(&field)?),
        populated: row.try_get(5).map_err(&field)?,
        access_method: row.try_get(6).map_err(&field)?,
        tablespace: row.try_get(7).map_err(&field)?,
        comment: row.try_get(8).map_err(&field)?,
    })
}

pub(super) fn trigger(row: &Row) -> Result<Trigger, DriverError> {
    let field = decode_error("pg_trigger");
    Ok(Trigger {
        schema: row.try_get(0).map_err(&field)?,
        table: row.try_get(1).map_err(&field)?,
        name: row.try_get(2).map_err(&field)?,
        definition: row.try_get(3).map_err(&field)?,
        enabled: row.try_get(4).map_err(&field)?,
    })
}
