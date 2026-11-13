use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::column::ResultColumn;

use super::grid_actions::{add, add_for_column, enable};
use super::{DataGrid, GridRequest, GridRow, RowData};
use crate::i18n::{gettext, gettext_f};
use crate::services::grid::{GridColumn, GridMasks, OutwardRules, remask_rows};

pub(super) fn install_actions(grid: &DataGrid) {
    add(grid, "reveal-masked", |grid| {
        if grid.target_column().is_some_and(|index| grid.offers_reveal(index)) {
            confirm_reveal(grid);
        }
    });
    add_for_column(grid, "reveal-masked-at", |grid, index| {
        if grid.offers_reveal(index) {
            confirm_reveal(grid);
        }
    });
}

pub(super) fn refresh_actions(grid: &DataGrid, column: Option<usize>) {
    enable(
        grid,
        "reveal-masked",
        column.is_some_and(|index| grid.offers_reveal(index)),
    );
}

// A header names a masked column as masked, since GTK draws a header's title and nothing else.
pub(super) fn header_title(column: &GridColumn, masks: &GridMasks) -> String {
    match masks.is_masked(column.index) {
        true => gettext_f("{column} (masked)", &[("column", &column.name)]),
        false => column.name.clone(),
    }
}

impl DataGrid {
    // The columns draw again, so the headers and the cell locks follow.
    pub fn set_masks(&self, masks: GridMasks) {
        let imp = self.imp();
        if *imp.masks.borrow() == masks {
            return;
        }
        imp.masks.replace(masks.clone());
        self.edit().set_masks(&masks);
        let (columns, sorting) = {
            let set = imp.columns.borrow();
            (set.columns(), set.sorting())
        };
        if !columns.is_empty() {
            self.commit_editors();
            self.rebuild_columns(columns, sorting);
            self.columns_took_rows();
        }
        self.refresh_actions();
    }

    pub fn masks(&self) -> GridMasks {
        self.imp().masks.borrow().clone()
    }

    // The held cells' masks with what every path out takes under the rules as they are now, with their generation.
    pub(crate) fn outward_masks(&self) -> (GridMasks, Option<(u64, OutwardRules)>) {
        let held = self.masks();
        let Some((outward, table)) = self
            .config()
            .and_then(|config| Some((config.outward.clone()?, config.table.clone())))
        else {
            return (held, None);
        };
        let columns: Vec<ResultColumn> = self.grid_columns().iter().map(GridColumn::result_column).collect();
        let (generation, fresh) = outward.now(&columns, table.as_ref());
        let masks = GridMasks {
            external: fresh.external,
            untraced: fresh.untraced,
            ..held
        };
        (masks, Some((generation, outward)))
    }

    // After a saved change: a column already masked keeps its mask, since the value under it is gone.
    pub fn remask(&self, fresh: GridMasks) {
        let held = self.masks();
        let columns: Vec<ResultColumn> = self.grid_columns().iter().map(GridColumn::result_column).collect();
        let rows: Vec<(GridRow, Arc<[Value]>)> = self
            .store()
            .rows()
            .filter_map(|row| row.cells().map(|cells| (row, cells)))
            .collect();
        let cells: Vec<Arc<[Value]>> = rows.iter().map(|(_, cells)| cells.clone()).collect();
        let shown = match remask_rows(&columns, &held.shown, &fresh.shown, &cells) {
            Some((shown, masked)) => {
                self.commit_editors();
                for ((row, _), cells) in rows.iter().zip(masked) {
                    let id = row.data().id;
                    row.set_data(RowData { id, cells: Some(cells) });
                }
                shown
            }
            None => held.shown.clone(),
        };
        self.set_masks(GridMasks { shown, ..fresh });
        self.find_rows_changed();
    }

    pub(super) fn offers_reveal(&self, column: usize) -> bool {
        self.config().is_some_and(|config| config.reveal) && {
            let masks = self.imp().masks.borrow();
            masks.revealable() && masks.is_masked(column)
        }
    }
}

// Reveal shows this tab's values on screen only; every path out of the app stays masked.
fn confirm_reveal(grid: &DataGrid) {
    let dialog = adw::AlertDialog::builder()
        .heading(gettext("Reveal Masked Values?"))
        .body(gettext(
            "This tab shows the values the connection's masking rules hide. Exports, shares and the assistant stay masked.",
        ))
        .close_response("cancel")
        .default_response("cancel")
        .build();
    dialog.add_response("cancel", &gettext("Cancel"));
    dialog.add_response("reveal", &gettext("Reveal"));
    dialog.set_response_appearance("reveal", adw::ResponseAppearance::Suggested);
    let weak = grid.downgrade();
    dialog.connect_response(None, move |_, response| {
        if let (Some(grid), "reveal") = (weak.upgrade(), response) {
            grid.request(GridRequest::RevealMasked);
        }
    });
    #[cfg(test)]
    grid.imp().reveal_dialogs.borrow_mut().push(dialog.clone());
    dialog.present(Some(grid));
}

#[cfg(test)]
impl DataGrid {
    pub(crate) fn reveal_dialog(&self) -> Option<adw::AlertDialog> {
        self.imp().reveal_dialogs.borrow().last().cloned()
    }
}
