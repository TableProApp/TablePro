use std::fmt;

/// One kind of structure change, named in an error that refuses it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DdlOperation {
    CreateTable,
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
    CreateIndex,
    IndexExpressionKey,
    PartialIndex,
    DropIndex,
    AddForeignKey,
    DropForeignKey,
}

impl fmt::Display for DdlOperation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::CreateTable => "creating a table",
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
            Self::CreateIndex => "creating an index",
            Self::IndexExpressionKey => "an index on an expression",
            Self::PartialIndex => "a partial index",
            Self::DropIndex => "dropping an index",
            Self::AddForeignKey => "adding a foreign key",
            Self::DropForeignKey => "dropping a foreign key",
        })
    }
}
