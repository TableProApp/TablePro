use tablepro_core::ColumnInfo;
use tablepro_core::browse::PageLayout;
use tablepro_core::column::ResultColumn;

/// Checks that a page came back with the columns the tab built it from.
/// A table altered between the column read and the page shows up here,
/// and the columns are read again once before the tab gives up on it.
#[derive(Debug, Default)]
pub(crate) struct ColumnRecheck {
    attempted: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RecheckAction {
    Accept,
    /// Read the columns again, then the page.
    Refetch,
    /// The columns moved again after they were read again:
    /// `LoadFailure::ColumnsChanged`.
    Fail,
}

impl ColumnRecheck {
    pub(crate) fn check(
        &mut self,
        columns: &[ColumnInfo],
        result_columns: &[ResultColumn],
        layout: &PageLayout,
    ) -> RecheckAction {
        let width = layout.visible.len() + layout.identity.len();
        let visible_names = result_columns
            .get(layout.visible.clone())
            .unwrap_or_default()
            .iter()
            .map(|column| column.name.as_str());
        let matches = result_columns.len() == width
            && layout.visible.len() == columns.len()
            && visible_names.eq(columns.iter().map(|column| column.name.as_str()));
        if matches {
            self.attempted = false;
            return RecheckAction::Accept;
        }
        // A failure spends the refetch, so the next mismatch, after Try
        // Again or a page turn, gets one of its own.
        match std::mem::replace(&mut self.attempted, true) {
            false => RecheckAction::Refetch,
            true => {
                self.attempted = false;
                RecheckAction::Fail
            }
        }
    }

    /// A read of the columns other than the recheck's own, or the end of
    /// the recheck's own in a failure.
    pub(crate) fn reset(&mut self) {
        self.attempted = false;
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnType};

    use super::*;

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::untyped_text("text"),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn result(names: &[&str]) -> Vec<ResultColumn> {
        names.iter().map(|name| column(name).result_column()).collect()
    }

    fn layout(visible: usize, identity: usize) -> PageLayout {
        PageLayout {
            visible: 0..visible,
            identity: visible..visible + identity,
        }
    }

    #[test]
    fn column_recheck_accepts_matching_visible_names_with_identity_tail() {
        let mut recheck = ColumnRecheck::default();
        let columns = [column("id"), column("name")];

        let action = recheck.check(
            &columns,
            &result(&["id", "name", "__tablepro_row_oid", "__tablepro_row_id"]),
            &layout(2, 2),
        );

        assert_eq!(action, RecheckAction::Accept);
    }

    #[test]
    fn column_recheck_refetches_once_then_fails() {
        let mut recheck = ColumnRecheck::default();
        let columns = [column("id"), column("name")];
        let renamed = result(&["id", "full_name"]);

        assert_eq!(recheck.check(&columns, &renamed, &layout(2, 0)), RecheckAction::Refetch);
        assert_eq!(recheck.check(&columns, &renamed, &layout(2, 0)), RecheckAction::Fail);
        assert_eq!(
            recheck.check(&columns, &result(&["id", "name"]), &layout(2, 0)),
            RecheckAction::Accept
        );
        assert_eq!(
            recheck.check(&columns, &renamed, &layout(2, 0)),
            RecheckAction::Refetch,
            "a page that matched did not reset the guard"
        );
    }

    #[test]
    fn a_failed_recheck_leaves_the_next_mismatch_its_refetch() {
        let mut recheck = ColumnRecheck::default();
        let columns = [column("id"), column("name")];
        let renamed = result(&["id", "full_name"]);

        assert_eq!(recheck.check(&columns, &renamed, &layout(2, 0)), RecheckAction::Refetch);
        assert_eq!(recheck.check(&columns, &renamed, &layout(2, 0)), RecheckAction::Fail);
        assert_eq!(recheck.check(&columns, &renamed, &layout(2, 0)), RecheckAction::Refetch);
    }

    #[test]
    fn a_reset_leaves_the_next_mismatch_its_refetch() {
        let mut recheck = ColumnRecheck::default();
        let columns = [column("id"), column("name")];
        let renamed = result(&["id", "full_name"]);

        assert_eq!(recheck.check(&columns, &renamed, &layout(2, 0)), RecheckAction::Refetch);
        recheck.reset();

        assert_eq!(recheck.check(&columns, &renamed, &layout(2, 0)), RecheckAction::Refetch);
    }

    #[test]
    fn column_recheck_rejects_wrong_identity_width() {
        let mut recheck = ColumnRecheck::default();
        let columns = [column("id"), column("name")];

        let action = recheck.check(&columns, &result(&["id", "name", "__tablepro_row_id"]), &layout(2, 2));

        assert_eq!(action, RecheckAction::Refetch);
    }

    #[test]
    fn column_recheck_rejects_a_column_the_tab_does_not_have() {
        let mut recheck = ColumnRecheck::default();

        let action = recheck.check(&[column("id")], &result(&["id", "name"]), &layout(2, 0));

        assert_eq!(action, RecheckAction::Refetch);
    }
}
