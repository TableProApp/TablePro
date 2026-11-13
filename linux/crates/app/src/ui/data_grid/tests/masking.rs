use gtk4::prelude::*;
use libadwaita::prelude::*;
use tablepro_core::Value;
use tablepro_core::masking::{ColumnMasks, MaskingStyle};

use super::super::test_grid::{Grid, GridSpec, persisted, two_text_columns, two_text_values};
use super::{action_names, data_column};
use crate::services::grid::{CellLock, GridMasks};
use crate::ui::data_grid::GridRequest;
use crate::ui::export::ExportSource;

fn name_masked(revealed: bool) -> GridMasks {
    GridMasks {
        shown: match revealed {
            true => ColumnMasks::none(),
            false => ColumnMasks::new(vec![None, Some(MaskingStyle::Full)]),
        },
        external: ColumnMasks::new(vec![None, Some(MaskingStyle::Email)]),
        revealed,
        masked_key: false,
        untraced: Vec::new(),
    }
}

fn results() -> Grid {
    let rows = two_text_values();
    Grid::build(GridSpec::results(two_text_columns()), persisted(&rows))
}

#[gtk4::test]
fn a_masked_column_says_so_in_its_header_and_its_saved_cells_refuse_edits() {
    let grid = Grid::open(two_text_columns(), two_text_values());

    grid.grid.set_masks(name_masked(false));

    assert_eq!(data_column(&grid, 1).title().as_deref(), Some("name (masked)"));
    assert_eq!(data_column(&grid, 0).title().as_deref(), Some("id"));
    let row = grid.grid.store().row(0).expect("a row");
    let tracked = grid.grid.tracked();
    assert_eq!(tracked.lock(&grid.columns[1], &row), Some(CellLock::Masked));
    assert_ne!(tracked.lock(&grid.columns[0], &row), Some(CellLock::Masked));
    let draft = grid.insert_draft();
    let new_row = grid
        .grid
        .store()
        .rows()
        .find(|row| row.draft_id() == Some(draft))
        .expect("the new row");
    assert_eq!(
        grid.grid.tracked().lock(&grid.columns[1], &new_row),
        None,
        "a new row's masked cell took no value"
    );
}

#[gtk4::test]
fn a_masked_key_locks_every_saved_row_and_masked_values_are_never_duplicated() {
    let grid = Grid::open(two_text_columns(), two_text_values());

    grid.grid.set_masks(GridMasks {
        masked_key: true,
        ..name_masked(false)
    });
    grid.focus(0, 0);

    let row = grid.grid.store().row(0).expect("a row");
    assert_eq!(
        grid.grid.tracked().lock(&grid.columns[0], &row),
        Some(CellLock::MaskedKey)
    );
    assert!(!grid.is_enabled("duplicate-rows"), "a copy would write the masked text");
}

#[gtk4::test]
fn reveal_asks_first_then_hands_the_host_the_request() {
    let grid = results();
    grid.grid.set_masks(name_masked(false));
    let header = data_column(&grid, 1).header_menu().expect("the header's menu");
    assert!(
        action_names(&header)
            .iter()
            .any(|action| action == "grid.reveal-masked-at")
    );
    assert!(
        !action_names(&data_column(&grid, 0).header_menu().expect("the header's menu"))
            .iter()
            .any(|action| action == "grid.reveal-masked-at"),
        "an unmasked column offered Reveal"
    );

    grid.grid
        .activate_action("grid.reveal-masked-at", Some(&1u32.to_variant()))
        .expect("the action");
    crate::test_support::drain_main_context();
    let dialog = grid.grid.reveal_dialog().expect("the confirmation");
    assert!(
        grid.take_requests()
            .iter()
            .all(|request| !matches!(request, GridRequest::RevealMasked))
    );
    dialog.emit_by_name::<()>("response", &[&"reveal"]);

    assert!(
        grid.take_requests()
            .iter()
            .any(|request| matches!(request, GridRequest::RevealMasked))
    );
    dialog.force_close();
}

#[gtk4::test]
fn a_revealed_grid_offers_no_reveal_and_exports_masked_by_the_rules() {
    let grid = results();
    grid.grid.set_masks(name_masked(true));

    assert_eq!(data_column(&grid, 1).title().as_deref(), Some("name"));
    assert!(
        !action_names(&data_column(&grid, 1).header_menu().expect("the header's menu"))
            .iter()
            .any(|action| action == "grid.reveal-masked-at")
    );
    grid.activate("export");

    let masks = grid.take_requests().into_iter().find_map(|request| match request {
        GridRequest::Export(ExportSource::Rows { masks, .. }) => Some(masks),
        _ => None,
    });
    assert_eq!(masks.expect("an export").styles(), [None, Some(MaskingStyle::Email)]);
}

#[gtk4::test]
fn a_saved_rule_masks_the_rows_on_screen() {
    let grid = results();

    grid.grid.remask(name_masked(false));

    let row = grid.grid.store().row(0).expect("a row");
    let cells = row.cells().expect("cells");
    assert_eq!(cells[1], Value::Text("••••".to_owned()));
    assert_eq!(cells[0], Value::Int(1));
    assert!(grid.grid.masks().is_masked(1));
}
