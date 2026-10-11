use serde::{Deserialize, Serialize};

pub const CATALOG_OBJECT_LIMIT: usize = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CatalogObjectKind {
    Routine,
    Trigger,
    Sequence,
    Extension,
    Role,
    Type,
    Grant,
}

impl CatalogObjectKind {
    pub const ALL: [Self; 7] = [
        Self::Routine,
        Self::Trigger,
        Self::Sequence,
        Self::Extension,
        Self::Role,
        Self::Type,
        Self::Grant,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Routine => "routine",
            Self::Trigger => "trigger",
            Self::Sequence => "sequence",
            Self::Extension => "extension",
            Self::Role => "role",
            Self::Type => "type",
            Self::Grant => "grant",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.as_str() == value)
    }

    pub fn is_schema_scoped(self) -> bool {
        !matches!(self, Self::Extension | Self::Role)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogObject {
    pub kind: CatalogObjectKind,
    pub schema: Option<String>,
    pub name: String,
    pub detail: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_kind_parses_from_its_own_name_and_nothing_else_does() {
        for kind in CatalogObjectKind::ALL {
            assert_eq!(CatalogObjectKind::parse(kind.as_str()), Some(kind));
            assert_eq!(serde_json::to_value(kind).unwrap(), kind.as_str());
        }
        assert_eq!(CatalogObjectKind::parse("Routine"), None);
        assert_eq!(CatalogObjectKind::parse("table"), None);
    }
}
