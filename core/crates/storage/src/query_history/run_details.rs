// What the app knew of a run beyond its outcome: the History pane's columns and the `history_entry` wire schema's
// (tablepro-records). None where the app did not say, as for every entry an older build recorded.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RunDetails {
    pub database: Option<String>,
    pub schema: Option<String>,
    pub source: Option<RunSource>,
    pub statement_type: Option<StatementType>,
    pub first_row_us: Option<i64>,
    pub server_us: Option<i64>,
    // The statement's shape as the app's grammar reads it, so runs that differ only in their values group together.
    // It never leaves the device: another device reads the shape with its own grammar.
    pub fingerprint: Option<i64>,
}

// What started a run. The names are the wire's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RunSource {
    Editor,
    Explain,
    TableBrowse,
    RowEdit,
    StructureDdl,
    Import,
    Mcp,
    Script,
    Shortcuts,
    CommandLine,
}

impl RunSource {
    pub const ALL: [Self; 10] = [
        Self::Editor,
        Self::Explain,
        Self::TableBrowse,
        Self::RowEdit,
        Self::StructureDdl,
        Self::Import,
        Self::Mcp,
        Self::Script,
        Self::Shortcuts,
        Self::CommandLine,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Editor => "editor",
            Self::Explain => "explain",
            Self::TableBrowse => "table_browse",
            Self::RowEdit => "row_edit",
            Self::StructureDdl => "structure_ddl",
            Self::Import => "import",
            Self::Mcp => "mcp",
            Self::Script => "script",
            Self::Shortcuts => "shortcuts",
            Self::CommandLine => "command_line",
        }
    }

    // None for a name a newer build wrote.
    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|source| source.as_str() == name)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StatementType {
    Select,
    Insert,
    Update,
    Delete,
    Ddl,
    Other,
}

impl StatementType {
    pub const ALL: [Self; 6] = [
        Self::Select,
        Self::Insert,
        Self::Update,
        Self::Delete,
        Self::Ddl,
        Self::Other,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Select => "select",
            Self::Insert => "insert",
            Self::Update => "update",
            Self::Delete => "delete",
            Self::Ddl => "ddl",
            Self::Other => "other",
        }
    }

    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.as_str() == name)
    }
}
