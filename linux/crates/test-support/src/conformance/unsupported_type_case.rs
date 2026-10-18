/// A column of a type the driver has no decoder for, and a value of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnsupportedTypeCase {
    /// Statements run first, such as creating the enum or composite the
    /// column uses.
    pub setup_sql: Vec<String>,
    /// The column clause `ALTER TABLE ... ADD` takes, naming the column
    /// `v`. It is the whole clause because engines disagree on whether
    /// `COLUMN` is required (ClickHouse) or refused (SQL Server).
    pub declaration: String,
    /// A non-null value of the type, as SQL.
    pub insert_value_sql: String,
}
