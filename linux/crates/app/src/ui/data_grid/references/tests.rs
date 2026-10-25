use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;
use tablepro_core::ddl::{InboundForeignKey, OutboundForeignKey};
use tablepro_core::filter::{Combinator, FilterOp, FilterRule, FilterSet, FilterValue};
use tablepro_core::meta::TableRef;
use tablepro_core::{ColumnInfo, ForeignKeyInfo, Value};

use crate::application::ShortcutOwner;
use crate::test_support::shortcut_keys::{keystroke, owner_controller, shortcuts, trigger_keys};
use crate::test_support::wait_until;
use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, named, persisted};
use crate::ui::data_grid::{GridRequest, KeysHandle, TableKeys};

type Item = (String, Option<String>, Option<u32>);

fn public(name: &str) -> TableRef {
    TableRef::new(Some("public".to_owned()), name)
}

fn key(columns: &[&str], to: TableRef, ref_columns: &[&str]) -> ForeignKeyInfo {
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

fn filter(rules: &[(&str, &str)]) -> FilterSet {
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

fn with_keys(columns: Vec<ColumnInfo>, rows: Vec<Vec<Value>>, keys: TableKeys) -> Grid {
    let handle = KeysHandle::new(keys.table.clone());
    handle.set(keys);
    Grid::build(
        GridSpec {
            references: Some(handle),
            ..GridSpec::table(columns)
        },
        persisted(&rows),
    )
}

/// `orders` keyed by `id`, whose `customer_id` points at customers.
fn orders_grid(outbound: Vec<ForeignKeyInfo>) -> Grid {
    with_keys(
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
            outbound: outbound
                .into_iter()
                .map(|key| OutboundForeignKey {
                    key,
                    parent_compares_alike: true,
                })
                .collect(),
            inbound: Vec::new(),
        },
    )
}

fn open_menu(grid: &Grid, id: i64, column: usize) {
    assert!(
        grid.grid.open_cell_menu(&grid.cell_of(id, column), None),
        "the menu opens"
    );
}

fn close_menus(grid: &Grid) {
    if let Some(menus) = grid.grid.menus() {
        menus.cell.popdown();
        menus.reference_chooser.popdown();
    }
}

/// The foreign key items the cell menu holds, submenus opened, as each
/// one's label, action and the index it carries.
fn reference_items(grid: &Grid) -> Vec<Item> {
    let menus = grid.grid.menus().expect("the grid's menus");
    items(menus.references.upcast_ref())
}

fn items(menu: &gio::MenuModel) -> Vec<Item> {
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

fn item(label: &str, action: Option<&str>, target: Option<u32>) -> Item {
    (label.to_owned(), action.map(str::to_owned), target)
}

fn followed(grid: &Grid) -> Vec<(TableRef, FilterSet)> {
    grid.take_requests()
        .into_iter()
        .filter_map(|request| match request {
            GridRequest::FollowReference(reference) => Some((reference.table, reference.filter)),
            _ => None,
        })
        .collect()
}

/// Ctrl+J on the focused cell, as a key press reaching the grid's
/// controller would. `true` when the grid took the key.
fn ctrl_j(grid: &Grid) -> bool {
    let view = grid.grid.column_view();
    let controller = owner_controller(&view, ShortcutOwner::GridCell).expect("the grid's cell keys");
    let action = shortcuts(&controller)
        .into_iter()
        .find(|shortcut| {
            shortcut
                .trigger()
                .is_some_and(|trigger| trigger_keys(&trigger).contains(&keystroke("<Primary>j")))
        })
        .and_then(|shortcut| shortcut.action())
        .expect("the grid binds Ctrl+J");
    action.activate(gtk::ShortcutActionFlags::empty(), &view, None)
}

#[gtk4::test]
fn a_key_cell_offers_open_referenced_row_and_sends_the_rows_it_names() {
    let grid = orders_grid(vec![key(&["customer_id"], public("customers"), &["id"])]);

    open_menu(&grid, 1, 1);
    let offered = reference_items(&grid);
    grid.grid
        .activate_action("grid.open-reference", Some(&0u32.to_variant()))
        .expect("the menu's item");
    close_menus(&grid);

    assert_eq!(
        offered,
        [item("Open Referenced Row", Some("grid.open-reference"), Some(0))]
    );
    assert_eq!(followed(&grid), [(public("customers"), filter(&[("id", "42")]))]);
}

/// The menu acts on the key it offered: keys read while it is open
/// change Ctrl+J, not the menu.
#[gtk4::test]
fn a_menu_follows_the_key_it_offered_after_the_keys_are_read_again() {
    let handle = KeysHandle::new(public("orders"));
    handle.set(TableKeys {
        table: public("orders"),
        outbound: vec![OutboundForeignKey {
            key: key(&["customer_id"], public("customers"), &["id"]),
            parent_compares_alike: true,
        }],
        inbound: Vec::new(),
    });
    let grid = Grid::build(
        GridSpec {
            references: Some(handle.clone()),
            ..GridSpec::table(vec![
                named("id", "integer", true),
                named("customer_id", "integer", false),
            ])
        },
        persisted(&[vec![Value::Int(1), Value::Int(42)]]),
    );
    open_menu(&grid, 1, 1);

    handle.set(TableKeys {
        table: public("orders"),
        outbound: Vec::new(),
        inbound: Vec::new(),
    });
    grid.grid.keys_changed();
    grid.grid
        .activate_action("grid.open-reference", Some(&0u32.to_variant()))
        .expect("the menu's item");
    close_menus(&grid);

    assert_eq!(followed(&grid), [(public("customers"), filter(&[("id", "42")]))]);
}

#[gtk4::test]
fn a_null_key_and_a_column_in_no_key_offer_nothing() {
    let grid = orders_grid(vec![key(&["customer_id"], public("customers"), &["id"])]);

    open_menu(&grid, 2, 1);
    let on_null = reference_items(&grid);
    open_menu(&grid, 1, 2);
    let on_other = reference_items(&grid);
    close_menus(&grid);

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

    open_menu(&grid, 1, 2);
    let offered = reference_items(&grid);
    grid.grid
        .activate_action("grid.open-reference", Some(&1u32.to_variant()))
        .expect("the second key");
    close_menus(&grid);

    assert_eq!(
        offered,
        [
            item("Open Referenced Row", None, None),
            item("tenants (tenant__id)", Some("grid.open-reference"), Some(0)),
            item(
                "crm.customers (tenant__id, customer__id)",
                Some("grid.open-reference"),
                Some(1)
            ),
        ]
    );
    assert_eq!(followed(&grid), [(crm, filter(&[("tenant_id", "7"), ("id", "42")]))]);
}

/// One column pointing at two columns of one table gives the two keys
/// the same columns, so their constraints tell them apart.
#[gtk4::test]
fn keys_from_the_same_columns_into_one_table_name_their_constraints() {
    let mut by_id = key(&["customer_id"], public("customers"), &["id"]);
    by_id.name = "by_id".to_owned();
    let mut by_code = key(&["customer_id"], public("customers"), &["code"]);
    by_code.name = "by_code".to_owned();
    let grid = orders_grid(vec![by_id, by_code]);

    open_menu(&grid, 1, 1);
    let offered = reference_items(&grid);
    close_menus(&grid);

    assert_eq!(
        offered,
        [
            item("Open Referenced Row", None, None),
            item(
                "customers (customer__id) through by__id",
                Some("grid.open-reference"),
                Some(0)
            ),
            item(
                "customers (customer__id) through by__code",
                Some("grid.open-reference"),
                Some(1)
            ),
        ]
    );
}

#[gtk4::test]
fn a_key_the_catalogue_could_not_pair_is_offered_and_says_why_it_cannot_open() {
    let grid = orders_grid(vec![key(&["customer_id"], public("ghost"), &[])]);

    open_menu(&grid, 1, 1);
    let offered = reference_items(&grid).len();
    grid.activate("follow-reference");
    close_menus(&grid);

    assert_eq!(offered, 1);
    let toasts: Vec<String> = grid
        .take_requests()
        .into_iter()
        .filter_map(|request| match request {
            GridRequest::Toast(text) => Some(text),
            GridRequest::FollowReference(reference) => panic!("opened {reference:?}"),
            _ => None,
        })
        .collect();
    assert_eq!(toasts.len(), 1);
    assert!(toasts[0].contains("customer_id_fkey"), "{toasts:?}");
}

#[gtk4::test]
fn referencing_rows_are_offered_for_a_saved_row_and_not_for_a_draft() {
    let orders = TableRef::new(Some("sales".to_owned()), "orders");
    let grid = with_keys(
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

    open_menu(&grid, 1, 1);
    let offered = reference_items(&grid);
    grid.grid
        .activate_action("grid.show-referencing-rows", Some(&0u32.to_variant()))
        .expect("the menu's Show Referencing Rows");
    close_menus(&grid);
    let opened = followed(&grid);
    grid.insert_draft();
    let mut draft = None;
    wait_until(WAIT, || {
        draft = grid
            .cells()
            .into_iter()
            .find(|cell| cell.row().is_some_and(|row| row.draft_id().is_some()));
        draft.is_some()
    })
    .expect("the draft is drawn");
    grid.grid.open_cell_menu(&draft.expect("the draft's cell"), None);
    let on_draft = reference_items(&grid);
    close_menus(&grid);

    assert_eq!(
        offered,
        [
            item("Show Referencing Rows", None, None),
            item(
                "sales.orders (customer__id)",
                Some("grid.show-referencing-rows"),
                Some(0)
            ),
        ]
    );
    assert_eq!(opened, [(orders, filter(&[("customer_id", "1")]))]);
    assert_eq!(on_draft, [], "a draft is offered rows that point at it");
}

#[gtk4::test]
fn a_grid_given_no_keys_offers_no_reference_items() {
    let grid = Grid::open(
        vec![named("id", "integer", true), named("customer_id", "integer", false)],
        vec![vec![Value::Int(1), Value::Int(42)]],
    );

    open_menu(&grid, 1, 1);
    let offered = reference_items(&grid);
    let enabled = grid.is_enabled("follow-reference");
    grid.activate("follow-reference");
    close_menus(&grid);

    assert_eq!(offered, []);
    assert!(!enabled);
    assert_eq!(followed(&grid), []);
}

#[gtk4::test]
fn ctrl_j_follows_the_one_key_of_the_focused_cell_and_lets_the_key_go_on_elsewhere() {
    let grid = orders_grid(vec![key(&["customer_id"], public("customers"), &["id"])]);

    grid.focus(0, 1);
    assert!(ctrl_j(&grid));
    grid.focus(0, 2);
    assert!(!ctrl_j(&grid), "a column in no key took Ctrl+J");
    grid.focus(1, 1);
    assert!(!ctrl_j(&grid), "a NULL key took Ctrl+J");

    assert_eq!(followed(&grid), [(public("customers"), filter(&[("id", "42")]))]);
}

#[gtk4::test]
fn ctrl_j_on_a_column_in_two_keys_offers_them_at_the_cell() {
    let crm = TableRef::new(Some("crm".to_owned()), "customers");
    let grid = orders_grid(vec![
        key(&["tenant_id"], public("tenants"), &["id"]),
        key(&["tenant_id", "customer_id"], crm.clone(), &["tenant_id", "id"]),
    ]);
    grid.focus(0, 2);

    assert!(ctrl_j(&grid));

    let chooser = grid
        .grid
        .menus()
        .map(|menus| menus.reference_chooser.clone())
        .expect("the chooser");
    wait_until(WAIT, || chooser.is_visible()).expect("the keys are offered");
    let offered = chooser.menu_model().map(|model| items(&model)).unwrap_or_default();
    assert!(followed(&grid).is_empty(), "a key was followed before one was chosen");
    grid.grid
        .activate_action("grid.open-reference", Some(&1u32.to_variant()))
        .expect("the chooser's second key");
    close_menus(&grid);

    assert_eq!(offered.len(), 2, "{offered:?}");
    assert_eq!(followed(&grid), [(crm, filter(&[("tenant_id", "7"), ("id", "42")]))]);
}

#[gtk4::test]
fn keys_read_after_the_focus_landed_turn_ctrl_j_on() {
    let columns = vec![named("id", "integer", true), named("customer_id", "integer", false)];
    let handle = KeysHandle::new(public("orders"));
    let grid = Grid::build(
        GridSpec {
            references: Some(handle.clone()),
            ..GridSpec::table(columns)
        },
        persisted(&[vec![Value::Int(1), Value::Int(42)]]),
    );
    grid.focus(0, 1);
    assert!(!grid.is_enabled("follow-reference"), "no keys yet");

    handle.set(TableKeys {
        table: public("orders"),
        outbound: vec![OutboundForeignKey {
            key: key(&["customer_id"], public("customers"), &["id"]),
            parent_compares_alike: true,
        }],
        inbound: Vec::new(),
    });
    grid.grid.keys_changed();

    assert!(grid.is_enabled("follow-reference"));
}
