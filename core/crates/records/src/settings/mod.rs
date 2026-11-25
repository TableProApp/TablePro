// Each platform's settings registry (0044, Settings; 0054, Crates): the categories a settings kind holds, each
// category's options with their classes, and the categories that go whole. Options cross platforms only once two
// platforms share them, through a registry that starts empty.

use crate::kind::Kind;
use crate::record_id::{COLUMN_LAYOUT_PREFIX, THEME_PREFIX, column_layout_connection, theme_category};
use crate::schema::Field;

mod macos;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Registry {
    pub kind: Kind,
    pub categories: &'static [Category],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Category {
    pub id: CategoryId,
    pub merge: Merge,
    pub document: Document,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CategoryId {
    Named(&'static str),
    // `theme.<theme id>` or `columnLayout.<table key>` (0052, Ids per kind).
    Theme,
    ColumnLayout,
}

// How a category's two edits meet (0044, Conflict rules, Settings).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Merge {
    // Option by option, lists of objects by `id`.
    ByOption,
    // A shortcut has to stay unique, the active AI provider has to be one of the providers and a theme is one
    // design, so these go whole.
    Whole,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Document {
    Object(&'static [Field]),
    // A list of objects with an `id`, merged by it.
    List(&'static [Field]),
}

impl Document {
    pub const fn options(self) -> &'static [Field] {
        match self {
            Self::Object(fields) | Self::List(fields) => fields,
        }
    }
}

impl CategoryId {
    pub fn matches(self, category: &str) -> bool {
        match self {
            Self::Named(name) => name == category,
            Self::Theme => category.strip_prefix(THEME_PREFIX).and_then(theme_category).is_some(),
            Self::ColumnLayout => column_layout_connection(category).is_some(),
        }
    }
}

impl Registry {
    pub fn category(&self, category: &str) -> Option<&'static Category> {
        self.categories.iter().find(|known| known.id.matches(category))
    }

    pub fn names(&self, category: &str) -> bool {
        self.category(category).is_some()
    }
}

// The registry of a settings kind. iOS, Linux and Windows sync no settings yet, so theirs name no category.
pub fn registry(kind: Kind) -> Option<Registry> {
    let categories: &'static [Category] = match kind {
        Kind::MacosSettings => macos::CATEGORIES,
        Kind::IosSettings | Kind::LinuxSettings | Kind::WindowsSettings => &[],
        _ => return None,
    };
    Some(Registry { kind, categories })
}

// The connection a category is about, so a connection that does not sync holds its records back.
pub fn owner(category: &str) -> Option<uuid::Uuid> {
    category
        .starts_with(COLUMN_LAYOUT_PREFIX)
        .then(|| column_layout_connection(category))
        .flatten()
}

#[cfg(test)]
mod tests;
