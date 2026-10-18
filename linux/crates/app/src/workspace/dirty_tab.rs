use uuid::Uuid;

use super::DirtyKind;

/// A tab closing would lose something in, named the way its tab is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirtyTab {
    pub id: Uuid,
    pub title: String,
    pub kind: DirtyKind,
}

impl DirtyTab {
    /// The tabs' names for a sentence, each quoted.
    pub fn names(tabs: &[DirtyTab]) -> String {
        let quoted: Vec<String> = tabs.iter().map(|tab| Self::quote(&tab.title)).collect();
        quoted.join(", ")
    }

    pub fn quote(title: &str) -> String {
        crate::i18n::gettext_f("“{name}”", &[("name", title)])
    }
}
