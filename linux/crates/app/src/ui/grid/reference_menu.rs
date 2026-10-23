use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::ForeignKeyInfo;
use tablepro_core::browse::{ReferenceError, RowReference};
use tablepro_core::column::ResultColumn;
use tablepro_core::ddl::InboundForeignKey;
use tablepro_core::meta::TableRef;

use super::{GridCell, GridMsg, GridSink, KeysHandle, RowObject, TabGridContext, TableKeys};
use crate::ui::menu_label;

pub(super) const OPEN_ONE: &str = "open-referenced-row";
pub(super) const OPEN_CHOICE: &str = "open-reference";
pub(super) const REFERENCING: &str = "show-referencing-rows";

/// The keys a row leads somewhere by, as a menu opened on one of its
/// cells offers them.
#[derive(Debug, Clone, Default)]
pub(super) struct Offers {
    keys: Option<Rc<TableKeys>>,
    /// The table's keys that hold the cell's column, by position.
    pub(super) open: Vec<usize>,
    /// The other tables' keys that point at the row, by position.
    pub(super) referencing: Vec<usize>,
}

/// The cell menu's foreign key items: one section both cell menus show,
/// filled as a menu opens, since a submenu cannot hide itself.
#[derive(Clone)]
pub(super) struct ReferenceMenu {
    tab: Rc<TabGridContext>,
    columns: Arc<[ResultColumn]>,
    section: gio::Menu,
    /// The choices a column in more than one key offers, which the
    /// keyboard shows on its own.
    choices: gio::Menu,
    armed: Rc<RefCell<Offers>>,
}

impl ReferenceMenu {
    pub(super) fn new(tab: Rc<TabGridContext>, columns: Arc<[ResultColumn]>) -> Self {
        Self {
            tab,
            columns,
            section: gio::Menu::new(),
            choices: gio::Menu::new(),
            armed: Rc::default(),
        }
    }

    pub(super) fn section(&self) -> &gio::Menu {
        &self.section
    }

    pub(super) fn choices(&self) -> &gio::Menu {
        &self.choices
    }

    /// What a menu opened on `cell` would offer, under the keys read so
    /// far. A grid of query results has no keys and offers nothing.
    pub(super) fn offers_for(&self, cell: &GridCell) -> Offers {
        let (Some(keys), Some(row)) = (self.tab.keys.as_ref().map(KeysHandle::get), cell.row()) else {
            return Offers::default();
        };
        let Some(column) = self.columns.get(cell.column()) else {
            return Offers::default();
        };
        let open = keys
            .outbound
            .iter()
            .enumerate()
            .filter(|(_, key)| key.columns.contains(&column.name))
            .filter(|(_, key)| leads_somewhere(self.referenced_by(&keys.table, key, &row)))
            .map(|(index, _)| index)
            .collect();
        let referencing = keys
            .inbound
            .iter()
            .enumerate()
            .filter(|(_, key)| self.referencing_by(&keys.table, key, &row).is_some_and(leads_somewhere))
            .map(|(index, _)| index)
            .collect();
        Offers {
            keys: Some(keys),
            open,
            referencing,
        }
    }

    /// Fill the section for `cell` as its menu opens.
    pub(super) fn arm(&self, cell: &GridCell) {
        let offers = self.offers_for(cell);
        self.section.remove_all();
        self.choices.remove_all();
        if let Some(keys) = offers.keys.as_deref() {
            let open: Vec<(usize, KeyName)> = offers
                .open
                .iter()
                .filter_map(|&index| {
                    let key = keys.outbound.get(index)?;
                    let target = TableRef::new(key.ref_schema.clone(), key.ref_table.clone());
                    Some((index, KeyName::new(&keys.table, &target, &key.columns, &key.name)))
                })
                .collect();
            for (index, label) in labelled(open) {
                self.choices.append_item(&choice(&label, OPEN_CHOICE, index));
            }
            match offers.open.len() {
                0 => {}
                1 => self.section.append_item(&crate::application::menu_item(
                    &crate::i18n::gettext("Open Referenced Row"),
                    &format!("cell.{OPEN_ONE}"),
                )),
                _ => self
                    .section
                    .append_submenu(Some(&crate::i18n::gettext("Open Referenced Row")), &self.choices),
            }
            let referencing = gio::Menu::new();
            let inbound: Vec<(usize, KeyName)> = offers
                .referencing
                .iter()
                .filter_map(|&index| {
                    let key = keys.inbound.get(index)?;
                    Some((index, KeyName::new(&keys.table, &key.table, &key.columns, &key.name)))
                })
                .collect();
            for (index, label) in labelled(inbound) {
                referencing.append_item(&choice(&label, REFERENCING, index));
            }
            if referencing.n_items() > 0 {
                self.section
                    .append_submenu(Some(&crate::i18n::gettext("Show Referencing Rows")), &referencing);
            }
        }
        self.armed.replace(offers);
    }

    /// The row the outbound key at `index` points at from `row`, under
    /// the keys the menu opened with.
    pub(super) fn referenced(&self, index: usize, row: &RowObject) -> Option<Result<RowReference, ReferenceError>> {
        let armed = self.armed.borrow();
        let keys = armed.keys.as_ref()?;
        let key = keys.outbound.get(index)?;
        Some(self.referenced_by(&keys.table, key, row))
    }

    /// The rows the inbound key at `index` holds that point at `row`.
    pub(super) fn referencing(&self, index: usize, row: &RowObject) -> Option<Result<RowReference, ReferenceError>> {
        let armed = self.armed.borrow();
        let keys = armed.keys.as_ref()?;
        let key = keys.inbound.get(index)?;
        self.referencing_by(&keys.table, key, row)
    }

    /// The row `key` points at from `row` as the grid shows it, pending
    /// edits included.
    fn referenced_by(
        &self,
        source: &TableRef,
        key: &ForeignKeyInfo,
        row: &RowObject,
    ) -> Result<RowReference, ReferenceError> {
        let (columns, values) = self.key_cells(&key.columns, |index| {
            Some(self.tab.with_effective_value(row, index, |value, _| value.clone()))
        });
        RowReference::referenced(source, key, &columns, &values)
    }

    /// The rows of `key` that point at `row` as it was saved, since that
    /// is what they reference. A draft is not saved, so `None`.
    fn referencing_by(
        &self,
        source: &TableRef,
        key: &InboundForeignKey,
        row: &RowObject,
    ) -> Option<Result<RowReference, ReferenceError>> {
        let saved = row.cells()?;
        let (columns, values) = self.key_cells(&key.referenced_columns, |index| saved.get(index).cloned());
        Some(RowReference::referencing(source, key, &columns, &values))
    }

    /// The row's columns named `names` with their values, read through
    /// `value`, so a row of large cells copies only its key's.
    fn key_cells(
        &self,
        names: &[String],
        value: impl Fn(usize) -> Option<tablepro_core::Value>,
    ) -> (Vec<ResultColumn>, Vec<tablepro_core::Value>) {
        names
            .iter()
            .filter_map(|name| {
                let index = self.columns.iter().position(|column| column.name == *name)?;
                Some((self.columns.get(index)?.clone(), value(index)?))
            })
            .unzip()
    }

    /// The one outbound key the armed menu offers, for its plain item.
    pub(super) fn only_choice(&self) -> Option<usize> {
        match self.armed.borrow().open.as_slice() {
            [index] => Some(*index),
            _ => None,
        }
    }
}

/// Open what a key leads to, or say why it cannot.
pub(super) fn follow(sink: &GridSink, reference: Result<RowReference, ReferenceError>) {
    match reference {
        Ok(reference) => sink(GridMsg::FollowReference(reference)),
        Err(error) => sink(GridMsg::ShowToast(crate::ui::error_text::reference_message(&error))),
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
    item.set_action_and_target_value(Some(&format!("cell.{action}")), Some(&target.to_variant()));
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
                true => crate::i18n::gettext_f(
                    "{key} through {constraint}",
                    &[("key", &name.short), ("constraint", &name.constraint)],
                ),
                false => name.short.clone(),
            };
            (*index, menu_label(&label))
        })
        .collect()
}

/// The index a parameterized item carries.
pub(super) fn chosen(parameter: Option<&glib::Variant>) -> Option<usize> {
    parameter
        .and_then(glib::Variant::get::<u32>)
        .and_then(|index| usize::try_from(index).ok())
}

#[cfg(test)]
pub(super) mod tests {
    use gtk4 as gtk;
    use gtk4::gio;
    use gtk4::prelude::*;
    use tablepro_core::ddl::InboundForeignKey;
    use tablepro_core::filter::{Combinator, FilterOp, FilterRule, FilterSet, FilterValue};
    use tablepro_core::meta::TableRef;
    use tablepro_core::{ForeignKeyInfo, Value};

    use crate::test_support::descendants;
    use crate::ui::grid::test_grid::{Grid, named, open_menu};
    use crate::ui::grid::{GridMsg, TableKeys};

    pub(in crate::ui::grid) fn public(name: &str) -> TableRef {
        TableRef::new(Some("public".to_owned()), name)
    }

    pub(in crate::ui::grid) fn key(columns: &[&str], to: TableRef, ref_columns: &[&str]) -> ForeignKeyInfo {
        ForeignKeyInfo {
            name: format!("{}_fkey", columns.join("_")),
            columns: columns.iter().map(|name| (*name).to_owned()).collect(),
            ref_schema: to.schema,
            ref_table: to.name,
            ref_columns: ref_columns.iter().map(|name| (*name).to_owned()).collect(),
            on_delete: None,
            on_update: None,
        }
    }

    pub(in crate::ui::grid) fn filter(rules: &[(&str, &str)]) -> FilterSet {
        FilterSet {
            combinator: Combinator::And,
            rules: rules
                .iter()
                .map(|(column, text)| FilterRule {
                    column: (*column).to_owned(),
                    op: FilterOp::Eq,
                    value: Some(FilterValue::Single((*text).to_owned())),
                })
                .collect(),
            extra_sql: None,
        }
    }

    /// `orders` keyed by `id`, whose `customer_id` points at customers.
    pub(in crate::ui::grid) fn orders_grid(outbound: Vec<ForeignKeyInfo>) -> Grid {
        Grid::open_with_keys(
            vec![
                named("id", "integer", true),
                named("customer_id", "integer", false),
                named("tenant_id", "integer", false),
            ],
            vec![
                vec![Value::Int(1), Value::Int(42), Value::Int(7)],
                vec![Value::Int(2), Value::Null, Value::Int(7)],
            ],
            TableKeys {
                table: public("orders"),
                outbound,
                inbound: Vec::new(),
            },
        )
    }

    /// The foreign key items the open cell menu holds, submenus opened,
    /// as each one's label, action and the index it carries.
    pub(in crate::ui::grid) fn reference_items(grid: &Grid) -> Vec<(String, Option<String>, Option<u32>)> {
        let menu = descendants(&grid.view)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::PopoverMenu>().ok())
            .filter_map(|popover| popover.menu_model())
            .find(|model| {
                items(model)
                    .iter()
                    .any(|(_, action, _)| action.as_deref() == Some("cell.show-row-json"))
            })
            .expect("the cell menu");
        items(&menu)
            .into_iter()
            .filter(|(label, action, _)| {
                label.contains("Referenc") || action.as_ref().is_some_and(|a| a.contains("referenc"))
            })
            .collect()
    }

    fn items(menu: &gio::MenuModel) -> Vec<(String, Option<String>, Option<u32>)> {
        let mut found = Vec::new();
        for position in 0..menu.n_items() {
            let attribute = |name: &str| menu.item_attribute_value(position, name, None);
            if let Some(label) = attribute("label").and_then(|value| value.get::<String>()) {
                found.push((
                    label,
                    attribute("action").and_then(|value| value.get::<String>()),
                    attribute("target").and_then(|value| value.get::<u32>()),
                ));
            }
            for link in ["section", "submenu"] {
                if let Some(inner) = menu.item_link(position, link) {
                    found.extend(items(&inner));
                }
            }
        }
        found
    }

    pub(in crate::ui::grid) fn followed(grid: &Grid) -> Vec<(TableRef, FilterSet)> {
        grid.take_messages()
            .into_iter()
            .filter_map(|msg| match msg {
                GridMsg::FollowReference(reference) => Some((reference.table, reference.filter)),
                _ => None,
            })
            .collect()
    }

    fn item(label: &str, action: Option<&str>, target: Option<u32>) -> (String, Option<String>, Option<u32>) {
        (label.to_owned(), action.map(str::to_owned), target)
    }

    #[gtk4::test]
    fn a_key_cell_offers_open_referenced_row_and_sends_the_rows_it_names() {
        let grid = orders_grid(vec![key(&["customer_id"], public("customers"), &["id"])]);

        open_menu(&grid.cell_of(1, 1));
        let offered = reference_items(&grid);
        grid.view
            .activate_action("cell.open-referenced-row", None)
            .expect("the menu's Open Referenced Row");

        assert_eq!(
            offered,
            [item("Open Referenced Row", Some("cell.open-referenced-row"), None)]
        );
        assert_eq!(followed(&grid), [(public("customers"), filter(&[("id", "42")]))]);
    }

    #[gtk4::test]
    fn a_null_key_and_a_column_in_no_key_offer_nothing() {
        let grid = orders_grid(vec![key(&["customer_id"], public("customers"), &["id"])]);

        open_menu(&grid.cell_of(2, 1));
        let on_null = reference_items(&grid);
        open_menu(&grid.cell_of(1, 2));
        let on_other = reference_items(&grid);

        assert_eq!(on_null, []);
        assert_eq!(on_other, []);
    }

    #[gtk4::test]
    fn a_column_in_two_keys_offers_each_and_follows_the_one_chosen() {
        let crm = TableRef::new(Some("crm".to_owned()), "customers");
        let grid = orders_grid(vec![
            key(&["tenant_id"], public("tenants"), &["id"]),
            key(&["tenant_id", "customer_id"], crm.clone(), &["tenant_id", "id"]),
        ]);

        open_menu(&grid.cell_of(1, 2));
        let offered = reference_items(&grid);
        grid.view
            .activate_action("cell.open-reference", Some(&1u32.to_variant()))
            .expect("the second key");

        assert_eq!(
            offered,
            [
                item("Open Referenced Row", None, None),
                item("tenants (tenant__id)", Some("cell.open-reference"), Some(0)),
                item(
                    "crm.customers (tenant__id, customer__id)",
                    Some("cell.open-reference"),
                    Some(1)
                ),
            ]
        );
        assert_eq!(followed(&grid), [(crm, filter(&[("tenant_id", "7"), ("id", "42")]))]);
    }

    /// One column pointing at two columns of one table gives the two
    /// keys the same columns, so their constraints tell them apart.
    #[gtk4::test]
    fn keys_from_the_same_columns_into_one_table_name_their_constraints() {
        let mut by_id = key(&["customer_id"], public("customers"), &["id"]);
        by_id.name = "by_id".to_owned();
        let mut by_code = key(&["customer_id"], public("customers"), &["code"]);
        by_code.name = "by_code".to_owned();
        let grid = orders_grid(vec![by_id, by_code]);

        open_menu(&grid.cell_of(1, 1));

        assert_eq!(
            reference_items(&grid),
            [
                item("Open Referenced Row", None, None),
                item(
                    "customers (customer__id) through by__id",
                    Some("cell.open-reference"),
                    Some(0)
                ),
                item(
                    "customers (customer__id) through by__code",
                    Some("cell.open-reference"),
                    Some(1)
                ),
            ]
        );
    }

    #[gtk4::test]
    fn a_key_the_catalogue_could_not_pair_is_offered_and_says_why_it_cannot_open() {
        let grid = orders_grid(vec![key(&["customer_id"], public("ghost"), &[])]);

        open_menu(&grid.cell_of(1, 1));
        let offered = reference_items(&grid).len();
        grid.view
            .activate_action("cell.open-referenced-row", None)
            .expect("the menu's Open Referenced Row");

        assert_eq!(offered, 1);
        let toasts: Vec<String> = grid
            .take_messages()
            .into_iter()
            .filter_map(|msg| match msg {
                GridMsg::ShowToast(text) => Some(text),
                GridMsg::FollowReference(reference) => panic!("opened {reference:?}"),
                _ => None,
            })
            .collect();
        assert_eq!(toasts.len(), 1);
        assert!(toasts[0].contains("customer_id_fkey"), "{toasts:?}");
    }

    #[gtk4::test]
    fn referencing_rows_are_offered_for_a_saved_row_and_not_for_a_draft() {
        let orders = TableRef::new(Some("sales".to_owned()), "orders");
        let grid = Grid::open_with_keys(
            vec![named("id", "integer", true), named("name", "text", false)],
            vec![vec![Value::Int(1), Value::Text("Ada".into())]],
            TableKeys {
                table: public("customers"),
                outbound: Vec::new(),
                inbound: vec![InboundForeignKey {
                    child_compares_alike: true,
                    name: "orders_customer_id_fkey".to_owned(),
                    table: orders.clone(),
                    columns: vec!["customer_id".to_owned()],
                    referenced_columns: vec!["id".to_owned()],
                }],
            },
        );

        open_menu(&grid.cell_of(1, 1));
        let offered = reference_items(&grid);
        grid.view
            .activate_action("cell.show-referencing-rows", Some(&0u32.to_variant()))
            .expect("the menu's Show Referencing Rows");
        let opened = followed(&grid);
        grid.insert_draft();
        let draft = grid
            .cells()
            .into_iter()
            .find(|cell| cell.row().is_some_and(|row| row.draft_id().is_some()))
            .expect("the draft's cell");
        open_menu(&draft);

        assert_eq!(
            offered,
            [
                item("Show Referencing Rows", None, None),
                item(
                    "sales.orders (customer__id)",
                    Some("cell.show-referencing-rows"),
                    Some(0)
                ),
            ]
        );
        assert_eq!(opened, [(orders, filter(&[("customer_id", "1")]))]);
        assert_eq!(reference_items(&grid), [], "a draft is offered rows that point at it");
    }

    #[gtk4::test]
    fn a_result_grid_offers_no_reference_items() {
        let grid = Grid::open(
            vec![named("id", "integer", true), named("customer_id", "integer", false)],
            vec![vec![Value::Int(1), Value::Int(42)]],
        );

        open_menu(&grid.cell_of(1, 1));

        assert_eq!(reference_items(&grid), []);
        assert!(grid.view.activate_action("cell.open-referenced-row", None).is_ok());
        assert_eq!(followed(&grid), []);
    }
}
