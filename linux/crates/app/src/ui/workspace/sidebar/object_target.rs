use tablepro_core::meta::{ObjectInfo, TableRef};

/// What a sidebar row stands for, and so what opening it does. Every row
/// action matches on it, so none can take a routine for the table that
/// shares its name.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum ObjectTarget {
    /// A table, a view or a key, whose rows open in a tab.
    Rows(TableRef),
    /// A routine, a sequence or a trigger, whose SQL opens read-only.
    Definition(ObjectInfo),
}

impl ObjectTarget {
    pub(crate) fn of(object: &ObjectInfo) -> Self {
        if object.kind.has_definition() {
            Self::Definition(object.clone())
        } else {
            Self::Rows(TableRef::new(object.schema.clone(), object.name.clone()))
        }
    }

    pub(crate) fn into_rows(self) -> Option<TableRef> {
        match self {
            Self::Rows(table) => Some(table),
            Self::Definition(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::ObjectKind;

    use super::*;

    #[test]
    fn a_routine_is_never_a_table_of_its_name() {
        let routine = ObjectInfo::new(Some("public".to_owned()), "users", ObjectKind::Function);
        let table = ObjectInfo::new(Some("public".to_owned()), "users", ObjectKind::Table);

        assert_eq!(ObjectTarget::of(&routine), ObjectTarget::Definition(routine.clone()));
        assert_eq!(
            ObjectTarget::of(&table),
            ObjectTarget::Rows(TableRef::new(Some("public".to_owned()), "users"))
        );
        assert_eq!(ObjectTarget::of(&routine).into_rows(), None);
    }
}
