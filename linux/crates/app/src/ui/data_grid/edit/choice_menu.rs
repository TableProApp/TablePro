use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio, glib};
use tablepro_core::Value;
use tablepro_core::column::ColumnKind;
use tablepro_core::edit::{CellInput, EditText, edit_text};

use super::cell_editor::{InlineStart, Plan};
use super::{EditController, edit_start};
use crate::i18n::pgettext;
use crate::services::grid::GridColumn;
use crate::ui::data_grid::grid_menu::presets_section;
use crate::ui::data_grid::selection::Target;
use crate::ui::data_grid::{DataGrid, GridCell, PinnedRow};
use crate::ui::menu_label;

/// The prefix a choice menu's actions are inserted under.
pub const CHOICE_ACTIONS: &str = "choice";

const LABEL: &str = "label";

/// MySQL lists a set's members in the column's order, apart by commas,
/// which no member can hold.
const SEPARATOR: char = ',';

/// A cell's labels as menu items, radio items for an enum and check items
/// for a set, with the actions they act through on the row and column
/// they were made for.
pub struct ChoiceMenu {
    pub section: gio::Menu,
    pub actions: gio::SimpleActionGroup,
}

impl EditController {
    /// The labels the cell at `row` and `column` picks from, as it stands
    /// now. `None` for a cell that does not pick from labels.
    pub fn choice_menu(&self, row: &PinnedRow, column: usize) -> Option<ChoiceMenu> {
        let grid = self.grid.upgrade()?;
        match self.plan(&grid, row.get()?, column) {
            Plan::Choice { start, .. } => build_menu(&grid, &start),
            _ => None,
        }
    }

    /// The menu of `cell`'s labels, with the presets the cell takes.
    pub(super) fn open_choice(&self, grid: &DataGrid, cell: &GridCell, start: &InlineStart) {
        let Some(popover) = grid.menus().and_then(|menus| menus.choices.clone()) else {
            return;
        };
        let Some(menu) = build_menu(grid, start) else {
            return;
        };
        let model = gio::Menu::new();
        model.append_section(None, &menu.section);
        model.append_section(None, &presets_section());
        popover.insert_action_group(CHOICE_ACTIONS, Some(&menu.actions));
        popover.set_menu_model(Some(&model));
        // The header that names the column takes no focus.
        popover.update_property(&[gtk::accessible::Property::Label(&start.column.name)]);
        let pin = start.row.pin();
        grid.hold_menu_target(Target {
            cell: Some((pin.clone(), start.column.index)),
            rows: vec![pin],
        });
        grid.refresh_actions();
        grid.show_popover(&popover, grid.bounds_in_view(cell.upcast_ref()));
    }

    /// Write what `pick` makes of the cell's text now. Returns the text
    /// the cell holds after it, `None` for NULL or DEFAULT. A row that left
    /// its slot or a cell locked since takes nothing.
    fn choose(
        &self,
        grid: &DataGrid,
        row: &PinnedRow,
        column: usize,
        pick: impl FnOnce(Option<&str>) -> String,
    ) -> Option<String> {
        let row = row.get()?.clone();
        let grid_column = self.unlocked_column(grid, &row, column)?;
        grid.commit_editors();
        let start = edit_start(&self.tracked(), &row, column);
        let next = pick(chosen(&grid_column, &start.original).as_deref());
        self.commit_input(grid, &grid_column, &start, CellInput::Value(Value::Text(next)));
        chosen(&grid_column, &self.tracked().edit_input(&row, column))
    }
}

fn build_menu(grid: &DataGrid, start: &InlineStart) -> Option<ChoiceMenu> {
    let ColumnKind::Enum { labels, multiple } = &start.column.value_type().kind else {
        return None;
    };
    let pin = start.row.pin();
    let column = start.column.index;
    let current = chosen(&start.column, &start.start.original);
    let menu = ChoiceMenu {
        section: gio::Menu::new(),
        actions: gio::SimpleActionGroup::new(),
    };
    let labels: Rc<[String]> = labels.as_slice().into();
    match multiple {
        false => enum_items(&menu, grid, pin, column, labels, current.as_deref()),
        true => set_items(&menu, grid, &pin, column, labels, current.as_deref()),
    }
    Some(menu)
}

/// One radio item per label, on one action whose state is the index of
/// the label the cell holds. An index, since a GVariant string ends at a
/// NUL and ClickHouse labels can hold one.
fn enum_items(
    menu: &ChoiceMenu,
    grid: &DataGrid,
    pin: PinnedRow,
    column: usize,
    labels: Rc<[String]>,
    current: Option<&str>,
) {
    let action = gio::SimpleAction::new_stateful(
        LABEL,
        Some(Option::<u32>::static_variant_type().as_ref()),
        &label_index(&labels, current).to_variant(),
    );
    let weak = grid.downgrade();
    let picked = labels.clone();
    action.connect_activate(move |action, parameter| {
        let label = parameter
            .and_then(glib::Variant::get::<Option<u32>>)
            .flatten()
            .and_then(|index| picked.get(usize::try_from(index).ok()?).cloned());
        let (Some(grid), Some(label)) = (weak.upgrade(), label) else {
            return;
        };
        let now = grid.edit().choose(&grid, &pin, column, |_| label);
        action.set_state(&label_index(&picked, now.as_deref()).to_variant());
    });
    menu.actions.add_action(&action);
    for (index, label) in labels.iter().enumerate() {
        let item = gio::MenuItem::new(Some(&item_label(label)), None);
        item.set_action_and_target_value(
            Some(&format!("{CHOICE_ACTIONS}.{LABEL}")),
            Some(&u32::try_from(index).ok().to_variant()),
        );
        menu.section.append_item(&item);
    }
}

/// One check item per label, each on its own action, since a check item
/// reads its state from an action without a target.
fn set_items(
    menu: &ChoiceMenu,
    grid: &DataGrid,
    pin: &PinnedRow,
    column: usize,
    labels: Rc<[String]>,
    current: Option<&str>,
) {
    let held = members(current);
    for (index, label) in labels.iter().enumerate() {
        let name = format!("member-{index}");
        let action = gio::SimpleAction::new_stateful(&name, None, &held.contains(&label.as_str()).to_variant());
        let (weak, pin, labels) = (grid.downgrade(), pin.clone(), labels.clone());
        action.connect_activate(move |action, _| {
            let Some(grid) = weak.upgrade() else {
                return;
            };
            let now = grid
                .edit()
                .choose(&grid, &pin, column, |current| toggled_member(&labels, current, index));
            let member = labels
                .get(index)
                .is_some_and(|label| members(now.as_deref()).contains(&label.as_str()));
            action.set_state(&member.to_variant());
        });
        menu.actions.add_action(&action);
        let item = gio::MenuItem::new(Some(&item_label(label)), Some(&format!("{CHOICE_ACTIONS}.{name}")));
        menu.section.append_item(&item);
    }
}

fn label_index(labels: &[String], text: Option<&str>) -> Option<u32> {
    let index = labels.iter().position(|label| Some(label.as_str()) == text)?;
    u32::try_from(index).ok()
}

/// A NUL shows as U+2400, as in a cell, since GTK's text ends at one.
fn item_label(label: &str) -> String {
    match label.is_empty() {
        // Translators: an enum label that is the empty string, as an item in the menu of a cell's labels.
        true => pgettext("enum label", "Empty"),
        false => menu_label(&label.replace('\0', "\u{2400}")),
    }
}

/// The cell's value as text, `None` for NULL or DEFAULT.
fn chosen(column: &GridColumn, input: &CellInput) -> Option<String> {
    match input {
        CellInput::Default | CellInput::Expression(_) | CellInput::Value(Value::Null) => None,
        CellInput::Value(value) => match edit_text(value, column.value_type()) {
            EditText::Editable(text) => Some(text),
            EditText::ReadOnly(_) => None,
        },
    }
}

fn members(text: Option<&str>) -> Vec<&str> {
    text.map_or_else(Vec::new, |text| {
        text.split(SEPARATOR).filter(|member| !member.is_empty()).collect()
    })
}

/// The set with `labels[index]` added or taken out: the labels in the
/// column's order, then any member the labels do not name, as it was.
fn toggled_member(labels: &[String], current: Option<&str>, index: usize) -> String {
    let held = members(current);
    let known = labels.iter().enumerate().filter(|(at, label)| {
        let holds = held.contains(&label.as_str());
        if *at == index { !holds } else { holds }
    });
    let unknown = held
        .iter()
        .copied()
        .filter(|member| !labels.iter().any(|label| label == member));
    known
        .map(|(_, label)| label.as_str())
        .chain(unknown)
        .collect::<Vec<_>>()
        .join(&SEPARATOR.to_string())
}

#[cfg(test)]
mod tests {
    use super::{members, toggled_member};

    fn labels(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn a_toggled_member_keeps_the_columns_order_and_members_it_does_not_know() {
        let tags = labels(&["new", "sale", "gift"]);

        assert_eq!(toggled_member(&tags, Some("gift"), 0), "new,gift");
        assert_eq!(toggled_member(&tags, Some("new,gift"), 2), "new");
        assert_eq!(
            toggled_member(&tags, Some("new"), 0),
            "",
            "the last member out is the empty set"
        );
        assert_eq!(toggled_member(&tags, None, 1), "sale", "NULL holds no member");
        assert_eq!(
            toggled_member(&tags, Some("old,sale"), 0),
            "new,sale,old",
            "a member the labels do not name was dropped"
        );
        assert_eq!(
            members(Some(" lead,x")),
            [" lead", "x"],
            "a member's spaces are its own"
        );
        assert!(members(Some("")).is_empty());
    }
}
