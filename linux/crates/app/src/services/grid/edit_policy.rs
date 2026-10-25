use crate::i18n::{gettext, gettext_f, ngettext_f};

/// Why the grid refuses a change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditRefusal {
    ReadOnly,
    /// Saved rows are named by their primary key, so without one no
    /// change can be saved (inventory D1).
    NoPrimaryKey,
    /// The table's columns have not been read yet.
    NoColumns,
}

impl EditRefusal {
    /// `None` where the state explains itself.
    pub fn message(self) -> Option<String> {
        match self {
            Self::ReadOnly => Some(gettext("This connection is read-only.")),
            Self::NoPrimaryKey => Some(gettext("This table has no primary key, so editing is turned off.")),
            Self::NoColumns => None,
        }
    }
}

/// What the grid may change. Every entry point (menu, key, toolbar)
/// reads the same answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EditPolicy {
    pub cells: Result<(), EditRefusal>,
    pub insert: Result<(), EditRefusal>,
    pub duplicate: Result<(), EditRefusal>,
    pub delete: Result<(), EditRefusal>,
    pub paste: Result<(), EditRefusal>,
}

pub fn edit_policy(read_only: bool, has_primary_key: bool, has_columns: bool) -> EditPolicy {
    let verdict = match (read_only, has_columns, has_primary_key) {
        (true, _, _) => Err(EditRefusal::ReadOnly),
        (false, false, _) => Err(EditRefusal::NoColumns),
        (false, true, false) => Err(EditRefusal::NoPrimaryKey),
        (false, true, true) => Ok(()),
    };
    EditPolicy {
        cells: verdict,
        insert: verdict,
        duplicate: verdict,
        delete: verdict,
        paste: verdict,
    }
}

/// The count shown once several rows are selected. It names the Delete
/// key only where Delete would act (inventory D12).
pub fn selection_hint(selected: u32, delete: Result<(), EditRefusal>) -> Option<String> {
    if selected <= 1 {
        return None;
    }
    let count = selected.to_string();
    Some(match delete {
        Ok(()) => gettext_f("{n} selected · press Delete to remove", &[("n", &count)]),
        Err(_) => ngettext_f("{n} selected", "{n} selected", selected, &[("n", &count)]),
    })
}

#[cfg(test)]
mod tests {
    use super::{EditPolicy, EditRefusal, edit_policy, selection_hint};

    fn all(verdict: Result<(), EditRefusal>) -> EditPolicy {
        EditPolicy {
            cells: verdict,
            insert: verdict,
            duplicate: verdict,
            delete: verdict,
            paste: verdict,
        }
    }

    #[test]
    fn a_keyed_writable_table_takes_every_change() {
        assert_eq!(edit_policy(false, true, true), all(Ok(())));
    }

    #[test]
    fn a_read_only_connection_refuses_everything_first() {
        for (has_primary_key, has_columns) in [(true, true), (false, true), (true, false), (false, false)] {
            assert_eq!(
                edit_policy(true, has_primary_key, has_columns),
                all(Err(EditRefusal::ReadOnly)),
                "key {has_primary_key}, columns {has_columns}"
            );
        }
    }

    #[test]
    fn a_table_without_a_primary_key_refuses_insert_and_duplicate_too() {
        let policy = edit_policy(false, false, true);

        assert_eq!(policy, all(Err(EditRefusal::NoPrimaryKey)));
        assert_eq!(policy.insert, Err(EditRefusal::NoPrimaryKey), "D1: the menu inserted");
        assert_eq!(policy.duplicate, Err(EditRefusal::NoPrimaryKey));
    }

    #[test]
    fn a_table_whose_columns_are_unread_refuses_quietly() {
        assert_eq!(edit_policy(false, true, false), all(Err(EditRefusal::NoColumns)));
        assert_eq!(edit_policy(false, false, false), all(Err(EditRefusal::NoColumns)));
        assert_eq!(EditRefusal::NoColumns.message(), None);
    }

    #[test]
    fn each_refusal_says_today_s_sentence() {
        assert_eq!(
            EditRefusal::ReadOnly.message().as_deref(),
            Some("This connection is read-only.")
        );
        assert_eq!(
            EditRefusal::NoPrimaryKey.message().as_deref(),
            Some("This table has no primary key, so editing is turned off.")
        );
    }

    #[test]
    fn the_selection_hint_names_delete_only_where_it_acts() {
        assert_eq!(selection_hint(0, Ok(())), None);
        assert_eq!(selection_hint(1, Ok(())), None);
        assert_eq!(
            selection_hint(3, Ok(())).as_deref(),
            Some("3 selected · press Delete to remove")
        );
        assert_eq!(
            selection_hint(3, Err(EditRefusal::NoPrimaryKey)).as_deref(),
            Some("3 selected"),
            "D12: the hint offered a Delete that was off"
        );
    }
}
