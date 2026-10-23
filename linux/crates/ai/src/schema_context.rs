/// What a prompt says about the connection: its engine, where the user
/// is, the tables there and the structure of the ones in play. Read from
/// the catalog only: no row is ever part of it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SchemaContext {
    /// The engine as the user knows it, such as `PostgreSQL`.
    pub engine: String,
    pub language: QueryLanguage,
    pub database: Option<String>,
    pub schema: Option<String>,
    /// Table and view names of the schema the user is in.
    pub tables: Vec<String>,
    pub described: Vec<TableShape>,
}

/// What the engine takes: SQL, or commands one per line, as Redis does.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum QueryLanguage {
    #[default]
    Sql,
    Commands,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableShape {
    pub name: String,
    pub columns: Vec<ColumnShape>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColumnShape {
    pub name: String,
    pub type_name: String,
    pub nullable: bool,
    pub primary_key: bool,
}

impl SchemaContext {
    /// The names of the tables whose structure goes with the request.
    pub fn described_names(&self) -> Vec<&str> {
        self.described.iter().map(|table| table.name.as_str()).collect()
    }
}
