use crate::meta::TableRef;

/// What a dump covers.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum DumpScope {
    /// Every schema of the connection's database, the engine's own left
    /// out. On an engine whose databases are its schemas, the database the
    /// connection is in.
    Database,
    Schema(String),
}

/// Where an object goes in the file, in the order a restore needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum DumpSection {
    /// Schemas, extensions, types, sequences, routines a table can name,
    /// and the tables themselves.
    BeforeData,
    /// What would slow the rows down or refuse them in the wrong order:
    /// sequence positions, keys, indexes, foreign keys, comments.
    AfterData,
    /// Views and routines, ordered by the names their text mentions.
    Programs,
    /// Last, so loading the rows fires none of them.
    Triggers,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum DumpObjectKind {
    Schema,
    Extension,
    Type,
    Sequence,
    Function,
    Procedure,
    Table,
    Index,
    Constraint,
    ForeignKey,
    SequenceValue,
    Comment,
    View,
    MaterializedView,
    Trigger,
    Dictionary,
}

impl DumpObjectKind {
    /// The word the file's comment line names the object with.
    pub fn label(self) -> &'static str {
        match self {
            Self::Schema => "Schema",
            Self::Extension => "Extension",
            Self::Type => "Type",
            Self::Sequence => "Sequence",
            Self::Function => "Function",
            Self::Procedure => "Procedure",
            Self::Table => "Table",
            Self::Index => "Index",
            Self::Constraint => "Constraint",
            Self::ForeignKey => "Foreign key",
            Self::SequenceValue => "Sequence value",
            Self::Comment => "Comment",
            Self::View => "View",
            Self::MaterializedView => "Materialized view",
            Self::Trigger => "Trigger",
            Self::Dictionary => "Dictionary",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DumpStatement {
    /// The statement with no terminator.
    pub sql: String,
    /// It holds a routine body with semicolons of its own, which MySQL's
    /// client reads as one statement only inside a `DELIMITER` block.
    pub body: bool,
}

impl DumpStatement {
    pub fn new(sql: impl Into<String>) -> Self {
        Self {
            sql: sql.into(),
            body: false,
        }
    }

    pub fn body(sql: impl Into<String>) -> Self {
        Self {
            sql: sql.into(),
            body: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DumpObject {
    pub kind: DumpObjectKind,
    pub section: DumpSection,
    pub schema: Option<String>,
    pub name: String,
    pub statements: Vec<DumpStatement>,
    /// The table a CREATE TABLE makes, so it follows the order the rows
    /// load in.
    pub table: Option<TableRef>,
}

impl DumpObject {
    pub fn new(
        kind: DumpObjectKind,
        section: DumpSection,
        schema: Option<String>,
        name: impl Into<String>,
        statements: Vec<DumpStatement>,
    ) -> Self {
        Self {
            kind,
            section,
            schema,
            name: name.into(),
            statements,
            table: None,
        }
    }

    /// A CREATE TABLE, placed in the table order.
    pub fn table(table: TableRef, statements: Vec<DumpStatement>) -> Self {
        Self {
            kind: DumpObjectKind::Table,
            section: DumpSection::BeforeData,
            schema: table.schema.clone(),
            name: table.name.clone(),
            statements,
            table: Some(table),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DumpTable {
    /// As the connection reads it.
    pub table: TableRef,
    /// The tables it must come after: those its foreign keys point at
    /// where the engine checks them as rows load, and a partition's
    /// parent.
    pub references: Vec<TableRef>,
    /// Whether its rows are read. A partitioned table's rows are its
    /// partitions'.
    pub rows: bool,
    /// A row can point at a row of its own table and the engine checks
    /// that as each statement ends, so each row goes in a statement of
    /// its own.
    pub one_row_per_insert: bool,
}

impl DumpTable {
    pub fn new(table: TableRef) -> Self {
        Self {
            table,
            references: Vec::new(),
            rows: true,
            one_row_per_insert: false,
        }
    }
}

/// An object the dump leaves out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DumpSkip {
    pub kind: DumpObjectKind,
    pub schema: Option<String>,
    pub name: String,
    pub reason: DumpSkipReason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum DumpSkipReason {
    /// The server gave no text for it, as for an object the login may
    /// not read.
    NoDefinition,
    /// Its code is encrypted on the server.
    Encrypted,
    /// Its code is a .NET assembly, not SQL.
    ClrRoutine,
    /// Its text holds a line a client reads as the end of a batch, such
    /// as a SQL Server line that is only `GO`, so no file can carry it
    /// whole.
    SplitsApart,
    /// Its text hides a secret the server will not show, such as a
    /// password.
    HiddenSecret,
    /// The dump writes no object of its kind, such as a foreign table or
    /// an aggregate.
    NotSupported,
    /// Its definition is in the file but not the rows it stores, such as
    /// a materialized view that refills only from rows inserted later.
    RowsNotCarried,
    /// Its rows live on another server, which a load would write to.
    RemoteRows,
}

/// What a dump of one scope writes, read from the catalog in one go.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DumpCatalog {
    pub objects: Vec<DumpObject>,
    pub tables: Vec<DumpTable>,
    pub skipped: Vec<DumpSkip>,
}
