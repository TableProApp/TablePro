//! How the Structure tab names a foreign key's actions.

use tablepro_core::ddl::ReferentialAction;

/// The On Delete and On Update choices: the database's own default, then
/// each action the engine takes, in its order.
pub(super) fn action_labels(actions: &[ReferentialAction]) -> Vec<String> {
    std::iter::once(crate::i18n::gettext("Database Default"))
        .chain(actions.iter().map(|action| action.as_sql().to_owned()))
        .collect()
}

/// The action a choice stands for. The first choice leaves it to the
/// database; one past the end can only be a stale selection.
pub(super) fn action_at(actions: &[ReferentialAction], position: u32) -> Option<ReferentialAction> {
    let index = usize::try_from(position.checked_sub(1)?).ok()?;
    actions.get(index).copied()
}

/// A key the user drafted left an unset action to the database. One
/// read from the database with no action is one the driver could not
/// name, so the row says so rather than claim the default.
pub(super) fn action_text(action: Option<ReferentialAction>, drafted: bool) -> String {
    match (action, drafted) {
        (Some(action), _) => action.as_sql().to_owned(),
        (None, true) => crate::i18n::gettext("database default"),
        (None, false) => crate::i18n::gettext("not reported"),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ddl::DdlDialect;

    use super::*;

    #[test]
    fn each_choice_decodes_to_the_action_it_is_labelled_with() {
        let mssql = drivers_mssql::MssqlDialect::new(16);
        let actions = mssql.referential_actions();

        let labels = action_labels(actions);

        assert_eq!(labels[0], "Database Default");
        assert_eq!(action_at(actions, 0), None);
        assert!(!labels.iter().any(|label| label == "RESTRICT"), "{labels:?}");
        for (position, label) in labels.iter().enumerate().skip(1) {
            let position = u32::try_from(position).expect("a short list");
            assert_eq!(
                action_at(actions, position).map(ReferentialAction::as_sql),
                Some(label.as_str())
            );
        }
        let past_the_end = u32::try_from(labels.len()).expect("a short list");
        assert_eq!(action_at(actions, past_the_end), None);
    }

    #[test]
    fn an_unset_action_reads_by_where_the_key_came_from() {
        assert_eq!(action_text(Some(ReferentialAction::SetNull), false), "SET NULL");
        assert_eq!(action_text(None, true), "database default");
        assert_eq!(action_text(None, false), "not reported");
    }
}
