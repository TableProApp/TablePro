use super::{ColumnDefinition, DraftType};
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
        }
    }

    pub fn from_definition(definition: ColumnDefinition) -> Self {
        let info = &definition.info;
        Self {
            name: info.name.clone(),
            column_type: DraftType::Catalog(info.column_type.clone()),
            nullable: info.nullable,
            primary_key: info.primary_key,
            auto_increment: info.is_auto_increment,
            default: info.default.clone(),
            comment: info.comment.clone(),
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
}
