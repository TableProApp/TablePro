use super::{ColumnDefinition, DraftColumn, DraftType};

/// What an edit changed about a column it kept. The name is not here:
/// a rename is its own change, so a rename alone alters nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct ChangedAttributes {
    pub column_type: bool,
    pub nullability: bool,
    pub default: bool,
    pub primary_key: bool,
    pub auto_increment: bool,
    pub comment: bool,
}

impl ChangedAttributes {
    pub fn between(original: &ColumnDefinition, draft: &DraftColumn) -> Self {
        let info = &original.info;
        let column_type = match &draft.column_type {
            DraftType::Catalog(column_type) => *column_type != info.column_type,
            // Typed text equal to the declaration is the same type: the
            // user retyped what was there.
            DraftType::Typed(text) => {
                info.column_type
                    .catalog
                    .as_ref()
                    .map(|catalog| catalog.declaration.as_sql())
                    != Some(text.trim())
            }
        };
        let comment = info.comment.as_deref().filter(|text| !text.is_empty()) != draft.comment_text();
        Self {
            column_type,
            nullability: info.nullable != draft.nullable,
            default: info.default != draft.default,
            primary_key: info.primary_key != draft.primary_key,
            auto_increment: info.is_auto_increment != draft.auto_increment,
            comment,
        }
    }

    pub fn any(&self) -> bool {
        self.column_type || self.nullability || self.default || self.primary_key || self.auto_increment || self.comment
    }
}
