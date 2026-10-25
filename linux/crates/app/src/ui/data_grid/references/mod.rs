use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::Value;
use tablepro_core::browse::{ReferenceError, RowReference};
use tablepro_core::column::ResultColumn;
use tablepro_core::ddl::{InboundForeignKey, OutboundForeignKey};
use tablepro_core::meta::TableRef;

use super::grid_actions::{add, enable};
use super::selection::Resolved;
use super::{DataGrid, GridCell, GridRequest, GridRow, KeysHandle, PinnedRow, TableKeys};
use crate::i18n::{gettext, gettext_f};
use crate::services::grid::GridColumn;
use crate::ui::menu_label;

#[cfg(test)]
mod tests;

const FOLLOW: &str = "follow-reference";
const OPEN_CHOICE: &str = "open-reference";
const REFERENCING: &str = "show-referencing-rows";

/// The keys a row leads somewhere by from one of its cells, under the
/// keys read when they were taken.
#[derive(Debug, Default)]
struct Offers {
    keys: Option<Rc<TableKeys>>,
    /// The table's keys that hold the cell's column, by position.
    open: Vec<usize>,
    /// The other tables' keys that point at the row, by position.
    referencing: Vec<usize>,
}

/// What a menu or the chooser offered, and the row it was opened on. The
/// choices act on this rather than on the keys or rows of the moment, so
/// a key read or a page that lands while a menu is open changes nothing
/// it does.
#[derive(Debug, Default)]
pub struct Armed {
    offers: Offers,
    row: Option<PinnedRow>,
}

impl Armed {
    fn new(grid: &DataGrid, row: &GridRow, column: usize) -> Self {
        Self {
            offers: offers(grid, row, column),
            row: Some(row.pin()),
        }
    }

    fn referenced(&self, grid: &DataGrid, index: usize) -> Option<Result<RowReference, ReferenceError>> {
        let keys = self.offers.keys.as_ref()?;
        let key = keys.outbound.get(index)?;
        Some(referenced_by(grid, &keys.table, key, self.row.as_ref()?.get()?))
    }

    fn referencing(&self, grid: &DataGrid, index: usize) -> Option<Result<RowReference, ReferenceError>> {
        let keys = self.offers.keys.as_ref()?;
        let key = keys.inbound.get(index)?;
        referencing_by(grid, &keys.table, key, self.row.as_ref()?.get()?)
    }
}

pub fn install_actions(grid: &DataGrid) {
    add(grid, FOLLOW, follow_reference);
    add_choice(grid, OPEN_CHOICE, |grid, index| {
        let reference = grid.imp().armed_references.borrow().referenced(grid, index);
        if let Some(reference) = reference {
            follow(grid, reference);
        }
    });
    add_choice(grid, REFERENCING, |grid, index| {
        let reference = grid.imp().armed_references.borrow().referencing(grid, index);
        if let Some(reference) = reference {
            follow(grid, reference);
        }
    });
}

pub fn refresh_actions(grid: &DataGrid, target: Option<&Resolved>) {
    let follows = !grid.is_editing()
        && target
            .and_then(|target| target.cell.as_ref())
            .is_some_and(|(row, column)| !offers(grid, row, *column).open.is_empty());
    enable(grid, FOLLOW, follows);
}

impl DataGrid {
    /// The table's foreign keys were read: Ctrl+J follows what they
    /// offer now.
    pub(crate) fn keys_changed(&self) {
        self.refresh_actions();
    }

    /// Fill the cell menu's key items for `cell` as the menu opens; a row
    /// or the space below the rows offers none.
    pub(crate) fn arm_references(&self, cell: Option<&GridCell>) {
        let armed = cell
            .and_then(|cell| Some((cell.row()?, cell.column())))
            .map(|(row, column)| Armed::new(self, &row, column))
            .unwrap_or_default();
        self.fill_reference_menus(&armed);
        self.imp().armed_references.replace(armed);
    }

    fn fill_reference_menus(&self, armed: &Armed) {
        let Some(menus) = self.menus() else {
            return;
        };
        let section = &menus.references;
        section.remove_all();
        let Some(choices) = menus.reference_chooser.menu_model().and_downcast::<gio::Menu>() else {
            return;
        };
        choices.remove_all();
        let Some(keys) = armed.offers.keys.as_deref() else {
            return;
        };
        let open = armed.offers.open.iter().filter_map(|&index| {
            let key = &keys.outbound.get(index)?.key;
            let target = TableRef::new(key.ref_schema.clone(), key.ref_table.clone());
            Some((index, KeyName::new(&keys.table, &target, &key.columns, &key.name)))
        });
        for (index, label) in labelled(open.collect()) {
            choices.append_item(&choice(&label, OPEN_CHOICE, index));
        }
        let open_label = gettext("Open Referenced Row");
        match armed.offers.open.as_slice() {
            [] => {}
            // The item shows Ctrl+J but acts on the key it offered, as a key
            // read while the menu is open leaves the menu as it was.
            [index] => {
                let item = crate::application::menu_item(&open_label, &format!("grid.{FOLLOW}"));
                let target = u32::try_from(*index).unwrap_or(u32::MAX);
                item.set_action_and_target_value(Some(&format!("grid.{OPEN_CHOICE}")), Some(&target.to_variant()));
                section.append_item(&item);
            }
            _ => section.append_submenu(Some(&open_label), &choices),
        }
        let inbound = armed.offers.referencing.iter().filter_map(|&index| {
            let key = keys.inbound.get(index)?;
            Some((index, KeyName::new(&keys.table, &key.table, &key.columns, &key.name)))
        });
        let referencing = gio::Menu::new();
        for (index, label) in labelled(inbound.collect()) {
            referencing.append_item(&choice(&label, REFERENCING, index));
        }
        if referencing.n_items() > 0 {
            section.append_submenu(Some(&gettext("Show Referencing Rows")), &referencing);
        }
    }

    /// The keys to choose from, pointing at the cell they were offered
    /// for when it is the focused one.
    fn open_reference_chooser(&self, armed: Armed) {
        let Some(chooser) = self.menus().map(|menus| menus.reference_chooser.clone()) else {
            return;
        };
        let row = armed.row.as_ref().and_then(PinnedRow::get).cloned();
        let at = self
            .focused_cell()
            .filter(|cell| cell.row() == row)
            .and_then(|cell| self.bounds_in_view(cell.upcast_ref()));
        self.fill_reference_menus(&armed);
        self.imp().armed_references.replace(armed);
        self.show_popover(&chooser, at);
    }
}

/// Ctrl+J: follow the one key the target cell's column is in, or offer
/// them when it is in several.
fn follow_reference(grid: &DataGrid) {
    let Some((row, column)) = grid.target().and_then(|target| target.cell) else {
        return;
    };
    let armed = Armed::new(grid, &row, column);
    match armed.offers.open.as_slice() {
        [] => {}
        [index] => {
            if let Some(reference) = armed.referenced(grid, *index) {
                follow(grid, reference);
            }
        }
        _ => grid.open_reference_chooser(armed),
    }
}

fn add_choice(grid: &DataGrid, name: &str, act: impl Fn(&DataGrid, usize) + 'static) {
    let action = gio::SimpleAction::new(name, Some(glib::VariantTy::UINT32));
    let weak = grid.downgrade();
    action.connect_activate(move |_, parameter| {
        let (Some(grid), Some(index)) = (weak.upgrade(), parameter.and_then(glib::Variant::get::<u32>)) else {
            return;
        };
        act(&grid, index as usize);
    });
    grid.actions().add_action(&action);
}

/// What `row` offers from `column`, under the keys read so far. A grid
/// that was given no keys offers nothing.
fn offers(grid: &DataGrid, row: &GridRow, column: usize) -> Offers {
    let Some(keys) = grid
        .config()
        .and_then(|config| config.references.as_ref())
        .map(KeysHandle::get)
    else {
        return Offers::default();
    };
    let columns = grid.grid_columns();
    let Some(name) = columns.get(column).map(|column| column.name.as_str()) else {
        return Offers::default();
    };
    let open = keys
        .outbound
        .iter()
        .enumerate()
        .filter(|(_, outbound)| outbound.key.columns.iter().any(|key_column| key_column == name))
        .filter(|(_, outbound)| leads_somewhere(referenced_by(grid, &keys.table, outbound, row)))
        .map(|(index, _)| index)
        .collect();
    let referencing = keys
        .inbound
        .iter()
        .enumerate()
        .filter(|(_, inbound)| referencing_by(grid, &keys.table, inbound, row).is_some_and(leads_somewhere))
        .map(|(index, _)| index)
        .collect();
    Offers {
        keys: Some(keys),
        open,
        referencing,
    }
}

/// The row `key` points at from `row` as the grid shows it, pending
/// edits included.
fn referenced_by(
    grid: &DataGrid,
    source: &TableRef,
    key: &OutboundForeignKey,
    row: &GridRow,
) -> Result<RowReference, ReferenceError> {
    let tracked = grid.tracked();
    let (columns, values) = key_cells(&grid.grid_columns(), &key.key.columns, |index| {
        Some(tracked.with_value(row, index, |value, _| value.clone()))
    });
    RowReference::referenced(source, key, &columns, &values)
}

/// The rows of `key` that point at `row` as it was saved, since that is
/// what they reference. A draft is not saved, so `None`.
fn referencing_by(
    grid: &DataGrid,
    source: &TableRef,
    key: &InboundForeignKey,
    row: &GridRow,
) -> Option<Result<RowReference, ReferenceError>> {
    let saved = row.cells()?;
    let (columns, values) = key_cells(&grid.grid_columns(), &key.referenced_columns, |index| {
        saved.get(index).cloned()
    });
    Some(RowReference::referencing(source, key, &columns, &values))
}

/// The columns named `names` with the row's values, read through
/// `value`, so a row of large cells copies only its key's.
fn key_cells(
    columns: &[GridColumn],
    names: &[String],
    value: impl Fn(usize) -> Option<Value>,
) -> (Vec<ResultColumn>, Vec<Value>) {
    names
        .iter()
        .filter_map(|name| {
            let column = columns.iter().find(|column| column.name == *name)?;
            Some((column.result_column(), value(column.index)?))
        })
        .unzip()
}

/// Open what a key leads to, or say why it cannot.
fn follow(grid: &DataGrid, reference: Result<RowReference, ReferenceError>) {
    match reference {
        Ok(reference) => grid.request(GridRequest::FollowReference(reference)),
        Err(error) => grid.toast(crate::ui::error_text::reference_message(&error)),
    }
}

/// A key that cannot be followed is still offered, so the toast it
/// raises says why; one with nothing to follow is not.
fn leads_somewhere(reference: Result<RowReference, ReferenceError>) -> bool {
    match reference {
        Ok(_) => true,
        Err(error) => !error.leaves_nothing_to_follow(),
    }
}

fn choice(label: &str, action: &str, index: usize) -> gio::MenuItem {
    let item = gio::MenuItem::new(Some(label), None);
    let target = u32::try_from(index).unwrap_or(u32::MAX);
    item.set_action_and_target_value(Some(&format!("grid.{action}")), Some(&target.to_variant()));
    item
}

/// How an item names its key: the other table, with its schema where
/// that is not the source's, and the key's columns on the side that
/// holds it, which tell two keys into one table apart.
struct KeyName {
    short: String,
    constraint: String,
}

impl KeyName {
    fn new(source: &TableRef, table: &TableRef, columns: &[String], constraint: &str) -> Self {
        let name = match (&table.schema, table.schema == source.schema) {
            (Some(schema), false) => format!("{schema}.{}", table.name),
            _ => table.name.clone(),
        };
        Self {
            short: format!("{name} ({})", columns.join(", ")),
            constraint: constraint.to_owned(),
        }
    }
}

/// Each key's label. Two keys from the same columns into the same table
/// also name their constraint, since they point at different columns.
fn labelled(names: Vec<(usize, KeyName)>) -> Vec<(usize, String)> {
    let shared = |short: &str| names.iter().filter(|(_, name)| name.short == short).count() > 1;
    names
        .iter()
        .map(|(index, name)| {
            let label = match shared(&name.short) {
                true => gettext_f(
                    "{key} through {constraint}",
                    &[("key", &name.short), ("constraint", &name.constraint)],
                ),
                false => name.short.clone(),
            };
            (*index, menu_label(&label))
        })
        .collect()
}
