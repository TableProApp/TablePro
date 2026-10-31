//! The Character Set and Collation rows of a table and of its text
//! columns: searchable lists of what the server offers, where the
//! collations follow the character set picked.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::column::ColumnKind;
use tablepro_core::ddl::{CharacterSet, DraftColumn};
use tablepro_core::dialect::SqlDialect;

use super::context::CharacterSets;
use crate::i18n::{gettext, gettext_f};

/// One entry of a row: the name it writes, `None` for the table's
/// default, and what the list shows for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Choice {
    pub(super) value: Option<String>,
    pub(super) label: String,
}

impl Choice {
    fn named(name: &str) -> Self {
        Self {
            value: Some(name.to_owned()),
            label: name.to_owned(),
        }
    }

    fn table_default() -> Self {
        Self {
            value: None,
            label: gettext("Table default"),
        }
    }
}

/// A combo row whose entries stand for names. Filling it is no pick.
#[derive(Clone)]
pub(super) struct ChoiceRow {
    row: glib::WeakRef<adw::ComboRow>,
    choices: Rc<RefCell<Vec<Choice>>>,
    filling: Rc<Cell<bool>>,
}

impl ChoiceRow {
    pub(super) fn new(row: &adw::ComboRow, on_pick: impl Fn(Option<String>) + 'static) -> Self {
        row.set_enable_search(true);
        row.set_search_match_mode(gtk::StringFilterMatchMode::Substring);
        row.set_expression(Some(&gtk::PropertyExpression::new(
            gtk::StringObject::static_type(),
            None::<&gtk::Expression>,
            "string",
        )));
        // Collation names run long, and an ellipsis would hide the part
        // that tells them apart.
        crate::ui::combo_value::show_whole_value(row);
        let choices: Rc<RefCell<Vec<Choice>>> = Rc::default();
        let filling = Rc::new(Cell::new(false));
        let (listed, quiet) = (choices.clone(), filling.clone());
        row.connect_selected_notify(move |row| {
            if quiet.get() {
                return;
            }
            let picked = usize::try_from(row.selected())
                .ok()
                .and_then(|position| listed.borrow().get(position).map(|choice| choice.value.clone()));
            if let Some(value) = picked {
                on_pick(value);
            }
        });
        Self {
            row: row.downgrade(),
            choices,
            filling,
        }
    }

    /// List `choices` with the one that writes `selected` picked. The
    /// list is replaced only when it changed, since this also puts back
    /// a pick the tab refused, from inside that pick's own signal.
    pub(super) fn show(&self, choices: &[Choice], selected: Option<&str>) {
        let Some(row) = self.row.upgrade() else {
            return;
        };
        let position = choices
            .iter()
            .position(|choice| choice.value.as_deref() == selected)
            .and_then(|position| u32::try_from(position).ok())
            .unwrap_or(gtk::INVALID_LIST_POSITION);
        self.filling.set(true);
        if *self.choices.borrow() != choices {
            self.choices.replace(choices.to_vec());
            let labels: Vec<&str> = choices.iter().map(|choice| choice.label.as_str()).collect();
            row.set_model(Some(&gtk::StringList::new(&labels)));
        }
        row.set_selected(position);
        self.filling.set(false);
    }
}

/// A row is off until the server's character sets are read, and says
/// why when they could not be.
pub(super) fn follow_catalog(row: &adw::ComboRow, character_sets: &CharacterSets) {
    let reason = matches!(character_sets, CharacterSets::Unreadable)
        .then(|| gettext("The server's character sets couldn't be read."));
    row.set_sensitive(matches!(character_sets, CharacterSets::Read(_)));
    row.set_tooltip_text(reason.as_deref());
    let widget = row.upcast_ref::<gtk::Widget>();
    match reason.as_deref() {
        Some(text) => widget.update_property(&[gtk::accessible::Property::Description(text)]),
        None => widget.reset_property(gtk::AccessibleProperty::Description),
    }
}

/// The character sets the server offers, and the one the row holds when
/// the server does not list it, so the row never shows a value it
/// cannot write back. `table_default` adds the entry that names none.
pub(super) fn character_set_choices(
    catalog: &[CharacterSet],
    current: Option<&str>,
    table_default: bool,
) -> Vec<Choice> {
    let mut choices: Vec<Choice> = table_default.then(Choice::table_default).into_iter().collect();
    if let Some(current) = current
        && !catalog.iter().any(|set| set.name == current)
    {
        choices.push(Choice::named(current));
    }
    choices.extend(catalog.iter().map(|set| Choice::named(&set.name)));
    choices
}

/// The collations of `character_set`, its default one marked, and the
/// one the row holds when the server does not list it. A column that
/// names no character set takes the table's collation too.
pub(super) fn collation_choices(
    catalog: &[CharacterSet],
    character_set: Option<&str>,
    current: Option<&str>,
) -> Vec<Choice> {
    let Some(character_set) = character_set else {
        return vec![Choice::table_default()];
    };
    let mut choices: Vec<Choice> = Vec::new();
    if let Some(current) = current
        && !collations_of(catalog, character_set).any(|collation| collation == current)
    {
        choices.push(Choice::named(current));
    }
    let default = default_collation(catalog, character_set);
    choices.extend(collations_of(catalog, character_set).map(|collation| Choice {
        value: Some(collation.to_owned()),
        label: match default.as_deref() == Some(collation) {
            true => gettext_f("{collation} (default)", &[("collation", collation)]),
            false => collation.to_owned(),
        },
    }));
    choices
}

fn collations_of<'a>(catalog: &'a [CharacterSet], character_set: &str) -> impl Iterator<Item = &'a str> {
    catalog
        .iter()
        .filter(move |set| set.name == character_set)
        .flat_map(|set| set.collations.iter().map(String::as_str))
}

/// The collation a character set takes when it is named alone.
pub(super) fn default_collation(catalog: &[CharacterSet], character_set: &str) -> Option<String> {
    catalog
        .iter()
        .find(|set| set.name == character_set)
        .map(|set| set.default_collation.clone())
}

/// Whether the column's type holds text, the only kind a character set
/// applies to.
pub(super) fn takes_character_set(dialect: Option<&dyn SqlDialect>, column: &DraftColumn) -> bool {
    let Some(dialect) = dialect else {
        return false;
    };
    column
        .column_type
        .column_type(dialect, &column.name)
        .is_ok_and(|column_type| matches!(column_type.kind, ColumnKind::Text { .. } | ColumnKind::Enum { .. }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog() -> Vec<CharacterSet> {
        vec![CharacterSet {
            name: "latin1".to_owned(),
            default_collation: "latin1_swedish_ci".to_owned(),
            collations: vec!["latin1_bin".to_owned(), "latin1_swedish_ci".to_owned()],
        }]
    }

    fn values(choices: &[Choice]) -> Vec<Option<&str>> {
        choices.iter().map(|choice| choice.value.as_deref()).collect()
    }

    #[test]
    fn a_character_set_the_server_does_not_list_stays_a_choice() {
        let choices = character_set_choices(&catalog(), Some("utf8mb4"), true);

        assert_eq!(values(&choices), [None, Some("utf8mb4"), Some("latin1")]);
        assert_eq!(choices[0].label, "Table default");
    }

    #[test]
    fn collations_follow_their_character_set_with_the_default_marked() {
        let labels: Vec<String> = collation_choices(&catalog(), Some("latin1"), Some("latin1_bin"))
            .into_iter()
            .map(|choice| choice.label)
            .collect();

        assert_eq!(labels, ["latin1_bin", "latin1_swedish_ci (default)"]);
        assert_eq!(
            values(&collation_choices(
                &catalog(),
                Some("latin1"),
                Some("latin1_german1_ci")
            )),
            [Some("latin1_german1_ci"), Some("latin1_bin"), Some("latin1_swedish_ci")]
        );
        assert_eq!(values(&collation_choices(&catalog(), None, None)), [None]);
        assert_eq!(
            default_collation(&catalog(), "latin1").as_deref(),
            Some("latin1_swedish_ci")
        );
    }
}
