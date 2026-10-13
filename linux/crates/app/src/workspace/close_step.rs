use super::{CloseScope, DirtyKind, DirtyTab};

/// What a close has to settle next, in the order it settles them: a
/// save still running decides what the others are, and an outcome
/// nobody knows comes before anything is saved again.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloseStep {
    WaitForSaves,
    ResolveUnknownOutcome(Vec<DirtyTab>),
    ConfirmOpenTransactions(Vec<DirtyTab>),
    AskSaveChanges(Vec<DirtyTab>),
    Approve,
}

/// The step a close in `scope` takes, given how many of its saves are
/// running and what its tabs would lose.
pub fn next_close_step(scope: CloseScope, saves_in_flight: usize, dirty: &[DirtyTab]) -> CloseStep {
    if saves_in_flight > 0 {
        return CloseStep::WaitForSaves;
    }
    let in_scope: Vec<&DirtyTab> = dirty.iter().filter(|tab| scope.covers(tab.id)).collect();
    let of_kind = |wanted: fn(&DirtyKind) -> bool| -> Vec<DirtyTab> {
        in_scope
            .iter()
            .filter(|tab| wanted(&tab.kind))
            .map(|tab| (*tab).clone())
            .collect()
    };
    let unknown = of_kind(|kind| matches!(kind, DirtyKind::OutcomeUnknown(_)));
    if !unknown.is_empty() {
        return CloseStep::ResolveUnknownOutcome(unknown);
    }
    let transactions = of_kind(|kind| matches!(kind, DirtyKind::OpenTransaction));
    if !transactions.is_empty() {
        return CloseStep::ConfirmOpenTransactions(transactions);
    }
    let unsaved = of_kind(|kind| matches!(kind, DirtyKind::Unsaved));
    if !unsaved.is_empty() {
        return CloseStep::AskSaveChanges(unsaved);
    }
    CloseStep::Approve
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::*;
    use crate::workspace::UnknownCause;

    fn tab(kind: DirtyKind) -> DirtyTab {
        DirtyTab {
            id: Uuid::new_v4(),
            title: "users".to_owned(),
            kind,
        }
    }

    #[test]
    fn next_close_step_table() {
        let unsaved = tab(DirtyKind::Unsaved);
        let unknown = tab(DirtyKind::OutcomeUnknown(UnknownCause::Interrupted));
        let transaction = tab(DirtyKind::OpenTransaction);
        let all = [unsaved.clone(), transaction.clone(), unknown.clone()];
        let window = CloseScope::Window;

        assert_eq!(next_close_step(window, 1, &all), CloseStep::WaitForSaves);
        assert_eq!(next_close_step(window, 1, &[]), CloseStep::WaitForSaves);
        assert_eq!(
            next_close_step(window, 0, &all),
            CloseStep::ResolveUnknownOutcome(vec![unknown.clone()])
        );
        assert_eq!(
            next_close_step(window, 0, &[unsaved.clone(), transaction.clone()]),
            CloseStep::ConfirmOpenTransactions(vec![transaction.clone()])
        );
        assert_eq!(
            next_close_step(window, 0, std::slice::from_ref(&unsaved)),
            CloseStep::AskSaveChanges(vec![unsaved.clone()])
        );
        assert_eq!(next_close_step(window, 0, &[]), CloseStep::Approve);

        assert_eq!(
            next_close_step(CloseScope::Tab(unsaved.id), 0, &all),
            CloseStep::AskSaveChanges(vec![unsaved.clone()]),
            "another tab's unknown outcome held up this tab's close"
        );
        assert_eq!(
            next_close_step(CloseScope::Tab(transaction.id), 0, &all),
            CloseStep::ConfirmOpenTransactions(vec![transaction])
        );
        assert_eq!(
            next_close_step(CloseScope::Tab(Uuid::new_v4()), 0, &all),
            CloseStep::Approve
        );
    }
}
