// The keys in force: ACCELERATORS with the chosen preset's Linux rows applied by core ADR 0057's rule.

use std::cell::{OnceCell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use gio::prelude::SettingsExtManual;
use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, glib};
use libadwaita as adw;
use libadwaita::prelude::ComboRowExt;
use tablepro_core::keymap::{self, Chord, KeymapAction, Platform, ResolvedBinding};
use tablepro_linux_platform::settings::keys;

use super::{ACCELERATORS, Accelerator, AcceleratorScope, ShortcutOwner};
use crate::i18n::gettext;

pub(crate) const TABLEPRO: &str = "tablepro";

// The name GTK gives the controller that runs a widget class's key bindings.
pub(crate) const CLASS_SHORTCUTS: &str = "gtk-widget-class-shortcuts";

// The command whose key a menu item shows, which a preset change reads again; not always the item's own action.
const KEY_OF: &str = "tablepro-key-of";

pub(crate) type Keystroke = (gdk::Key, gdk::ModifierType);

// The keys the HIG keeps for the system, which no preset takes.
const GNOME_RESERVED: [&str; 13] = [
    "<Alt>Tab",
    "<Alt>F4",
    "<Alt>F5",
    "<Alt>F6",
    "<Alt>F7",
    "<Alt>F8",
    "<Alt>space",
    "<Primary><Alt>Tab",
    "<Primary><Alt>Delete",
    "<Primary><Alt>Up",
    "<Primary><Alt>Down",
    "<Primary><Alt>Left",
    "<Primary><Alt>Right",
];

// Commands whose keys are the platform's or the toolkit's own: quit, zoom, copy and paste, and the editor's cursors.
const HOLDERS: [&str; 12] = [
    "app.quit",
    "diagram.zoom-in",
    "diagram.zoom-out",
    "diagram.zoom-reset",
    "grid.copy",
    "grid.paste",
    "editor.add-cursor-next-match",
    "editor.add-cursors-all-matches",
    "editor.add-cursor-above",
    "editor.add-cursor-below",
    "editor.single-cursor",
    "editor.toggle-cursor",
];

// The owners a key pressed in the SQL editor meets: its view, the editor tab and the shell around it.
const AROUND_THE_EDITOR: [ShortcutOwner; 4] = [
    ShortcutOwner::SqlEditor,
    ShortcutOwner::SqlEditorCursors,
    ShortcutOwner::SqlEditorTab,
    ShortcutOwner::WorkspaceShell,
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct EffectiveAccelerator {
    pub action: &'static str,
    pub triggers: Vec<String>,
    pub scope: AcceleratorScope,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct EffectiveTable {
    entries: Vec<EffectiveAccelerator>,
    #[cfg(test)]
    displaced: Vec<&'static str>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Refusal {
    StockAction,
    Super,
    AltWithLetter,
    BareKey,
    Reserved,
    Held(&'static str),
    EditorKey,
}

impl EffectiveTable {
    pub(crate) fn defaults() -> Self {
        Self {
            entries: ACCELERATORS
                .iter()
                .map(|entry| EffectiveAccelerator {
                    action: entry.action,
                    triggers: entry.triggers.iter().map(|accel| (*accel).to_owned()).collect(),
                    scope: entry.scope,
                })
                .collect(),
            #[cfg(test)]
            displaced: Vec::new(),
        }
    }

    pub(crate) fn for_preset(id: &str) -> Self {
        if id == TABLEPRO {
            return Self::defaults();
        }
        match keymap::preset(id, Platform::Linux) {
            Ok(bindings) => Self::with_bindings(&bindings),
            Err(error) => {
                tracing::warn!(
                    preset = id,
                    code = error.code(),
                    %error,
                    "the shortcut preset was not read, so TablePro's keys apply"
                );
                Self::defaults()
            }
        }
    }

    // A preset row wins, except where Linux refuses it; a bare-key default keeps its key beside the chord.
    fn with_bindings(bindings: &[ResolvedBinding]) -> Self {
        let mut table = Self::defaults();
        let mut set_by_preset = vec![false; ACCELERATORS.len()];
        let mut claimed: Vec<(usize, Keystroke)> = Vec::new();
        for binding in bindings {
            let Some(accel) = gtk_accelerator(&binding.chord) else {
                tracing::debug!(chord = %binding.chord, "a preset key has no GTK name");
                continue;
            };
            let Some(wanted) = keystroke(&accel) else {
                continue;
            };
            for name in linux_actions(binding.action) {
                let Some(index) = ACCELERATORS.iter().position(|entry| entry.action == *name) else {
                    continue;
                };
                let entry = &ACCELERATORS[index];
                if let Some(refusal) = refusal(entry, &binding.chord, wanted) {
                    tracing::debug!(
                        action = entry.action,
                        chord = %binding.chord,
                        ?refusal,
                        "a preset key Linux refuses"
                    );
                    continue;
                }
                if entry.triggers.iter().any(|accel| keystroke(accel) == Some(wanted)) {
                    continue;
                }
                let mut triggers: Vec<String> = if set_by_preset[index] {
                    table.entries[index].triggers.clone()
                } else {
                    entry
                        .triggers
                        .iter()
                        .filter(|accel| is_bare(accel))
                        .map(|accel| (*accel).to_owned())
                        .collect()
                };
                triggers.push(accel.clone());
                table.entries[index].triggers = triggers;
                set_by_preset[index] = true;
                claimed.push((index, wanted));
            }
        }
        for (index, entry) in ACCELERATORS.iter().enumerate() {
            if set_by_preset[index] || entry.scope == AcceleratorScope::Stock {
                continue;
            }
            let triggers = &mut table.entries[index].triggers;
            #[cfg(test)]
            let before = triggers.len();
            triggers.retain(|accel| {
                keystroke(accel).is_none_or(|key| {
                    !claimed
                        .iter()
                        .any(|(by, taken)| *taken == key && meet(&ACCELERATORS[*by], entry))
                })
            });
            #[cfg(test)]
            if triggers.len() != before {
                table.displaced.push(entry.action);
            }
        }
        table
    }

    pub(crate) fn entries(&self) -> &[EffectiveAccelerator] {
        &self.entries
    }

    pub(crate) fn triggers_for(&self, action: &str) -> &[String] {
        self.entries
            .iter()
            .find(|entry| entry.action == action)
            .map_or(&[], |entry| entry.triggers.as_slice())
    }

    // GtkPopoverMenu shows an application key by itself, so a menu item puts only a Local or Component one on.
    fn shows_own_key(&self, action: &str) -> bool {
        self.entries.iter().any(|entry| {
            entry.action == action
                && matches!(
                    entry.scope,
                    AcceleratorScope::Local { .. } | AcceleratorScope::Component(_)
                )
        })
    }

    #[cfg(test)]
    pub(crate) fn displaced(&self) -> Vec<&'static str> {
        self.displaced.clone()
    }

    fn shortcuts_of(&self, owner: ShortcutOwner) -> Vec<gtk::Shortcut> {
        self.entries
            .iter()
            .filter(|entry| matches!(entry.scope, AcceleratorScope::Local { owner: of, .. } if of == owner))
            .flat_map(|entry| {
                entry.triggers.iter().filter_map(move |accel| {
                    super::accelerators::shortcut_trigger(&[accel.as_str()])
                        .map(|trigger| gtk::Shortcut::new(Some(trigger), Some(gtk::NamedAction::new(entry.action))))
                })
            })
            .collect()
    }
}

// Two entries meet where one key could reach both: in one owner, or anywhere for a key the window takes first.
fn meet(first: &Accelerator, second: &Accelerator) -> bool {
    let owner = |entry: &Accelerator| match entry.scope {
        AcceleratorScope::Local { owner, .. } | AcceleratorScope::Component(owner) => Some(owner),
        AcceleratorScope::Application | AcceleratorScope::Stock => None,
    };
    reaches_window_first(first)
        || reaches_window_first(second)
        || owner(first).is_some_and(|of| owner(second) == Some(of))
}

fn reaches_window_first(entry: &Accelerator) -> bool {
    entry.scope == AcceleratorScope::Application || entry.action.starts_with("tab-view.")
}

fn refusal(target: &Accelerator, chord: &Chord, wanted: Keystroke) -> Option<Refusal> {
    if target.scope == AcceleratorScope::Stock {
        return Some(Refusal::StockAction);
    }
    if chord.cmd {
        return Some(Refusal::Super);
    }
    let alphanumeric = chord.key.len() == 1 && chord.key.chars().all(|key| key.is_ascii_alphanumeric());
    if chord.alt && !chord.ctrl && alphanumeric {
        return Some(Refusal::AltWithLetter);
    }
    if !chord.ctrl && !chord.alt && !chord.is_function_key() {
        return Some(Refusal::BareKey);
    }
    if GNOME_RESERVED.iter().any(|accel| keystroke(accel) == Some(wanted)) {
        return Some(Refusal::Reserved);
    }
    let held = ACCELERATORS
        .iter()
        .filter(|entry| {
            entry.scope == AcceleratorScope::Stock || (HOLDERS.contains(&entry.action) && meet(entry, target))
        })
        .find(|entry| entry.triggers.iter().any(|accel| keystroke(accel) == Some(wanted)))
        .map(|entry| Refusal::Held(entry.action));
    // Core ADR 0057: the editor keeps its own key, which the command would take from it or never see.
    held.or_else(|| (meets_the_editor(target) && editor_binds(wanted)).then_some(Refusal::EditorKey))
}

// In the SQL editor the window's keys and the view's own run before its bindings, the tab's and the shell's after.
fn meets_the_editor(entry: &Accelerator) -> bool {
    reaches_window_first(entry)
        || matches!(
            entry.scope,
            AcceleratorScope::Local { owner, .. } | AcceleratorScope::Component(owner)
                if AROUND_THE_EDITOR.contains(&owner)
        )
}

thread_local! {
    static EDITOR_VIEW_KEYS: OnceCell<HashSet<Keystroke>> = const { OnceCell::new() };
}

fn editor_binds(wanted: Keystroke) -> bool {
    EDITOR_VIEW_KEYS.with(|keys| keys.get_or_init(editor_view_keys).contains(&wanted))
}

// GTK lists a class's key bindings only on a widget, so a view is made to read GtkTextView's and GtkSourceView's.
pub(crate) fn editor_view_keys() -> HashSet<Keystroke> {
    let view = sourceview5::View::new();
    let controllers = view.observe_controllers();
    let keys = (0..controllers.n_items())
        .filter_map(|at| controllers.item(at).and_downcast::<gtk::ShortcutController>())
        .filter(|controller| controller.name().is_some_and(|name| name == CLASS_SHORTCUTS))
        .flat_map(|controller| {
            (0..controller.n_items())
                .filter_map(|at| controller.item(at).and_downcast::<gtk::Shortcut>())
                .filter_map(|shortcut| shortcut.trigger())
                .flat_map(|trigger| keystrokes_of(&trigger))
                .collect::<Vec<_>>()
        })
        .collect();
    crate::ui::text_view_teardown::release(&view);
    keys
}

pub(crate) fn keystrokes_of(trigger: &gtk::ShortcutTrigger) -> Vec<Keystroke> {
    if let Some(keyval) = trigger.downcast_ref::<gtk::KeyvalTrigger>() {
        vec![(keyval.keyval().to_lower(), keyval.modifiers())]
    } else if let Some(pair) = trigger.downcast_ref::<gtk::AlternativeTrigger>() {
        let mut keys = keystrokes_of(&pair.first());
        keys.extend(keystrokes_of(&pair.second()));
        keys
    } else {
        Vec::new()
    }
}

fn is_bare(accel: &str) -> bool {
    keystroke(accel).is_some_and(|(key, modifiers)| {
        let function_key = (gdk::Key::F1..=gdk::Key::F35).contains(&key);
        !modifiers.intersects(gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::ALT_MASK) && !function_key
    })
}

fn keystroke(accel: &str) -> Option<Keystroke> {
    gtk::accelerator_parse(accel).map(|(key, modifiers)| (key.to_lower(), modifiers))
}

// The core writes keys by their VS Code names; GTK wants its keyval names.
pub(crate) fn gtk_accelerator(chord: &Chord) -> Option<String> {
    let key = match chord.key.as_str() {
        "`" => "grave".to_owned(),
        "-" => "minus".to_owned(),
        "=" => "equal".to_owned(),
        "[" => "bracketleft".to_owned(),
        "]" => "bracketright".to_owned(),
        "\\" => "backslash".to_owned(),
        ";" => "semicolon".to_owned(),
        "'" => "apostrophe".to_owned(),
        "," => "comma".to_owned(),
        "." => "period".to_owned(),
        "/" => "slash".to_owned(),
        "left" => "Left".to_owned(),
        "up" => "Up".to_owned(),
        "right" => "Right".to_owned(),
        "down" => "Down".to_owned(),
        "pageup" => "Page_Up".to_owned(),
        "pagedown" => "Page_Down".to_owned(),
        "home" => "Home".to_owned(),
        "end" => "End".to_owned(),
        "tab" => "Tab".to_owned(),
        "enter" => "Return".to_owned(),
        "escape" => "Escape".to_owned(),
        "space" => "space".to_owned(),
        "backspace" => "BackSpace".to_owned(),
        "delete" => "Delete".to_owned(),
        "insert" => "Insert".to_owned(),
        function if chord.is_function_key() => function.to_uppercase(),
        plain if plain.len() == 1 && plain.chars().all(|key| key.is_ascii_alphanumeric()) => plain.to_owned(),
        _ => return None,
    };
    let mut accel = String::new();
    for (held, modifier) in [
        (chord.ctrl, "<Primary>"),
        (chord.shift, "<Shift>"),
        (chord.alt, "<Alt>"),
    ] {
        if held {
            accel.push_str(modifier);
        }
    }
    accel.push_str(&key);
    Some(accel)
}

// One meaning of the shared file is several commands here, one per surface that has it.
pub(crate) fn linux_actions(action: KeymapAction) -> &'static [&'static str] {
    match action {
        KeymapAction::ExecuteQuery => &["editor.run-statement"],
        KeymapAction::ExecuteAllStatements => &["editor.run"],
        KeymapAction::ExplainQuery | KeymapAction::DiscardChanges => &[],
        KeymapAction::FormatQuery => &["editor.format"],
        KeymapAction::NewTab => &["win.new-editor-tab"],
        KeymapAction::CloseTab => &["win.close-current"],
        KeymapAction::ShowNextTab => &["tab-view.select-next"],
        KeymapAction::ShowPreviousTab => &["tab-view.select-previous"],
        KeymapAction::Refresh => &["win.refresh-page", "table.refresh", "diagram.refresh"],
        KeymapAction::NewConnection => &["win.new-connection"],
        KeymapAction::QuickSwitcher => &["win.quick-open"],
        KeymapAction::ToggleTableBrowser => &["win.show-sidebar"],
        KeymapAction::SaveChanges => &["table.save", "results.save", "structure.save"],
        KeymapAction::AddRow => &["grid.insert-row"],
        KeymapAction::Delete => &["grid.delete-rows"],
        KeymapAction::DuplicateRow => &["grid.duplicate-rows"],
        KeymapAction::ToggleFilters => &["browse.filter"],
        KeymapAction::Find => &["editor.find", "grid.find"],
        KeymapAction::FindAndReplace => &["editor.find-replace"],
        KeymapAction::ToggleHistory => &["win.show-history"],
        KeymapAction::CancelQuery => &["editor.cancel"],
        KeymapAction::CommitTransaction => &["editor.commit"],
        KeymapAction::ShowSettings => &["app.preferences"],
    }
}

thread_local! {
    static CURRENT: RefCell<Rc<EffectiveTable>> = RefCell::new(Rc::new(EffectiveTable::defaults()));
    // One store per owner, which every controller of that owner reads, so a change reaches widgets already built.
    static STORES: RefCell<HashMap<ShortcutOwner, gio::ListStore>> = RefCell::new(HashMap::new());
    // A menu keeps a copy of each item's attributes, so a change writes the keys again into every menu that shows one.
    static MENUS: RefCell<Vec<glib::WeakRef<gio::Menu>>> = const { RefCell::new(Vec::new()) };
    // The accessible nodes that announce a command's keys, one command each.
    static ANNOUNCED: RefCell<Vec<(glib::WeakRef<gtk::Accessible>, String)>> = const { RefCell::new(Vec::new()) };
}

pub(crate) fn current() -> Rc<EffectiveTable> {
    CURRENT.with(|current| current.borrow().clone())
}

pub(crate) fn owner_store(owner: ShortcutOwner) -> gio::ListStore {
    STORES.with(|stores| {
        stores
            .borrow_mut()
            .entry(owner)
            .or_insert_with(|| {
                let store = gio::ListStore::new::<gtk::Shortcut>();
                store.splice(0, 0, &current().shortcuts_of(owner));
                store
            })
            .clone()
    })
}

pub(crate) fn follow(app: &adw::Application, settings: &gio::Settings) {
    apply(app, &settings.string(keys::SHORTCUT_PRESET));
    let app = app.downgrade();
    let _ = settings.connect_changed(Some(keys::SHORTCUT_PRESET), move |settings, key| {
        if let Some(app) = app.upgrade() {
            apply(&app, &settings.string(key));
        }
    });
}

pub(crate) fn apply(app: &impl IsA<gtk::Application>, preset: &str) {
    let table = Rc::new(EffectiveTable::for_preset(preset));
    install_application_keys(app, &table);
    show(table);
}

// What was built before the change reads the new table: the controllers' stores, the menus and the accessible nodes.
fn show(table: Rc<EffectiveTable>) {
    CURRENT.with(|current| current.replace(table.clone()));
    STORES.with(|stores| {
        for (owner, store) in stores.borrow().iter() {
            store.splice(0, store.n_items(), &table.shortcuts_of(*owner));
        }
    });
    let menus: Vec<gio::Menu> = MENUS.with(|menus| {
        let mut menus = menus.borrow_mut();
        menus.retain(|held| held.upgrade().is_some());
        menus.iter().filter_map(glib::WeakRef::upgrade).collect()
    });
    for menu in &menus {
        write_menu_keys(menu, &table);
    }
    let announced: Vec<(gtk::Accessible, String)> = ANNOUNCED.with(|announced| {
        let mut announced = announced.borrow_mut();
        announced.retain(|(held, _)| held.upgrade().is_some());
        announced
            .iter()
            .filter_map(|(held, action)| Some((held.upgrade()?, action.clone())))
            .collect()
    });
    for (accessible, action) in &announced {
        crate::ui::a11y::write_key_shortcuts(accessible, table.triggers_for(action));
    }
}

// Every menu whose items show a key goes through here, so the keys it shows stay the keys in force.
pub(crate) fn follow_menu(menu: &gio::Menu) {
    // A grid builds a header menu per column, and a menu no preset can give a key needs no following.
    if !write_menu_keys(menu, &current()) {
        return;
    }
    MENUS.with(|menus| {
        let mut menus = menus.borrow_mut();
        menus.retain(|held| held.upgrade().is_some_and(|held| held != *menu));
        menus.push(menu.downgrade());
    });
}

pub(crate) fn show_own_key(item: &gio::MenuItem, action: &str) {
    if current().shows_own_key(action) {
        show_key_of(item, action);
    }
}

pub(crate) fn show_key_of(item: &gio::MenuItem, action: &str) {
    item.set_attribute_value(KEY_OF, Some(&action.to_variant()));
    let table = current();
    let shown = table.triggers_for(action).first().map(|accel| accel.to_variant());
    item.set_attribute_value("accel", shown.as_ref());
}

// `None` leaves the node with no key, as Vim mode leaves the Stop button once Escape is its own.
pub(crate) fn follow_key_shortcuts(accessible: &gtk::Accessible, action: Option<&str>) {
    ANNOUNCED.with(|announced| {
        announced
            .borrow_mut()
            .retain(|(held, _)| held.upgrade().is_some_and(|held| held != *accessible));
    });
    let table = current();
    let none: &[String] = &[];
    crate::ui::a11y::write_key_shortcuts(accessible, action.map_or(none, |action| table.triggers_for(action)));
    if let Some(action) = action {
        ANNOUNCED.with(|announced| {
            announced.borrow_mut().push((accessible.downgrade(), action.to_owned()));
        });
    }
}

fn write_menu_keys(menu: &gio::Menu, table: &EffectiveTable) -> bool {
    let mut keyed = false;
    for position in 0..menu.n_items() {
        for link in ["section", "submenu"] {
            if let Some(inner) = menu.item_link(position, link).and_downcast::<gio::Menu>() {
                keyed |= write_menu_keys(&inner, table);
            }
        }
        let Some(source) = item_text(menu, position, KEY_OF) else {
            continue;
        };
        keyed = true;
        let wanted = table.triggers_for(&source).first();
        if item_text(menu, position, "accel").as_ref() == wanted || !menu.is_mutable() {
            continue;
        }
        // GMenu has no way to change one item's attribute, so the item goes back in its place with the new key.
        let item = gio::MenuItem::from_model(menu, position);
        item.set_attribute_value("accel", wanted.map(|accel| accel.to_variant()).as_ref());
        menu.remove(position);
        menu.insert_item(position, &item);
    }
    keyed
}

fn item_text(menu: &gio::Menu, position: i32, attribute: &str) -> Option<String> {
    menu.item_attribute_value(position, attribute, Some(glib::VariantTy::STRING))
        .and_then(|value| value.get::<String>())
}

// A test that applies a preset puts TablePro's keys back for the tests after it, on the same GTK thread.
#[cfg(test)]
pub(crate) struct BackToTablePro;

#[cfg(test)]
impl Drop for BackToTablePro {
    fn drop(&mut self) {
        show(Rc::new(EffectiveTable::defaults()));
    }
}

pub(crate) fn install_application_keys(app: &impl IsA<gtk::Application>, table: &EffectiveTable) {
    for entry in table
        .entries
        .iter()
        .filter(|entry| entry.scope == AcceleratorScope::Application)
    {
        let accels: Vec<&str> = entry.triggers.iter().map(String::as_str).collect();
        app.set_accels_for_action(entry.action, &accels);
    }
}

// The file lists a Local key as text, so the dialog built from it is given the keys in force.
pub(crate) fn fill_shortcuts_dialog(builder: &gtk::Builder) {
    let table = current();
    for entry in table.entries() {
        let id = entry.action.replace('.', "-");
        if let Some(item) = builder.object::<adw::ShortcutsItem>(&id) {
            if item.action_name().is_empty() {
                item.set_accelerator(&entry.triggers.join(" "));
            }
            continue;
        }
        let Some((section, title)) = keyless_listing(entry.action).filter(|_| !entry.triggers.is_empty()) else {
            continue;
        };
        if let Some(section) = builder.object::<adw::ShortcutsSection>(section) {
            section.add(adw::ShortcutsItem::new(&title, &entry.triggers.join(" ")));
        }
    }
}

// A command TablePro gives no key shows in the dialog only while a preset gives it one.
fn keyless_listing(action: &str) -> Option<(&'static str, String)> {
    match action {
        "win.new-connection" => Some(("section-general", gettext("New Connection"))),
        "grid.duplicate-rows" => Some(("section-data-grid", gettext("Duplicate Rows"))),
        "editor.commit" => Some(("section-sql-editor", gettext("Commit Transaction"))),
        _ => None,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PresetChoice {
    pub id: String,
    pub name: String,
}

// TablePro first, then the presets `first` names, then the rest in the file's order.
pub(crate) fn preset_choices(first: &[&str]) -> Vec<PresetChoice> {
    let presets = keymap::presets().unwrap_or_else(|error| {
        tracing::warn!(code = error.code(), %error, "the shortcut presets were not read");
        Vec::new()
    });
    let linux: Vec<PresetChoice> = presets
        .into_iter()
        .filter(|preset| preset.platforms.contains(&Platform::Linux))
        .map(|preset| PresetChoice {
            id: preset.id,
            name: preset.name,
        })
        .collect();
    let mut choices = vec![PresetChoice {
        id: TABLEPRO.to_owned(),
        name: "TablePro".to_owned(),
    }];
    for id in first {
        if let Some(choice) = linux.iter().find(|choice| choice.id == *id)
            && !choices.contains(choice)
        {
            choices.push(choice.clone());
        }
    }
    for choice in linux {
        if !choices.contains(&choice) {
            choices.push(choice);
        }
    }
    choices
}

pub(crate) fn bind_preset_row(row: &adw::ComboRow, settings: &gio::Settings, first: &[&str]) {
    let choices = preset_choices(first);
    let names: Vec<&str> = choices.iter().map(|choice| choice.name.as_str()).collect();
    // A new model moves the selection to its first row, which a binding still in place would write as the choice.
    gio::Settings::unbind(row, "selected");
    row.set_model(Some(&gtk::StringList::new(&names)));
    let ids: Vec<String> = choices.into_iter().map(|choice| choice.id).collect();
    let reading = ids.clone();
    settings
        .bind(keys::SHORTCUT_PRESET, row, "selected")
        .mapping(move |variant, _| {
            let id = variant.get::<String>()?;
            let index = reading.iter().position(|known| *known == id).unwrap_or(0);
            Some(u32::try_from(index).unwrap_or(0).to_value())
        })
        .set_mapping(move |value, _| {
            let index = usize::try_from(value.get::<u32>().ok()?).ok()?;
            Some(ids.get(index)?.to_variant())
        })
        .build();
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};

    use super::*;
    use crate::test_support::shortcut_keys::{
        Keystroke as Pressed, controller_keys, keystroke as pressed, keystrokes_with_twins, trigger_keys,
    };

    type Changed = Vec<(&'static str, Vec<String>)>;

    fn changed(table: &EffectiveTable) -> Changed {
        table
            .entries()
            .iter()
            .zip(ACCELERATORS)
            .filter(|(entry, default)| {
                entry
                    .triggers
                    .iter()
                    .map(String::as_str)
                    .ne(default.triggers.iter().copied())
            })
            .map(|(entry, _)| (entry.action, entry.triggers.clone()))
            .collect()
    }

    fn golden(rows: &[(&'static str, &[&str])]) -> Changed {
        rows.iter()
            .map(|(action, triggers)| (*action, triggers.iter().map(|accel| (*accel).to_owned()).collect()))
            .collect()
    }

    fn linux_presets() -> Vec<String> {
        keymap::preset_ids(Platform::Linux).expect("the core's presets")
    }

    #[gtk4::test]
    fn the_schema_offers_tablepro_and_every_linux_preset_of_the_core() {
        let settings = crate::test_support::MemorySettings::new();
        let schema = settings.get().gio().settings_schema().expect("the schema");
        let range = schema.key(keys::SHORTCUT_PRESET).range();

        assert_eq!(range.child_value(0).str(), Some("enum"));
        let choices = range
            .child_value(1)
            .as_variant()
            .and_then(|values| values.get::<Vec<String>>())
            .expect("the choices");
        let mut expected = vec![TABLEPRO.to_owned()];
        expected.extend(linux_presets());
        assert_eq!(choices, expected);
    }

    #[test]
    fn every_command_a_preset_names_is_in_the_table() {
        for action in KeymapAction::ALL {
            for name in linux_actions(action) {
                assert!(
                    ACCELERATORS.iter().any(|entry| entry.action == *name),
                    "{} maps to {name}, which the table lacks",
                    action.as_str()
                );
            }
        }
    }

    #[gtk4::test]
    fn every_key_of_every_linux_preset_has_a_gtk_name() {
        for id in linux_presets() {
            for binding in keymap::preset(&id, Platform::Linux).expect("the preset") {
                let accel = gtk_accelerator(&binding.chord).unwrap_or_else(|| panic!("{} in {id}", binding.chord));
                assert!(gtk::accelerator_parse(&accel).is_some(), "{accel} of {id}");
            }
        }
        let named = |text: &str| Chord::parse(text).ok().and_then(|chord| gtk_accelerator(&chord));
        assert_eq!(named("ctrl+shift+enter").as_deref(), Some("<Primary><Shift>Return"));
        assert_eq!(named("ctrl+]").as_deref(), Some("<Primary>bracketright"));
        assert_eq!(named("alt+insert").as_deref(), Some("<Alt>Insert"));
        assert_eq!(named("ctrl+f5").as_deref(), Some("<Primary>F5"));
        assert_eq!(named("ctrl+.").as_deref(), Some("<Primary>period"));
        assert_eq!(named("ctrl+alt+-").as_deref(), Some("<Primary><Alt>minus"));
    }

    #[gtk4::test]
    fn linux_refuses_what_gnome_or_gtk_keeps() {
        let entry = |action: &str| {
            ACCELERATORS
                .iter()
                .find(|entry| entry.action == action)
                .unwrap_or_else(|| panic!("{action}"))
        };
        let refused = |action: &str, chord: &str| {
            let chord = Chord::parse(chord).expect("a chord");
            let accel = gtk_accelerator(&chord).expect("a GTK name");
            refusal(entry(action), &chord, keystroke(&accel).expect("a key"))
        };

        assert_eq!(refused("win.show-sidebar", "alt+1"), Some(Refusal::AltWithLetter));
        assert_eq!(refused("win.show-sidebar", "alt+s"), Some(Refusal::AltWithLetter));
        assert_eq!(refused("tab-view.select-next", "ctrl+tab"), Some(Refusal::StockAction));
        assert_eq!(refused("win.quick-open", "f"), Some(Refusal::BareKey));
        assert_eq!(refused("win.quick-open", "alt+f4"), Some(Refusal::Reserved));
        assert_eq!(refused("win.new-editor-tab", "ctrl+q"), Some(Refusal::Held("app.quit")));
        assert_eq!(
            refused("win.show-sidebar", "ctrl+0"),
            Some(Refusal::Held("diagram.zoom-reset")),
            "a key the window takes first meets the diagram's zoom"
        );
        assert_eq!(
            refused("win.quick-open", "ctrl+a"),
            Some(Refusal::Held("list.select-all"))
        );
        assert_eq!(
            refused("grid.duplicate-rows", "ctrl+d"),
            None,
            "the grid and the editor's cursors never see one key"
        );
        assert_eq!(refused("editor.cancel", "ctrl+f2"), None);
        assert_eq!(refused("win.refresh-page", "ctrl+f5"), None);
    }

    #[gtk4::test]
    fn the_sql_editor_keeps_the_keys_its_view_binds() {
        let entry = |action: &str| {
            ACCELERATORS
                .iter()
                .find(|entry| entry.action == action)
                .unwrap_or_else(|| panic!("{action}"))
        };
        let refused = |action: &str, chord: &str| {
            let chord = Chord::parse(chord).expect("a chord");
            let accel = gtk_accelerator(&chord).expect("a GTK name");
            refusal(entry(action), &chord, keystroke(&accel).expect("a key"))
        };

        assert_eq!(
            refused("win.refresh-page", "ctrl+shift+backspace"),
            Some(Refusal::EditorKey),
            "the shell's key never gets past the view's own delete"
        );
        assert_eq!(
            refused("win.quick-open", "ctrl+space"),
            Some(Refusal::EditorKey),
            "the window's key takes completion from the editor"
        );
        assert_eq!(
            refused("editor.cancel", "ctrl+."),
            Some(Refusal::EditorKey),
            "GtkTextView opens its emoji chooser on Ctrl+."
        );
        assert_eq!(refused("editor.find-replace", "ctrl+alt+f"), None);
        assert_eq!(
            refused("grid.delete-rows", "ctrl+y"),
            None,
            "a key in the grid never reaches the editor"
        );
    }

    #[gtk4::test]
    fn tablepro_and_an_unknown_preset_keep_the_table() {
        assert_eq!(EffectiveTable::for_preset(TABLEPRO), EffectiveTable::defaults());
        assert_eq!(EffectiveTable::for_preset("not-a-preset"), EffectiveTable::defaults());
        assert!(EffectiveTable::defaults().displaced().is_empty());
    }

    #[gtk4::test]
    fn each_preset_moves_these_keys_and_displaces_these_commands() {
        let goldens: [(&str, Changed, &[&str]); 6] = [
            (
                "tableplus",
                golden(&[
                    ("win.new-connection", &["<Primary><Shift>k"]),
                    ("win.quick-open", &["<Primary>p"]),
                    ("win.new-editor-tab", &["<Primary>e"]),
                    ("win.switch-recent-tab", &[]),
                    ("grid.duplicate-rows", &["<Primary>d"]),
                    ("editor.run", &["<Primary><Shift>Return"]),
                    ("editor.run-statement", &["<Primary>Return"]),
                    ("editor.format", &["<Primary>i"]),
                    ("editor.find-replace", &["<Primary><Alt>f"]),
                ]),
                &["win.switch-recent-tab"],
            ),
            (
                "dbeaver",
                golden(&[
                    ("app.new-window", &[]),
                    ("win.new-connection", &["<Primary><Shift>n"]),
                    ("win.quick-open", &["<Primary><Shift>d"]),
                    ("win.new-editor-tab", &["<Primary>bracketright"]),
                    ("browse.filter", &["<Primary><Shift><Alt>t"]),
                    ("grid.insert-row", &["<Alt>Insert"]),
                    ("grid.duplicate-rows", &["<Primary><Alt>Insert"]),
                    ("grid.delete-rows", &["Delete", "<Alt>Delete"]),
                    ("editor.run", &["<Primary><Shift>Return"]),
                    ("editor.run-statement", &["<Primary>Return"]),
                ]),
                &["app.new-window"],
            ),
            (
                "datagrip",
                golden(&[
                    ("app.preferences", &["<Primary><Alt>s"]),
                    ("win.show-history", &["<Primary><Alt>e"]),
                    ("win.quick-open", &["<Primary>n"]),
                    ("win.new-editor-tab", &["<Primary><Shift>q"]),
                    ("win.close-current", &["<Primary>F4"]),
                    ("win.refresh-page", &["<Primary>F5"]),
                    ("browse.filter", &["<Primary><Shift><Alt>f"]),
                    ("table.refresh", &["<Primary>F5"]),
                    ("grid.insert-row", &["<Alt>Insert"]),
                    ("grid.duplicate-rows", &["<Primary>d"]),
                    ("grid.delete-rows", &["Delete", "<Primary>y"]),
                    ("editor.run", &["<Primary><Shift>Return"]),
                    ("editor.run-statement", &["<Primary>Return"]),
                    ("editor.cancel", &["Escape", "<Primary>F2"]),
                    ("editor.commit", &["<Primary><Shift><Alt>Return"]),
                    ("editor.format", &["<Primary><Alt>l"]),
                    ("editor.find-replace", &["<Primary>r"]),
                    ("diagram.refresh", &["<Primary>F5"]),
                ]),
                &[],
            ),
            (
                "beekeeperstudio",
                golden(&[
                    ("win.quick-open", &["<Primary>p"]),
                    ("grid.duplicate-rows", &["<Primary>d"]),
                    ("grid.delete-rows", &["Delete", "<Primary><Alt>minus"]),
                    ("editor.commit", &["<Primary><Shift>c"]),
                ]),
                &[],
            ),
            (
                "navicat",
                golden(&[
                    ("win.show-history", &["<Primary>l"]),
                    ("win.new-editor-tab", &[]),
                    ("editor.run", &["<Primary>r"]),
                    ("editor.run-statement", &["<Primary><Shift>r"]),
                    ("editor.cancel", &["Escape", "<Primary>t"]),
                ]),
                &["win.new-editor-tab"],
            ),
            (
                "dbx",
                golden(&[
                    ("win.new-connection", &["<Primary><Alt>c"]),
                    ("win.quick-open", &["<Primary>p"]),
                    ("win.show-sidebar", &["<Primary>b"]),
                    ("grid.duplicate-rows", &["<Primary>d"]),
                    ("editor.run", &["<Primary><Shift>Return"]),
                    ("editor.run-statement", &["<Primary>Return"]),
                    ("editor.find-replace", &["<Primary>r"]),
                ]),
                &[],
            ),
        ];
        let covered: Vec<String> = goldens.iter().map(|(id, _, _)| (*id).to_owned()).collect();
        assert_eq!(covered, linux_presets(), "a Linux preset has no golden");

        for (id, expected, displaced) in goldens {
            let table = EffectiveTable::for_preset(id);
            assert_eq!(changed(&table), expected, "{id}");
            assert_eq!(table.displaced(), displaced, "{id}");
        }
    }

    fn owner_of(entry: &EffectiveAccelerator) -> Option<ShortcutOwner> {
        match entry.scope {
            AcceleratorScope::Local { owner, .. } | AcceleratorScope::Component(owner) => Some(owner),
            AcceleratorScope::Application | AcceleratorScope::Stock => None,
        }
    }

    fn first_at_the_window(entry: &EffectiveAccelerator) -> bool {
        entry.scope == AcceleratorScope::Application || entry.action.starts_with("tab-view.")
    }

    // The accelerator table's own invariants, over the table each preset makes.
    #[gtk4::test]
    fn every_presets_table_keeps_the_tables_invariants() {
        let text_keys: HashSet<Pressed> = ["z", "y", "a", "c", "v", "x", "f", "g", "h", "slash"]
            .iter()
            .map(|key| pressed(&format!("<Primary>{key}")))
            .chain(["z", "g"].iter().map(|key| pressed(&format!("<Primary><Shift>{key}"))))
            .collect();
        let mut ids = vec![TABLEPRO.to_owned()];
        ids.extend(linux_presets());
        for id in ids {
            let table = EffectiveTable::for_preset(&id);
            let first: HashSet<Pressed> = table
                .entries()
                .iter()
                .filter(|entry| first_at_the_window(entry))
                .flat_map(|entry| entry.triggers.iter().map(|accel| pressed(accel)))
                .collect();
            let mut seen: HashMap<(Option<ShortcutOwner>, Pressed), &str> = HashMap::new();
            for entry in table.entries() {
                let owner = owner_of(entry);
                for accel in &entry.triggers {
                    if entry.scope == AcceleratorScope::Application {
                        assert!(
                            !text_keys.contains(&pressed(accel)),
                            "{id}: {} takes {accel}",
                            entry.action
                        );
                    }
                    for key in keystrokes_with_twins(accel) {
                        if owner.is_some() {
                            assert!(
                                !first.contains(&key),
                                "{id}: {accel} of {} is taken first",
                                entry.action
                            );
                        }
                        if (owner.is_some() || first_at_the_window(entry))
                            && let Some(other) = seen.insert((owner, key), entry.action)
                        {
                            panic!("{id}: {accel} is both {other} and {}", entry.action);
                        }
                    }
                }
            }
        }
    }

    #[gtk4::test]
    fn choosing_a_preset_moves_keys_in_place_and_back() {
        let _back = BackToTablePro;
        let app = gtk::Application::builder().build();
        let editor = super::super::local_shortcut_controller(ShortcutOwner::SqlEditor);
        assert!(!controller_keys(&editor).contains(&pressed("<Primary>t")));

        apply(&app, "navicat");

        let installed = |action: &str| -> Vec<Pressed> {
            app.accels_for_action(action)
                .iter()
                .map(|accel| pressed(accel))
                .collect()
        };
        assert!(
            installed("win.new-editor-tab").is_empty(),
            "the displaced command kept its key"
        );
        assert_eq!(installed("win.show-history"), [pressed("<Primary>l")]);
        assert!(
            controller_keys(&editor).contains(&pressed("<Primary>t")),
            "a controller built before the change missed it"
        );
        let kept: HashSet<Pressed> = trigger_keys(&super::super::editor_kept_keys().expect("the editor's keys"))
            .into_iter()
            .collect();
        assert!(
            kept.contains(&pressed("<Primary>t")),
            "Vim takes the preset's key from the editor"
        );

        apply(&app, TABLEPRO);

        assert_eq!(installed("win.new-editor-tab"), [pressed("<Primary>t")]);
        assert!(!controller_keys(&editor).contains(&pressed("<Primary>t")));
    }

    #[test]
    fn the_imported_apps_preset_is_listed_after_tablepro() {
        let ids = |choices: Vec<PresetChoice>| -> Vec<String> { choices.into_iter().map(|choice| choice.id).collect() };
        let plain = ids(preset_choices(&[]));
        let mut expected = vec![TABLEPRO.to_owned()];
        expected.extend(linux_presets());
        assert_eq!(plain, expected);

        let first = ids(preset_choices(&["dbx", "sequelace"]));
        assert_eq!(first[..2], [TABLEPRO.to_owned(), "dbx".to_owned()]);
        assert_eq!(first.len(), plain.len(), "a preset Linux lacks was listed");
    }
}
