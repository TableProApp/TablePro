use super::TableOptions;

/// A table's options as the user is editing them.
///
/// The character set and collation change together: a character set
/// named alone takes its default collation, so a draft that changes
/// either names both.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DraftTableOptions {
    pub character_set: Option<String>,
    pub collation: Option<String>,
    /// Rewrite every text column in the character set as well, rather
    /// than change only the default that columns added later take.
    pub converts_columns: bool,
    pub next_auto_increment: Option<u64>,
}

impl DraftTableOptions {
    pub fn from_options(options: &TableOptions) -> Self {
        Self {
            character_set: options.character_set.clone(),
            collation: options.collation.clone(),
            converts_columns: false,
            next_auto_increment: options.next_auto_increment,
        }
    }

    /// Whether the draft asks for anything a new table would be created
    /// with.
    pub fn sets_anything(&self) -> bool {
        self.character_set.is_some() || self.collation.is_some() || self.next_auto_increment.is_some()
    }
}
