use tablepro_core::ColumnInfo;
use tablepro_core::meta::{ObjectInfo, ObjectKind, ObjectScope, SchemaInfo, TableRef};

use crate::results::ValueKind;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SchemaEntry {
    pub name: String,
    pub is_default: bool,
    pub is_system: bool,
}

/// Which schemas to list objects from.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ObjectScopeArg {
    DefaultSchema,
    Schema { name: String },
    AllSchemas,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ObjectEntry {
    pub schema: Option<String>,
    pub name: String,
    pub kind: ObjectKindTag,
    /// The table a trigger fires on.
    pub parent_table: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ObjectKindTag {
    Table,
    PartitionedTable,
    View,
    MaterializedView,
    ForeignTable,
    Sequence,
    Function,
    Procedure,
    Trigger,
    Dictionary,
    Key,
    /// A kind a later driver reports that this build does not name.
    Other,
}

/// A table, named the way the server qualifies it. No schema means the
/// engine has none, or the connection's default one.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableName {
    pub schema: Option<String>,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ColumnEntry {
    pub name: String,
    /// The type as the server spells it, for display.
    pub type_name: String,
    pub value_kind: ValueKind,
    pub nullable: bool,
    pub primary_key: bool,
    pub auto_increment: bool,
    pub generated: bool,
    pub comment: Option<String>,
}

impl From<&SchemaInfo> for SchemaEntry {
    fn from(schema: &SchemaInfo) -> Self {
        Self {
            name: schema.name.clone(),
            is_default: schema.is_default,
            is_system: schema.is_system,
        }
    }
}

impl From<ObjectScopeArg> for ObjectScope {
    fn from(scope: ObjectScopeArg) -> Self {
        match scope {
            ObjectScopeArg::DefaultSchema => Self::DefaultSchema,
            ObjectScopeArg::Schema { name } => Self::Schema(name),
            ObjectScopeArg::AllSchemas => Self::AllSchemas,
        }
    }
}

impl From<&ObjectInfo> for ObjectEntry {
    fn from(object: &ObjectInfo) -> Self {
        Self {
            schema: object.schema.clone(),
            name: object.name.clone(),
            kind: ObjectKindTag::from(object.kind),
            parent_table: object.parent_table.clone(),
        }
    }
}

impl From<ObjectKind> for ObjectKindTag {
    fn from(kind: ObjectKind) -> Self {
        match kind {
            ObjectKind::Table => Self::Table,
            ObjectKind::PartitionedTable => Self::PartitionedTable,
            ObjectKind::View => Self::View,
            ObjectKind::MaterializedView => Self::MaterializedView,
            ObjectKind::ForeignTable => Self::ForeignTable,
            ObjectKind::Sequence => Self::Sequence,
            ObjectKind::Function => Self::Function,
            ObjectKind::Procedure => Self::Procedure,
            ObjectKind::Trigger => Self::Trigger,
            ObjectKind::Dictionary => Self::Dictionary,
            ObjectKind::Key(_) => Self::Key,
            _ => Self::Other,
        }
    }
}

impl From<TableName> for TableRef {
    fn from(table: TableName) -> Self {
        Self::new(table.schema, table.name)
    }
}

impl From<&ColumnInfo> for ColumnEntry {
    fn from(column: &ColumnInfo) -> Self {
        Self {
            name: column.name.clone(),
            type_name: column.column_type.name.clone(),
            value_kind: ValueKind::of_column(&column.column_type.kind),
            nullable: column.nullable,
            primary_key: column.primary_key,
            auto_increment: column.is_auto_increment,
            generated: column.is_generated,
            comment: column.comment.clone(),
        }
    }
}
