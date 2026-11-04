/// What the SQL editor draws with. `System` follows the desktop's
/// monospace font, which is what GNOME's own editors do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditorFont {
    System,
    Custom(String),
}

impl EditorFont {
    pub fn is_system(&self) -> bool {
        matches!(self, Self::System)
    }

    pub fn custom(&self) -> Option<&str> {
        match self {
            Self::System => None,
            Self::Custom(description) => Some(description),
        }
    }
}
