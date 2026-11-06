/// A database, or a Cassandra keyspace, to create. Each option is left
/// out of the statement while it is `None`, so the server's default
/// holds.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DatabaseDraft {
    pub name: String,
    pub owner: Option<String>,
    pub template: Option<String>,
    pub encoding: Option<String>,
    /// The collation and character classification together, as
    /// PostgreSQL's LOCALE sets both.
    pub locale: Option<String>,
    pub character_set: Option<String>,
    pub collation: Option<String>,
    pub cluster: Option<String>,
    pub replication: Option<KeyspaceReplication>,
    pub durable_writes: bool,
    /// ScyllaDB's tablets: `None` leaves the server's default.
    pub tablets: Option<bool>,
    /// The collection MongoDB creates the database with.
    pub first_collection: Option<String>,
}

impl DatabaseDraft {
    pub fn named(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            owner: None,
            template: None,
            encoding: None,
            locale: None,
            character_set: None,
            collation: None,
            cluster: None,
            replication: None,
            durable_writes: true,
            tablets: None,
            first_collection: None,
        }
    }
}

/// How a keyspace places its replicas.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum KeyspaceReplication {
    /// One factor for the whole cluster.
    Simple { factor: u32 },
    /// A factor per data centre, by name.
    NetworkTopology { factors: Vec<(String, u32)> },
}

/// How a database is dropped.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct DropDatabaseOptions {
    /// Close the other sessions on it first. Only an engine with
    /// `drop_database_force` takes it.
    pub force: bool,
    pub cluster: Option<String>,
}

/// An option of a schema or database the statement could not carry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CatalogOption {
    Name,
    Owner,
    Template,
    Encoding,
    Locale,
    CharacterSet,
    Collation,
    Cluster,
    DataCenter,
    ReplicationFactor,
    Collection,
}

impl std::fmt::Display for CatalogOption {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Name => "name",
            Self::Owner => "owner",
            Self::Template => "template",
            Self::Encoding => "encoding",
            Self::Locale => "locale",
            Self::CharacterSet => "character set",
            Self::Collation => "collation",
            Self::Cluster => "cluster",
            Self::DataCenter => "data centre",
            Self::ReplicationFactor => "replication factor",
            Self::Collection => "collection",
        })
    }
}
