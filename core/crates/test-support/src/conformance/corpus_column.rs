/// One column of an engine's value corpus: a type, and values of it the
/// way a real table holds them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorpusColumn {
    /// Statements run first, such as creating the enum the column uses.
    pub setup_sql: Vec<String>,
    /// The clause `ALTER TABLE ... ADD` takes, naming the column `v`, as
    /// in `UnsupportedTypeCase`.
    pub declaration: String,
    pub values: Vec<CorpusValue>,
}

/// A value written as SQL, and the text the grid shows for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorpusValue {
    pub sql: String,
    /// `None` for NULL.
    pub shown: Option<String>,
    /// What an editor run shows where it differs from a browse page,
    /// such as a MySQL TIMESTAMP, which browse reads as an instant and
    /// the editor in the server's zone.
    pub edited: Option<String>,
}

impl CorpusColumn {
    pub fn new(declaration: impl Into<String>) -> Self {
        Self {
            setup_sql: Vec::new(),
            declaration: declaration.into(),
            values: Vec::new(),
        }
    }

    pub fn after(mut self, setup_sql: impl Into<String>) -> Self {
        self.setup_sql.push(setup_sql.into());
        self
    }

    pub fn shows(mut self, sql: impl Into<String>, shown: impl Into<String>) -> Self {
        self.values.push(CorpusValue {
            sql: sql.into(),
            shown: Some(shown.into()),
            edited: None,
        });
        self
    }

    pub fn shows_apart(
        mut self,
        sql: impl Into<String>,
        browsed: impl Into<String>,
        edited: impl Into<String>,
    ) -> Self {
        self.values.push(CorpusValue {
            sql: sql.into(),
            shown: Some(browsed.into()),
            edited: Some(edited.into()),
        });
        self
    }

    pub fn null(mut self) -> Self {
        self.values.push(CorpusValue {
            sql: "NULL".to_owned(),
            shown: None,
            edited: None,
        });
        self
    }
}
