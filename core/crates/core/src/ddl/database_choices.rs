use super::CharacterSet;

/// What the server offers for the options of a new database, read when
/// the New Database dialog opens. A list an engine has no use for stays
/// empty.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DatabaseChoices {
    /// Roles that can own a database or schema.
    pub owners: Vec<String>,
    /// Databases a new one can be copied from.
    pub templates: Vec<String>,
    pub encodings: Vec<String>,
    pub locales: Vec<String>,
    pub character_sets: Vec<CharacterSet>,
    pub collations: Vec<String>,
    /// Clusters with more than one server, which ON CLUSTER can name. A
    /// single server lists none.
    pub clusters: Vec<String>,
    /// Data centres, for a keyspace's replication.
    pub data_centers: Vec<String>,
    /// What the server uses when the option is left out, where it says.
    pub defaults: DatabaseDefaults,
}

/// The server's own choice for an option left out.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DatabaseDefaults {
    pub owner: Option<String>,
    pub encoding: Option<String>,
    pub locale: Option<String>,
    pub character_set: Option<String>,
    pub collation: Option<String>,
}
