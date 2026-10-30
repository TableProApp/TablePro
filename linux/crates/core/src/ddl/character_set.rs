/// A character set the server offers, with the collations it takes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CharacterSet {
    pub name: String,
    /// The collation a column or table takes when it names only the
    /// character set. Always one of `collations`.
    pub default_collation: String,
    pub collations: Vec<String>,
}
