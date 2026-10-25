use super::{StatementOutcomeKind, result_tab_icon};

#[test]
fn a_statement_that_was_not_run_uses_a_stopped_result_tab_icon() {
    assert_eq!(
        result_tab_icon(&StatementOutcomeKind::NotRun),
        "media-playback-stop-symbolic"
    );
}
