use std::fmt;

/// One kind of structure change, named in an error that refuses it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DdlOperation {
    CreateTable,
    AlterTable,
    DropTable,
    DropTableCascade,
    RenameTable,
    AddColumn,
    /// SQLite refuses `ADD COLUMN ... NOT NULL` without a default,
    /// because the rows already there would have no value.
    AddRequiredColumnWithoutDefault,
    DropColumn,
    RenameColumn,
    AlterColumnType,
    AlterColumnNullability,
    AlterColumnDefault,
    AlterPrimaryKey,
    AlterAutoIncrement,
    SetColumnComment,
    /// A column's own character set or collation.
    AlterColumnCollation,
    /// The table's default character set and collation, a convert of its
    /// columns, or its next AUTO_INCREMENT value.
    AlterTableOptions,
    CreateIndex,
    IndexExpressionKey,
    DescendingIndexKey,
    PartialIndex,
    DropIndex,
    AddForeignKey,
    DropForeignKey,
    /// A default on a column, on an engine with no column defaults.
    ColumnDefault,
    /// NOT NULL on a column outside the primary key, on an engine with
    /// no such constraint.
    RequiredColumn,
    TruncateTable,
    /// Emptying the tables whose foreign keys point at the table too.
    TruncateTableCascade,
    /// Starting a table's numbering again as it is emptied.
    TruncateRestartIdentity,
    CreateSchema,
    DropSchema,
    /// Dropping a schema with everything in it.
    DropSchemaCascade,
    /// An owner other than the user who creates a schema or database.
    CatalogOwner,
    CreateDatabase,
    DropDatabase,
    /// Closing the other sessions on a database so it can be dropped.
    DropDatabaseForce,
    /// Running the statement on every server of a cluster.
    OnCluster,
}

impl fmt::Display for DdlOperation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::CreateTable => "creating a table",
            Self::AlterTable => "changing a table",
            Self::DropTable => "dropping a table",
            Self::DropTableCascade => "dropping a table with its dependents",
            Self::RenameTable => "renaming a table",
            Self::AddColumn => "adding a column",
            Self::AddRequiredColumnWithoutDefault => "adding a NOT NULL column without a default",
            Self::DropColumn => "dropping a column",
            Self::RenameColumn => "renaming a column",
            Self::AlterColumnType => "changing a column's type",
            Self::AlterColumnNullability => "changing whether a column takes NULL",
            Self::AlterColumnDefault => "changing a column's default",
            Self::AlterPrimaryKey => "changing the primary key",
            Self::AlterAutoIncrement => "changing whether a column numbers itself",
            Self::SetColumnComment => "setting a column comment",
            Self::AlterColumnCollation => "changing a column's character set or collation",
            Self::AlterTableOptions => "changing the table's character set or AUTO_INCREMENT value",
            Self::CreateIndex => "creating an index",
            Self::IndexExpressionKey => "an index on an expression",
            Self::DescendingIndexKey => "a descending index key",
            Self::PartialIndex => "a partial index",
            Self::DropIndex => "dropping an index",
            Self::AddForeignKey => "adding a foreign key",
            Self::DropForeignKey => "dropping a foreign key",
            Self::ColumnDefault => "a column default",
            Self::RequiredColumn => "a column that refuses NULL outside the primary key",
            Self::TruncateTable => "emptying a table",
            Self::TruncateTableCascade => "emptying a table with the tables that reference it",
            Self::TruncateRestartIdentity => "restarting a table's numbering",
            Self::CreateSchema => "creating a schema",
            Self::DropSchema => "dropping a schema",
            Self::DropSchemaCascade => "dropping a schema with everything in it",
            Self::CatalogOwner => "naming an owner",
            Self::CreateDatabase => "creating a database",
            Self::DropDatabase => "dropping a database",
            Self::DropDatabaseForce => "closing other sessions on a database",
            Self::OnCluster => "running on a cluster",
        })
    }
}
