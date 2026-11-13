use tablepro_core::Value;
use tablepro_core::masking::{MaskingPolicy, MaskingRule, MaskingStyle, MaskingTarget};
use tablepro_test_support::FakeReply;

use super::super::PagingInput;
use super::{Harness, WAIT, rows, serving_table, text};
use crate::services::grid::{CellLock, GridRowId};
use crate::test_support::wait_until;
use crate::ui::data_grid::GridRequest;

fn rule(pattern: &str, style: MaskingStyle) -> MaskingPolicy {
    MaskingPolicy::new([MaskingRule::new(pattern, MaskingTarget::Column, style)])
}

fn two_rows() -> Harness {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    harness
}

fn bullets() -> Value {
    Value::Text("••••".to_owned())
}

#[gtk4::test]
fn a_saved_rule_masks_the_page_and_a_reveal_reads_it_again_unmasked() {
    let harness = two_rows();

    harness
        .session
        .set_masking_policy(rule("users.name", MaskingStyle::Full));
    harness.tab().masking_changed();
    wait_until(WAIT, || harness.shown() == [bullets(), bullets()]).expect("the page masked");
    assert!(harness.grid().masks().is_masked(1));

    harness.grid().request(GridRequest::RevealMasked);

    wait_until(WAIT, || harness.shown() == text(&["Ada", "Grace"])).expect("the page read unmasked");
    assert!(harness.grid().masks().revealed);
    assert!(
        harness.grid().masks().external.is_masked(1),
        "a revealed page still masks on the way out"
    );
}

#[gtk4::test]
fn a_page_read_under_a_rule_comes_masked_and_a_masked_key_names_no_row() {
    let harness = two_rows();
    harness.session.set_masking_policy(rule("users.id", MaskingStyle::Hash));

    harness.tab().send(PagingInput::Refresh);

    wait_until(WAIT, || harness.grid().masks().masked_key).expect("the page read again under the rule");
    let row = harness.grid_row(0);
    assert_eq!(row.id(), GridRowId::Unkeyed);
    let name = harness.grid().grid_columns()[1].clone();
    assert_eq!(harness.grid().tracked().lock(&name, &row), Some(CellLock::MaskedKey));
    assert_ne!(row.cells().expect("cells")[0], Value::Int(0));
}
