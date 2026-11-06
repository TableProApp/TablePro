/// What an engine does to a whole table, schema or database, beside
/// changing a table's structure, so the sidebar offers only those.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CatalogCapabilities {
    pub truncate_table: bool,
    /// Whether a truncate can empty the tables whose foreign keys point
    /// at the table in the same statement. Where it can, the server
    /// refuses a referenced table without it (PostgreSQL).
    pub truncate_cascade: bool,
    /// Whether a truncate can choose to start the table's numbering
    /// again. MySQL and SQL Server always do; DuckDB and SQLite never.
    pub truncate_restart_identity: bool,
    /// Whether a truncate is refused for a table another table's foreign
    /// key points at, whatever the rows: by the server (MySQL, SQL
    /// Server), or by the plan on SQLite, whose DELETE would run the
    /// other table's ON DELETE action.
    pub truncate_refused_when_referenced: bool,
    pub create_schema: bool,
    pub drop_schema: bool,
    /// Whether a schema can be dropped with everything in it. Where it
    /// cannot, the server refuses a schema that holds anything.
    pub drop_schema_cascade: bool,
    /// Whether a new schema can name its owner.
    pub schema_owner: bool,
    pub create_database: bool,
    pub drop_database: bool,
    /// Whether a drop can first close the other sessions on the database.
    pub drop_database_force: bool,
    /// The options a new database takes beside its name.
    pub database_fields: DatabaseFields,
    pub database_noun: DatabaseNoun,
    /// Whether a statement can run on every server of a cluster
    /// (ClickHouse's ON CLUSTER).
    pub on_cluster: bool,
    /// The longest schema or database name the server keeps whole.
    /// PostgreSQL cuts a longer one short with only a notice, so the
    /// object would not be the one the user named.
    pub name_limit: Option<NameLimit>,
}

/// How long a name can be, in the unit the server counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NameLimit {
    Bytes(usize),
    Chars(usize),
}

impl NameLimit {
    pub fn admits(self, name: &str) -> bool {
        match self {
            Self::Bytes(limit) => name.len() <= limit,
            Self::Chars(limit) => name.chars().count() <= limit,
        }
    }
}

/// The options the New Database dialog shows for an engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DatabaseFields {
    pub owner: bool,
    pub template: bool,
    pub encoding: bool,
    pub locale: bool,
    pub character_set: bool,
    pub collation: bool,
    /// A keyspace's replication, durable writes and, on ScyllaDB,
    /// tablets.
    pub replication: bool,
    /// ScyllaDB's tablets switch.
    pub tablets: bool,
    /// MongoDB keeps a database only once it holds a collection.
    pub first_collection: bool,
}

/// What the engine calls a database.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DatabaseNoun {
    #[default]
    Database,
    Keyspace,
}
