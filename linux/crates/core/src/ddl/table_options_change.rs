/// What a save changes about a table's options.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TableOptionsChange {
    /// The new default character set and collation. Set for a convert
    /// too, even one to the pair the table already has.
    pub character_set: Option<CharacterSetChoice>,
    /// Rewrite every text column in `character_set`, which is then set.
    pub converts_columns: bool,
    pub next_auto_increment: Option<u64>,
}

/// A character set and one of its collations, always written together:
/// a character set named alone resets the collation to its default.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CharacterSetChoice {
    pub character_set: String,
    pub collation: String,
}
