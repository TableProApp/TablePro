use super::{ColumnAttributes, ColumnDefinition, DraftType};
use crate::column::ColumnDefault;

/// A column as the user is editing it.
#[derive(Debug, Clone, PartialEq)]
pub struct DraftColumn {
    /// The column this draft started from, `None` for one the user added.
    pub original: Option<ColumnDefinition>,
    pub name: String,
    pub column_type: DraftType,
    pub nullable: bool,
    pub primary_key: bool,
    pub auto_increment: bool,
    pub default: ColumnDefault,
    pub comment: Option<String>,
    /// The column's own character set and collation, which only an engine
    /// with `column_collations` lets the user change. `None` takes the
    /// table's default.
    pub character_set: Option<String>,
    pub collation: Option<String>,
}

impl DraftColumn {
    pub fn new(name: impl Into<String>, column_type: DraftType) -> Self {
        Self {
            original: None,
            name: name.into(),
            column_type,
            nullable: true,
            primary_key: false,
            auto_increment: false,
            default: ColumnDefault::None,
            comment: None,
            character_set: None,
            collation: None,
        }
    }

    pub fn from_definition(definition: ColumnDefinition) -> Self {
        let info = &definition.info;
        let attributes = &definition.attributes;
        Self {
            name: info.name.clone(),
            column_type: DraftType::Catalog(info.column_type.clone()),
            nullable: info.nullable,
            primary_key: info.primary_key,
            auto_increment: info.is_auto_increment,
            default: info.default.clone(),
            comment: info.comment.clone(),
            character_set: attributes.character_set.clone(),
            collation: attributes.collation.as_ref().map(|collation| collation.name.clone()),
            original: Some(definition),
        }
    }

    pub fn original_name(&self) -> Option<&str> {
        self.original.as_ref().map(ColumnDefinition::name)
    }

    /// An empty entry is the user saying "no comment", not a comment that
    /// happens to be empty.
    pub fn comment_text(&self) -> Option<&str> {
        self.comment.as_deref().filter(|text| !text.is_empty())
    }

    /// Whether the user named a character set or collation other than the
    /// column's own. A column the user added has neither of its own.
    pub fn collation_edited(&self) -> bool {
        self.collation_differs(self.original.as_ref().map(|original| &original.attributes))
    }

    pub(super) fn collation_differs(&self, attributes: Option<&ColumnAttributes>) -> bool {
        let character_set = attributes.and_then(|attributes| attributes.character_set.as_deref());
        let collation = attributes
            .and_then(|attributes| attributes.collation.as_ref())
            .map(|collation| collation.name.as_str());
        character_set != self.character_set.as_deref() || collation != self.collation.as_deref()
    }
}
