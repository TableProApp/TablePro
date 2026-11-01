//! The Options page: the table's default character set and collation,
//! whether a change of them converts the columns as well, and the value
//! the next numbered row takes.

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_core::ddl::{CharacterSet, DraftTableOptions};

use super::character_set_choices::{
    ChoiceRow, character_set_choices, collation_choices, default_collation, follow_catalog,
};
use super::columns::mark_invalid;
use super::draft_column_object::DraftColumnObject;
use super::{StructureEffects, StructureMode, StructureModel, StructureTab, TableInput, items};

pub(super) struct TableOptionsWidgets {
    pub(super) page: adw::ViewStackPage,
    /// Holds every control, so a save turns them all off at once.
    pub(super) controls: gtk::Box,
    pub(super) character_set_row: adw::ComboRow,
    pub(super) character_set: ChoiceRow,
    pub(super) collation_row: adw::ComboRow,
    pub(super) collation: ChoiceRow,
    pub(super) convert: adw::SwitchRow,
    /// Blocked while the tab writes the draft's value into the switch.
    pub(super) convert_toggled: glib::SignalHandlerId,
    pub(super) auto_increment_group: adw::PreferencesGroup,
    pub(super) auto_increment: adw::EntryRow,
    /// Blocked while the tab writes the draft's value into the field.
    pub(super) auto_increment_changed: glib::SignalHandlerId,
}

/// The Next Auto Increment field as the user typed it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct NextAutoIncrement {
    pub(super) text: String,
    /// Why `text` is no value the numbered column takes. The draft keeps
    /// the table's own value, and Save waits until the text is one.
    pub(super) error: Option<String>,
}

impl NextAutoIncrement {
    pub(super) fn showing(options: Option<&DraftTableOptions>) -> Self {
        Self::of(options.and_then(|options| options.next_auto_increment))
    }

    fn of(value: Option<u64>) -> Self {
        Self {
            text: value.map(|value| value.to_string()).unwrap_or_default(),
            error: None,
        }
    }
}

/// The page's controls, each sending its edit.
pub(super) fn build(tab: &StructureTab) -> TableOptionsWidgets {
    let imp = tab.imp();
    let sender = tab.sender();
    let character_set = ChoiceRow::new(&imp.character_set_row, move |picked| {
        if let Some(name) = picked {
            sender.input(TableInput::CharacterSetPicked(name));
        }
    });
    let sender = tab.sender();
    let collation = ChoiceRow::new(&imp.collation_row, move |picked| {
        if let Some(name) = picked {
            sender.input(TableInput::CollationPicked(name));
        }
    });
    let sender = tab.sender();
    let convert_toggled = imp
        .convert_row
        .connect_active_notify(move |row| sender.input(TableInput::ConvertColumnsToggled(row.is_active())));
    let sender = tab.sender();
    let auto_increment_changed = imp.auto_increment_row.connect_changed(move |entry| {
        sender.input(TableInput::NextAutoIncrementEdited(entry.text().to_string()));
    });
    TableOptionsWidgets {
        page: imp.options_page.get(),
        controls: imp.options_box.get(),
        character_set_row: imp.character_set_row.get(),
        character_set,
        collation_row: imp.collation_row.get(),
        collation,
        convert: imp.convert_row.get(),
        convert_toggled,
        auto_increment_group: imp.auto_increment_group.get(),
        auto_increment: imp.auto_increment_row.get(),
        auto_increment_changed,
    }
}

/// `None` for an empty field, which leaves the value as it is.
fn parse_next_auto_increment(text: &str, maximum: u64, original: Option<u64>) -> Result<Option<u64>, String> {
    let text = text.trim();
    if text.is_empty() {
        return Ok(None);
    }
    match text.parse::<u64>() {
        // An exhausted counter sits one past the column's type; the server's own value is never the user's error.
        Ok(value) if Some(value) == original || (1..=maximum).contains(&value) => Ok(Some(value)),
        _ => Err(crate::i18n::gettext_f(
            "Enter a whole number from 1 to {maximum}.",
            &[("maximum", &maximum.to_string())],
        )),
    }
}

impl StructureModel {
    /// A character set picked for the table takes its default collation,
    /// as the server would give it one named alone.
    pub(super) fn pick_table_character_set(&mut self, name: String, fx: &mut StructureEffects) {
        let catalog = self.context.borrow().character_set_catalog();
        let Some(options) = self.options.as_mut() else {
            return;
        };
        if let Some(collation) = default_collation(&catalog, &name) {
            options.collation = Some(collation);
        }
        options.character_set = Some(name);
        self.show_table_collations(&catalog);
        self.recompute_dirty_state(fx);
    }

    pub(super) fn edit_table_options(&mut self, fx: &mut StructureEffects, edit: impl FnOnce(&mut DraftTableOptions)) {
        let Some(options) = self.options.as_mut() else {
            return;
        };
        edit(options);
        self.recompute_dirty_state(fx);
    }

    /// Put the draft's options in the page, which is no edit. The page
    /// shows only where the engine changes a table's options.
    pub(super) fn show_table_options(&self) {
        let widgets = &self.widgets.options;
        let context = self.context.borrow();
        let offered = context.mode == StructureMode::Edit && context.capabilities().table_options;
        widgets.page.set_visible(offered && self.options.is_some());
        let Some(options) = &self.options else {
            return;
        };
        let catalog = context.character_set_catalog();
        widgets.character_set.show(
            &character_set_choices(&catalog, options.character_set.as_deref(), false),
            options.character_set.as_deref(),
        );
        self.show_table_collations(&catalog);
        for row in [&widgets.character_set_row, &widgets.collation_row] {
            follow_catalog(row, &context.character_sets);
        }
        widgets.convert.block_signal(&widgets.convert_toggled);
        widgets.convert.set_active(options.converts_columns);
        widgets.convert.unblock_signal(&widgets.convert_toggled);
        self.show_next_auto_increment(self.numbered_column_maximum().is_some());
    }

    fn show_table_collations(&self, catalog: &[CharacterSet]) {
        let Some(options) = &self.options else {
            return;
        };
        self.widgets.options.collation.show(
            &collation_choices(catalog, options.character_set.as_deref(), options.collation.as_deref()),
            options.collation.as_deref(),
        );
    }

    /// Read the Next Auto Increment text against the column that numbers
    /// itself now: a type change moves the range it takes. Without such
    /// a column the field goes, and the value with it.
    pub(super) fn sync_next_auto_increment(&mut self) {
        if self.options.is_none() {
            return;
        }
        let maximum = self.numbered_column_maximum();
        let original = self
            .context
            .borrow()
            .original()
            .and_then(|definition| definition.options.as_ref())
            .and_then(|options| options.next_auto_increment);
        let Some(options) = self.options.as_mut() else {
            return;
        };
        match maximum {
            Some(maximum) => match parse_next_auto_increment(&self.next_auto_increment.text, maximum, original) {
                Ok(value) => {
                    options.next_auto_increment = value.or(original);
                    self.next_auto_increment.error = None;
                }
                Err(error) => {
                    options.next_auto_increment = original;
                    self.next_auto_increment.error = Some(error);
                }
            },
            None => {
                options.next_auto_increment = original;
                self.next_auto_increment = NextAutoIncrement::of(original);
            }
        }
        self.show_next_auto_increment(maximum.is_some());
    }

    /// `shown` while a column of the draft numbers itself.
    fn show_next_auto_increment(&self, shown: bool) {
        let widgets = &self.widgets.options;
        widgets.auto_increment_group.set_visible(shown);
        if widgets.auto_increment.text() != self.next_auto_increment.text {
            widgets.auto_increment.block_signal(&widgets.auto_increment_changed);
            widgets.auto_increment.set_text(&self.next_auto_increment.text);
            widgets.auto_increment.unblock_signal(&widgets.auto_increment_changed);
        }
        mark_invalid(&widgets.auto_increment, self.next_auto_increment.error.as_deref());
    }

    /// The largest counter of the draft's AUTO_INCREMENT column, `None`
    /// while no column numbers itself.
    fn numbered_column_maximum(&self) -> Option<u64> {
        let column = items::<DraftColumnObject>(&self.columns)
            .iter()
            .map(DraftColumnObject::column)
            .find(|column| column.auto_increment)?;
        Some(self.context.borrow().auto_increment_maximum(&column))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_next_auto_increment_is_a_whole_number_inside_the_column_range() {
        assert_eq!(parse_next_auto_increment(" 42 ", 127, None), Ok(Some(42)));
        assert_eq!(parse_next_auto_increment("", 127, None), Ok(None));
        assert_eq!(parse_next_auto_increment("127", 127, None), Ok(Some(127)));
        for refused in ["0", "128", "-1", "1.5", "ten", "99999999999999999999999"] {
            assert_eq!(
                parse_next_auto_increment(refused, 127, None),
                Err("Enter a whole number from 1 to 127.".to_owned()),
                "{refused}"
            );
        }
    }

    #[test]
    fn an_exhausted_counter_the_server_reports_stands_until_edited() {
        assert_eq!(parse_next_auto_increment("128", 127, Some(128)), Ok(Some(128)));
        assert_eq!(
            parse_next_auto_increment("129", 127, Some(128)),
            Err("Enter a whole number from 1 to 127.".to_owned())
        );
    }
}
