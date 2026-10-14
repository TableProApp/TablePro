use super::GridRowId;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeleteAvailability {
    Available,
    Unavailable(DeleteBlock),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeleteBlock {
    NoRows,
    /// A DELETE names a row by its key, and these rows have none.
    UnkeyedRows,
    ReadOnlySession,
}

impl DeleteBlock {
    /// Why Delete is off, for its button's tooltip. `None` when nothing
    /// needs saying: there is just nothing selected.
    pub fn explanation(self) -> Option<String> {
        match self {
            Self::NoRows => None,
            Self::UnkeyedRows => Some(crate::i18n::gettext(
                "Rows without a primary key or unique key can't be deleted here",
            )),
            Self::ReadOnlySession => Some(crate::i18n::gettext("This connection is read-only")),
        }
    }
}

/// Whether Delete can act on `rows`. A draft needs no key: deleting it
/// only drops it.
pub fn delete_availability<'a>(rows: impl IntoIterator<Item = &'a GridRowId>, read_only: bool) -> DeleteAvailability {
    if read_only {
        return DeleteAvailability::Unavailable(DeleteBlock::ReadOnlySession);
    }
    let mut any = false;
    for row in rows {
        match row {
            GridRowId::Persisted(_) | GridRowId::Draft(_) => any = true,
            GridRowId::Unkeyed | GridRowId::Result => {
                return DeleteAvailability::Unavailable(DeleteBlock::UnkeyedRows);
            }
        }
    }
    match any {
        true => DeleteAvailability::Available,
        false => DeleteAvailability::Unavailable(DeleteBlock::NoRows),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;

    use super::{DeleteAvailability, DeleteBlock, delete_availability};
    use crate::services::change_tracker::RowKey;
    use crate::ui::grid::GridRowId;

    #[test]
    fn delete_availability_blocks_unkeyed_result_and_read_only() {
        let saved = GridRowId::Persisted(RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"));
        let draft = GridRowId::Draft(2);
        let blocked = |block| DeleteAvailability::Unavailable(block);

        assert_eq!(
            delete_availability(&[saved.clone(), draft.clone()], false),
            DeleteAvailability::Available
        );
        assert_eq!(
            delete_availability(std::slice::from_ref(&draft), false),
            DeleteAvailability::Available,
            "a draft needs no key to be dropped"
        );
        assert_eq!(delete_availability(&[], false), blocked(DeleteBlock::NoRows));
        assert_eq!(
            delete_availability(&[saved.clone(), GridRowId::Unkeyed], false),
            blocked(DeleteBlock::UnkeyedRows)
        );
        assert_eq!(
            delete_availability(&[GridRowId::Result], false),
            blocked(DeleteBlock::UnkeyedRows)
        );
        assert_eq!(
            delete_availability(&[saved], true),
            blocked(DeleteBlock::ReadOnlySession)
        );
        assert_eq!(DeleteBlock::NoRows.explanation(), None);
        assert!(DeleteBlock::UnkeyedRows.explanation().is_some());
        assert!(DeleteBlock::ReadOnlySession.explanation().is_some());
    }
}
