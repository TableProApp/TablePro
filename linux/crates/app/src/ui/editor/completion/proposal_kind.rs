use tablepro_core::TableRef;
use tablepro_core::meta::ObjectKind;

/// What a proposal names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProposalKind {
    Keyword,
    Schema,
    Table,
    View,
    MaterializedView,
    Column { data_type: String, table: TableRef },
    Function,
}

impl ProposalKind {
    /// The proposal for a catalog object, or `None` for one no
    /// statement names by itself, such as a sequence, or a kind added
    /// after this list.
    pub fn for_object(kind: ObjectKind) -> Option<Self> {
        match kind {
            ObjectKind::Table | ObjectKind::PartitionedTable | ObjectKind::ForeignTable | ObjectKind::Dictionary => {
                Some(Self::Table)
            }
            ObjectKind::View => Some(Self::View),
            ObjectKind::MaterializedView => Some(Self::MaterializedView),
            ObjectKind::Function | ObjectKind::Procedure => Some(Self::Function),
            _ => None,
        }
    }

    /// A column shows its type instead of an icon, and a keyword is
    /// plain text.
    pub fn icon_name(&self) -> Option<&'static str> {
        match self {
            Self::Schema => Some(crate::ui::icons::FOLDER),
            Self::Table => Some(crate::ui::icons::VIEW_LIST),
            Self::View | Self::MaterializedView => Some(crate::ui::icons::VIEW_REVEAL),
            Self::Function => Some(crate::ui::icons::SYSTEM_RUN),
            Self::Keyword | Self::Column { .. } => None,
        }
    }

    /// The order of two proposals that match equally well: what the
    /// statement already names comes before what it might.
    pub fn rank(&self) -> u8 {
        match self {
            Self::Column { .. } => 0,
            Self::Table | Self::View | Self::MaterializedView => 1,
            Self::Schema => 2,
            Self::Function => 3,
            Self::Keyword => 4,
        }
    }

    pub fn is_keyword(&self) -> bool {
        matches!(self, Self::Keyword)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sequence_is_not_proposed() {
        assert_eq!(ProposalKind::for_object(ObjectKind::Sequence), None);
        assert_eq!(
            ProposalKind::for_object(ObjectKind::PartitionedTable),
            Some(ProposalKind::Table)
        );
        assert_eq!(
            ProposalKind::for_object(ObjectKind::Procedure),
            Some(ProposalKind::Function)
        );
    }

    #[test]
    fn columns_come_before_tables_and_keywords_last() {
        let column = ProposalKind::Column {
            data_type: "integer".to_owned(),
            table: TableRef::unqualified("users"),
        };

        assert!(column.rank() < ProposalKind::Table.rank());
        assert!(ProposalKind::Table.rank() < ProposalKind::Keyword.rank());
    }
}
