use gtk4 as gtk;
use gtk4::gdk;
use gtk4::prelude::*;

use super::{Accelerator, AcceleratorScope, ShortcutListing, ShortcutOwner, ShortcutSection};

use AcceleratorScope::{Application, Component, Local, Stock};
use ShortcutListing::{Listed, Unlisted};
use ShortcutOwner::{
    AssistantComposer, BrowseGrid, BrowseTab, CellEditor, DiagramCanvas, DiagramTab, FilterStrip, GridCell, HistoryRow,
    InlineSuggestion, PickerPage, PickerRow, SidebarList, SqlEditor, SqlEditorCursors, SqlEditorTab, StructureTab,
};
use ShortcutSection::{BrowseTable, DataGrid, ErDiagram, General, TableStructure, Tabs};

const BUBBLE: gtk::PropagationPhase = gtk::PropagationPhase::Bubble;
/// GtkTextView binds Ctrl+/ to select-all, and a bubble controller on
/// the view runs before that binding only while it was added last.
/// Capture runs before every controller the view has.
const CAPTURE: gtk::PropagationPhase = gtk::PropagationPhase::Capture;

const fn application(action: &'static str, triggers: &'static [&'static str], section: ShortcutSection) -> Accelerator {
    Accelerator {
        action,
        triggers,
        scope: Application,
        listing: Listed(section),
    }
}

const fn stock(action: &'static str, triggers: &'static [&'static str], listing: ShortcutListing) -> Accelerator {
    Accelerator {
        action,
        triggers,
        scope: Stock,
        listing,
    }
}

const fn local(
    owner: ShortcutOwner,
    phase: gtk::PropagationPhase,
    action: &'static str,
    triggers: &'static [&'static str],
    listing: ShortcutListing,
) -> Accelerator {
    Accelerator {
        action,
        triggers,
        scope: Local { owner, phase },
        listing,
    }
}

const fn component(
    owner: ShortcutOwner,
    action: &'static str,
    triggers: &'static [&'static str],
    listing: ShortcutListing,
) -> Accelerator {
    Accelerator {
        action,
        triggers,
        scope: Component(owner),
        listing,
    }
}

/// Every key the app binds or relies on. History is on Ctrl+Shift+H, not
/// Ctrl+H: an application accelerator runs before the focused widget, and
/// Ctrl+H is find and replace in a text editor.
pub const ACCELERATORS: &[Accelerator] = &[
    application("app.new-window", &["<Primary><Shift>n"], General),
    application("app.preferences", &["<Primary>comma"], General),
    application("win.show-history", &["<Primary><Shift>h"], General),
    // As in GNOME Files.
    application("win.show-sidebar", &["F9"], General),
    application("win.show-assistant", &["<Primary><Alt>a"], General),
    application("app.quit", &["<Primary>q"], General),
    // AdwApplication adds the action and its accelerator once it finds
    // shortcuts-dialog.ui under the resource base path.
    stock("app.shortcuts", &["<Primary>question"], Listed(General)),
    stock("dialog.close", &["Escape"], Listed(General)),
    application("win.new-editor-tab", &["<Primary>t"], Tabs),
    application("win.close-current", &["<Primary>w"], Tabs),
    application("win.reopen-closed-tab", &["<Primary><Shift>t"], Tabs),
    // AdwTabView's own controller, which runs in the capture phase. The
    // workspace removes its Ctrl+Home and Ctrl+End pairs, so the lists
    // and the editor inside the tabs keep those keys.
    stock(
        "tab-view.select-next",
        &["<Primary>Tab", "<Primary>Page_Down"],
        Listed(Tabs),
    ),
    stock(
        "tab-view.select-previous",
        &["<Primary><Shift>Tab", "<Primary>Page_Up"],
        Listed(Tabs),
    ),
    stock("tab-view.move-next", &["<Primary><Shift>Page_Down"], Listed(Tabs)),
    stock("tab-view.move-previous", &["<Primary><Shift>Page_Up"], Listed(Tabs)),
    stock(
        "tab-view.select-number",
        &[
            "<Alt>1", "<Alt>2", "<Alt>3", "<Alt>4", "<Alt>5", "<Alt>6", "<Alt>7", "<Alt>8", "<Alt>9",
        ],
        Unlisted,
    ),
    stock("tab-view.select-tenth", &["<Alt>0"], Unlisted),
    local(BrowseTab, BUBBLE, "browse.filter", &["<Primary>f"], Listed(BrowseTable)),
    // F5 as in GNOME Files, and Ctrl+R as the GNOME HIG names Reload.
    local(
        BrowseTab,
        BUBBLE,
        "browse.refresh",
        &["F5", "<Primary>r"],
        Listed(BrowseTable),
    ),
    local(BrowseTab, BUBBLE, "browse.save", &["<Primary>s"], Listed(BrowseTable)),
    local(BrowseTab, BUBBLE, "browse.undo", &["<Primary>z"], Listed(BrowseTable)),
    local(
        BrowseTab,
        BUBBLE,
        "browse.redo",
        &["<Primary><Shift>z", "<Primary>y"],
        Listed(BrowseTable),
    ),
    // GtkListBase binds Page Up and Page Down with no modifier, Ctrl,
    // Shift and Ctrl+Shift to move within the rows on screen, so paging
    // takes Alt, which no widget in the tab binds.
    local(
        BrowseTab,
        BUBBLE,
        "browse.previous-page",
        &["<Alt>Page_Up"],
        Listed(BrowseTable),
    ),
    local(
        BrowseTab,
        BUBBLE,
        "browse.next-page",
        &["<Alt>Page_Down"],
        Listed(BrowseTable),
    ),
    stock("list.select-all", &["<Primary>a"], Listed(BrowseTable)),
    stock("list.unselect-all", &["<Primary><Shift>a"], Listed(BrowseTable)),
    stock("list.first-row", &["<Primary>Home"], Listed(BrowseTable)),
    stock("list.last-row", &["<Primary>End"], Listed(BrowseTable)),
    stock(
        "list.extend-selection",
        &["<Shift>Pointer_Button1"],
        Listed(BrowseTable),
    ),
    stock(
        "list.toggle-selection",
        &["<Primary>Pointer_Button1"],
        Listed(BrowseTable),
    ),
    stock("list.move", &["Up", "Down", "Left", "Right"], Listed(DataGrid)),
    component(GridCell, "cell.edit", &["F2", "Return"], Listed(DataGrid)),
    component(GridCell, "cell.toggle", &["space"], Listed(DataGrid)),
    component(GridCell, "cell.menu", &["Menu", "<Shift>F10"], Listed(DataGrid)),
    component(GridCell, "cell.set-null", &["<Primary>BackSpace"], Listed(DataGrid)),
    component(GridCell, "cell.open-referenced-row", &["<Primary>j"], Listed(DataGrid)),
    // GtkTreeView's keys for its focused header. A column view's header
    // takes no focus, so they act on the focused cell's column.
    component(GridCell, "cell.widen-column", &["<Shift><Alt>Right"], Listed(DataGrid)),
    component(GridCell, "cell.narrow-column", &["<Shift><Alt>Left"], Listed(DataGrid)),
    stock("text.activate", &["Return"], Listed(DataGrid)),
    component(CellEditor, "cell-editor.cancel", &["Escape"], Listed(DataGrid)),
    component(CellEditor, "cell-editor.next", &["Tab"], Listed(DataGrid)),
    component(CellEditor, "cell-editor.previous", &["<Shift>Tab"], Listed(DataGrid)),
    component(
        CellEditor,
        "cell-editor.save-text",
        &["<Primary>Return"],
        Listed(DataGrid),
    ),
    component(CellEditor, "cell-editor.pick-date", &["space"], Unlisted),
    local(
        BrowseGrid,
        BUBBLE,
        "browse.insert-row",
        &["<Primary>n"],
        Listed(DataGrid),
    ),
    local(BrowseGrid, BUBBLE, "browse.delete-rows", &["Delete"], Listed(DataGrid)),
    local(
        BrowseGrid,
        BUBBLE,
        "browse.copy-rows",
        &["<Primary>c"],
        Listed(DataGrid),
    ),
    local(
        BrowseGrid,
        BUBBLE,
        "browse.paste-rows",
        &["<Primary>v"],
        Listed(DataGrid),
    ),
    local(
        BrowseGrid,
        BUBBLE,
        "browse.clear-selection",
        &["Escape"],
        Listed(DataGrid),
    ),
    local(
        SqlEditor,
        CAPTURE,
        "editor.run",
        &["<Primary>Return"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditor,
        CAPTURE,
        "editor.run-statement",
        &["<Primary><Shift>Return"],
        Listed(ShortcutSection::SqlEditor),
    ),
    // Enabled only while a query runs, so otherwise Escape goes on to the
    // completion popup.
    local(
        SqlEditor,
        CAPTURE,
        "editor.cancel",
        &["Escape"],
        Listed(ShortcutSection::SqlEditor),
    ),
    // GtkPaned's own binding, a signal rather than an action. Tab indents
    // in the editor and Ctrl+Tab switches tabs, so this is its way out.
    stock("paned.cycle-child-focus", &["F6"], Listed(ShortcutSection::SqlEditor)),
    local(
        SqlEditor,
        CAPTURE,
        "editor.format",
        &["<Primary><Shift>f"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditor,
        CAPTURE,
        "editor.toggle-comment",
        &["<Primary>slash"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditorCursors,
        CAPTURE,
        "editor.add-cursor-next-match",
        &["<Primary>d"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditorCursors,
        CAPTURE,
        "editor.add-cursors-all-matches",
        &["<Primary><Shift>l"],
        Listed(ShortcutSection::SqlEditor),
    ),
    // GNOME's window manager takes Ctrl+Alt+Up and Down, and GtkSourceView
    // binds Alt+Up and Down to move lines. This takes its Shift+Alt+Up and
    // Down, which scroll by one line.
    local(
        SqlEditorCursors,
        CAPTURE,
        "editor.add-cursor-above",
        &["<Shift><Alt>Up"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditorCursors,
        CAPTURE,
        "editor.add-cursor-below",
        &["<Shift><Alt>Down"],
        Listed(ShortcutSection::SqlEditor),
    ),
    // Enabled only with more than one cursor, so otherwise Escape goes on.
    local(
        SqlEditorCursors,
        CAPTURE,
        "editor.single-cursor",
        &["Escape"],
        Listed(ShortcutSection::SqlEditor),
    ),
    // As Ctrl+click toggles a row in a list.
    component(
        SqlEditorCursors,
        "editor.toggle-cursor",
        &["<Primary>Pointer_Button1"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditorTab,
        BUBBLE,
        "editor.open-file",
        &["<Primary>o"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditorTab,
        BUBBLE,
        "editor.save",
        &["<Primary>s"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditorTab,
        BUBBLE,
        "editor.save-as",
        &["<Primary><Shift>s"],
        Listed(ShortcutSection::SqlEditor),
    ),
    // GtkSearchEntry binds Ctrl+G and Ctrl+Shift+G itself, and the find
    // bar follows its next-match and previous-match signals.
    local(
        SqlEditorTab,
        BUBBLE,
        "editor.find",
        &["<Primary>f"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditorTab,
        BUBBLE,
        "editor.find-replace",
        &["<Primary>h"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditorTab,
        BUBBLE,
        "editor.find-next",
        &["<Primary>g"],
        Listed(ShortcutSection::SqlEditor),
    ),
    local(
        SqlEditorTab,
        BUBBLE,
        "editor.find-previous",
        &["<Primary><Shift>g"],
        Listed(ShortcutSection::SqlEditor),
    ),
    // Only while a suggestion shows: otherwise Tab indents and Escape
    // goes on to the editor.
    component(
        InlineSuggestion,
        "suggestion.accept",
        &["Tab"],
        Listed(ShortcutSection::SqlEditor),
    ),
    component(
        InlineSuggestion,
        "suggestion.dismiss",
        &["Escape"],
        Listed(ShortcutSection::SqlEditor),
    ),
    // Shift+Return starts a new line, as in a chat.
    component(AssistantComposer, "assistant.send", &["Return"], Unlisted),
    local(
        StructureTab,
        BUBBLE,
        "structure.save",
        &["<Primary>s"],
        Listed(TableStructure),
    ),
    local(FilterStrip, BUBBLE, "filter.close", &["Escape"], Unlisted),
    local(
        SidebarList,
        BUBBLE,
        "sidebar.context-menu",
        &["Menu", "<Shift>F10"],
        Unlisted,
    ),
    local(
        HistoryRow,
        BUBBLE,
        "history-row.menu",
        &["Menu", "<Shift>F10"],
        Unlisted,
    ),
    local(PickerRow, BUBBLE, "picker-row.menu", &["Menu", "<Shift>F10"], Unlisted),
    // The GNOME HIG's zoom keys, with Ctrl+= for a keyboard where + needs
    // Shift.
    local(
        DiagramTab,
        BUBBLE,
        "diagram.zoom-in",
        &["<Primary>plus", "<Primary>equal"],
        Listed(ErDiagram),
    ),
    local(
        DiagramTab,
        BUBBLE,
        "diagram.zoom-out",
        &["<Primary>minus"],
        Listed(ErDiagram),
    ),
    local(
        DiagramTab,
        BUBBLE,
        "diagram.zoom-reset",
        &["<Primary>0"],
        Listed(ErDiagram),
    ),
    // As in Image Viewer. Nothing in the tab takes text.
    local(DiagramTab, BUBBLE, "diagram.zoom-fit", &["f"], Listed(ErDiagram)),
    local(
        DiagramTab,
        BUBBLE,
        "diagram.refresh",
        &["F5", "<Primary>r"],
        Listed(ErDiagram),
    ),
    local(
        DiagramCanvas,
        BUBBLE,
        "diagram.open-table",
        &["Return"],
        Listed(ErDiagram),
    ),
    local(
        DiagramCanvas,
        BUBBLE,
        "diagram.context-menu",
        &["Menu", "<Shift>F10"],
        Unlisted,
    ),
    // The arrow keys alone move the focus from table to table, as they
    // do between any widgets.
    local(
        DiagramCanvas,
        BUBBLE,
        "diagram.move-table-left",
        &["<Alt>Left"],
        Listed(ErDiagram),
    ),
    local(
        DiagramCanvas,
        BUBBLE,
        "diagram.move-table-right",
        &["<Alt>Right"],
        Listed(ErDiagram),
    ),
    local(
        DiagramCanvas,
        BUBBLE,
        "diagram.move-table-up",
        &["<Alt>Up"],
        Listed(ErDiagram),
    ),
    local(
        DiagramCanvas,
        BUBBLE,
        "diagram.move-table-down",
        &["<Alt>Down"],
        Listed(ErDiagram),
    ),
    local(
        PickerPage,
        BUBBLE,
        "picker-page.search",
        &["<Primary>f"],
        Listed(General),
    ),
];

pub fn install_application_accelerators(app: &impl IsA<gtk::Application>) {
    for entry in ACCELERATORS.iter().filter(|entry| entry.scope == Application) {
        app.set_accels_for_action(entry.action, entry.triggers);
    }
}

/// The owner's Local entries, each through the action it names, so a
/// disabled action lets its key go on.
pub fn local_shortcut_controller(owner: ShortcutOwner) -> gtk::ShortcutController {
    let controller = gtk::ShortcutController::new();
    controller.set_scope(gtk::ShortcutScope::Local);
    controller.set_name(Some(controller_name(owner)));
    for entry in ACCELERATORS {
        let Local { owner: of, phase } = entry.scope else {
            continue;
        };
        if of != owner {
            continue;
        }
        controller.set_propagation_phase(phase);
        for trigger in entry.triggers {
            if let Some(trigger) = shortcut_trigger(&[trigger]) {
                controller.add_shortcut(gtk::Shortcut::new(
                    Some(trigger),
                    Some(gtk::NamedAction::new(entry.action)),
                ));
            }
        }
    }
    controller
}

/// The name `local_shortcut_controller` gives the owner's controller.
pub const fn controller_name(owner: ShortcutOwner) -> &'static str {
    match owner {
        BrowseTab => "tablepro-browse-tab-shortcuts",
        BrowseGrid => "tablepro-browse-grid-shortcuts",
        GridCell => "tablepro-grid-cell-shortcuts",
        CellEditor => "tablepro-cell-editor-shortcuts",
        SqlEditor => "tablepro-sql-editor-shortcuts",
        SqlEditorCursors => "tablepro-sql-editor-cursor-shortcuts",
        SqlEditorTab => "tablepro-sql-editor-tab-shortcuts",
        StructureTab => "tablepro-structure-tab-shortcuts",
        FilterStrip => "tablepro-filter-strip-shortcuts",
        SidebarList => "tablepro-sidebar-list-shortcuts",
        HistoryRow => "tablepro-history-row-shortcuts",
        PickerRow => "tablepro-picker-row-shortcuts",
        DiagramTab => "tablepro-diagram-tab-shortcuts",
        DiagramCanvas => "tablepro-diagram-canvas-shortcuts",
        PickerPage => "tablepro-picker-page-shortcuts",
        InlineSuggestion => "tablepro-inline-suggestion-shortcuts",
        AssistantComposer => "tablepro-assistant-composer-shortcuts",
    }
}

pub fn triggers_for(action: &str) -> &'static [&'static str] {
    ACCELERATORS
        .iter()
        .find(|entry| entry.action == action)
        .map_or(&[], |entry| entry.triggers)
}

/// The keys for a component's own controller, so what it binds is what
/// the table lists.
pub fn component_trigger(action: &str) -> Option<gtk::ShortcutTrigger> {
    shortcut_trigger(triggers_for(action))
}

/// For a component that reads its keys from an event controller.
pub fn component_matches(action: &str, keyval: gdk::Key, state: gdk::ModifierType) -> bool {
    let modifiers = state & gtk::accelerator_get_default_mod_mask();
    let keyval = keyval.to_lower();
    triggers_for(action)
        .iter()
        .filter_map(|accel| parse(accel))
        .any(|(key, mods)| mods == modifiers && (key == keyval || keypad_twins(key).contains(&keyval)))
}

/// The SQL editor's own Ctrl keys, which Vim mode leaves to the editor in
/// every mode. A trigger, so an event matches it as the editor's shortcut
/// controllers match it, layout and consumed Shift included. Escape and
/// the other plain keys are Vim's.
pub fn editor_kept_keys() -> Option<gtk::ShortcutTrigger> {
    let accels: Vec<&str> = ACCELERATORS
        .iter()
        .filter(|entry| is_editors(entry))
        .flat_map(|entry| entry.triggers.iter().copied())
        .filter(|accel| parse(accel).is_some_and(|(_, mods)| mods.contains(gdk::ModifierType::CONTROL_MASK)))
        .collect();
    shortcut_trigger(&accels)
}

fn is_editors(entry: &Accelerator) -> bool {
    matches!(
        entry.scope,
        Local {
            owner: SqlEditor | SqlEditorTab,
            ..
        }
    )
}

/// GtkPopoverMenu shows an application accelerator by itself; a Local or
/// Component one has to be put on the item.
pub fn menu_item(label: &str, detailed_action: &str) -> gio::MenuItem {
    let item = gio::MenuItem::new(Some(label), Some(detailed_action));
    let shown = ACCELERATORS
        .iter()
        .find(|entry| entry.action == detailed_action && matches!(entry.scope, Local { .. } | Component(_)))
        .and_then(|entry| entry.triggers.first());
    if let Some(accel) = shown {
        item.set_attribute_value("accel", Some(&accel.to_variant()));
    }
    item
}

/// One trigger for all of `accels`, with the keypad twin of each key, as
/// GTK's own classes bind them.
fn shortcut_trigger(accels: &[&str]) -> Option<gtk::ShortcutTrigger> {
    accels
        .iter()
        .filter_map(|accel| parse(accel))
        .flat_map(|(key, modifiers)| {
            std::iter::once(key)
                .chain(keypad_twins(key).iter().copied())
                .map(move |key| gtk::KeyvalTrigger::new(key, modifiers).upcast::<gtk::ShortcutTrigger>())
        })
        .reduce(|first, second| gtk::AlternativeTrigger::new(first, second).upcast())
}

fn parse(accel: &str) -> Option<(gdk::Key, gdk::ModifierType)> {
    let parsed = gtk::accelerator_parse(accel);
    if parsed.is_none() {
        tracing::error!(accel, "an accelerator in the table does not parse; it is not bound");
    }
    parsed
}

pub(crate) fn keypad_twins(key: gdk::Key) -> &'static [gdk::Key] {
    match key {
        gdk::Key::Return => &[gdk::Key::ISO_Enter, gdk::Key::KP_Enter],
        gdk::Key::space => &[gdk::Key::KP_Space],
        gdk::Key::Delete => &[gdk::Key::KP_Delete],
        gdk::Key::Left => &[gdk::Key::KP_Left],
        gdk::Key::Right => &[gdk::Key::KP_Right],
        gdk::Key::Up => &[gdk::Key::KP_Up],
        gdk::Key::Down => &[gdk::Key::KP_Down],
        gdk::Key::plus => &[gdk::Key::KP_Add],
        gdk::Key::minus => &[gdk::Key::KP_Subtract],
        gdk::Key::_0 => &[gdk::Key::KP_0],
        _ => &[],
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};

    use libadwaita as adw;

    use super::*;
    use crate::test_support::shortcut_keys::{Keystroke, keystroke, keystrokes_with_twins, shortcuts, trigger_keys};

    /// Keys a window runs before the focused widget sees them: the
    /// application's, and the stock ones AdwApplication and AdwTabView
    /// add in the same capture phase.
    fn reaches_window_first(entry: &Accelerator) -> bool {
        entry.scope == Application || entry.action == "app.shortcuts" || entry.action.starts_with("tab-view.")
    }

    fn owner_of(entry: &Accelerator) -> Option<ShortcutOwner> {
        match entry.scope {
            Local { owner, .. } | Component(owner) => Some(owner),
            Application | Stock => None,
        }
    }

    /// The dialog shows these through `action-name`, so it shows the
    /// accelerator GTK has installed.
    fn shown_by_action_name(entry: &Accelerator) -> bool {
        entry.scope == Application || entry.action == "app.shortcuts"
    }

    #[gtk4::test]
    fn every_trigger_parses() {
        for entry in ACCELERATORS {
            assert!(!entry.triggers.is_empty(), "{} has no keys", entry.action);
            for accel in entry.triggers {
                assert!(gtk::accelerator_parse(*accel).is_some(), "{accel} of {}", entry.action);
                assert!(
                    gtk::ShortcutTrigger::parse_string(accel).is_some(),
                    "{accel} of {}",
                    entry.action
                );
            }
        }
    }

    #[gtk4::test]
    fn no_local_or_component_trigger_shadows_an_application_trigger() {
        let first: HashSet<Keystroke> = ACCELERATORS
            .iter()
            .filter(|entry| reaches_window_first(entry))
            .flat_map(|entry| entry.triggers.iter().map(|accel| keystroke(accel)))
            .collect();
        assert!(first.contains(&keystroke("<Primary>w")));

        for entry in ACCELERATORS {
            let Some(owner) = owner_of(entry) else {
                continue;
            };
            for accel in entry.triggers {
                for key in keystrokes_with_twins(accel) {
                    assert!(
                        !first.contains(&key),
                        "{accel} of {} is taken before it reaches {owner:?}",
                        entry.action
                    );
                }
            }
        }
    }

    #[gtk4::test]
    fn application_scope_avoids_text_editing_and_editor_keys() {
        let reserved: HashSet<Keystroke> = ["z", "y", "a", "c", "v", "x", "f", "g", "h", "slash"]
            .iter()
            .map(|key| keystroke(&format!("<Primary>{key}")))
            .chain(
                ["z", "g"]
                    .iter()
                    .map(|key| keystroke(&format!("<Primary><Shift>{key}"))),
            )
            .collect();
        let with_any_modifier = [
            gdk::Key::F5,
            gdk::Key::Escape,
            gdk::Key::Return,
            gdk::Key::Delete,
            gdk::Key::F2,
            gdk::Key::BackSpace,
            gdk::Key::Home,
            gdk::Key::End,
            gdk::Key::Tab,
            gdk::Key::Page_Up,
            gdk::Key::Page_Down,
            gdk::Key::Up,
            gdk::Key::Down,
            gdk::Key::Left,
            gdk::Key::Right,
        ];

        for entry in ACCELERATORS.iter().filter(|entry| entry.scope == Application) {
            for accel in entry.triggers {
                let key = keystroke(accel);
                assert!(!reserved.contains(&key), "{} takes {accel}", entry.action);
                assert!(!with_any_modifier.contains(&key.0), "{} takes {accel}", entry.action);
            }
        }
    }

    #[gtk4::test]
    fn no_duplicate_trigger_within_an_owner() {
        let mut seen: HashMap<(Option<ShortcutOwner>, Keystroke), &str> = HashMap::new();
        for entry in ACCELERATORS {
            let group = match owner_of(entry) {
                Some(owner) => Some(owner),
                None if reaches_window_first(entry) => None,
                None => continue,
            };
            for accel in entry.triggers {
                for key in keystrokes_with_twins(accel) {
                    if let Some(other) = seen.insert((group, key), entry.action) {
                        panic!("{accel} is both {other} and {}", entry.action);
                    }
                }
            }
        }
    }

    #[test]
    fn each_action_has_one_entry() {
        let mut seen = HashSet::new();
        for entry in ACCELERATORS {
            assert!(seen.insert(entry.action), "{} has two entries", entry.action);
        }
    }

    #[test]
    fn each_local_owner_runs_in_one_phase() {
        let mut phases: HashMap<ShortcutOwner, gtk::PropagationPhase> = HashMap::new();
        for entry in ACCELERATORS {
            if let Local { owner, phase } = entry.scope {
                let first = *phases.entry(owner).or_insert(phase);
                assert_eq!(first, phase, "{owner:?} mixes phases at {}", entry.action);
            }
        }
    }

    #[gtk4::test]
    fn local_shortcut_controller_names_each_trigger() {
        let mut owners: Vec<ShortcutOwner> = Vec::new();
        for entry in ACCELERATORS {
            if let Local { owner, .. } = entry.scope
                && !owners.contains(&owner)
            {
                owners.push(owner);
            }
        }
        for owner in owners {
            let controller = local_shortcut_controller(owner);
            let mut expected = Vec::new();
            for entry in ACCELERATORS {
                if let Local { owner: of, phase } = entry.scope
                    && of == owner
                {
                    assert_eq!(controller.propagation_phase(), phase, "{owner:?}");
                    for accel in entry.triggers {
                        expected.push((entry.action.to_owned(), keystrokes_with_twins(accel)));
                    }
                }
            }

            let found: Vec<(String, Vec<Keystroke>)> = shortcuts(&controller)
                .iter()
                .map(|shortcut| {
                    let action = shortcut
                        .action()
                        .and_downcast::<gtk::NamedAction>()
                        .map(|action| action.action_name().to_string())
                        .unwrap_or_default();
                    let keys = shortcut
                        .trigger()
                        .map(|trigger| trigger_keys(&trigger))
                        .unwrap_or_default();
                    (action, keys)
                })
                .collect();

            assert_eq!(found, expected, "{owner:?}");
            assert_eq!(controller.scope(), gtk::ShortcutScope::Local);
            assert_eq!(controller.name().as_deref(), Some(controller_name(owner)));
        }
    }

    #[gtk4::test]
    fn menu_item_shows_local_and_component_keys() {
        let accel = |item: &gio::MenuItem| {
            item.attribute_value("accel", None)
                .and_then(|value| value.get::<String>())
        };

        assert_eq!(
            accel(&menu_item("Set to NULL", "cell.set-null")).as_deref(),
            Some("<Primary>BackSpace")
        );
        assert_eq!(accel(&menu_item("Edit Cell", "cell.edit")).as_deref(), Some("F2"));
        assert_eq!(
            accel(&menu_item("New Window", "app.new-window")),
            None,
            "GTK shows its own"
        );
        assert_eq!(accel(&menu_item("Copy", "cell.copy")), None);
    }

    #[gtk4::test]
    fn component_matches_reads_the_table_and_keypad_twins() {
        let none = gdk::ModifierType::empty();

        assert!(component_matches("cell-editor.pick-date", gdk::Key::space, none));
        assert!(component_matches("cell-editor.pick-date", gdk::Key::KP_Space, none));
        assert!(component_matches(
            "cell-editor.pick-date",
            gdk::Key::space,
            gdk::ModifierType::LOCK_MASK
        ));
        assert!(!component_matches(
            "cell-editor.pick-date",
            gdk::Key::space,
            gdk::ModifierType::CONTROL_MASK
        ));
        assert!(!component_matches("cell-editor.pick-date", gdk::Key::Return, none));
    }

    #[gtk4::test]
    fn the_editor_keeps_its_ctrl_keys_from_vim() {
        let kept: HashSet<Keystroke> = trigger_keys(&editor_kept_keys().expect("the editor has Ctrl keys"))
            .into_iter()
            .collect();

        for accel in [
            "<Primary>Return",
            "<Primary>KP_Enter",
            "<Primary><Shift>Return",
            "<Primary><Shift>f",
            "<Primary>slash",
            "<Primary>f",
            "<Primary>h",
            "<Primary>g",
            "<Primary><Shift>g",
            "<Primary>o",
            "<Primary>s",
            "<Primary><Shift>s",
        ] {
            assert!(kept.contains(&keystroke(accel)), "{accel}");
        }
        for accel in ["Escape", "<Primary>r", "<Primary>d", "<Primary>v", "<Primary>w", "f"] {
            assert!(!kept.contains(&keystroke(accel)), "{accel}");
        }
    }

    #[gtk4::test]
    fn every_ctrl_key_of_the_editor_is_kept_from_vim() {
        let kept: HashSet<Keystroke> = trigger_keys(&editor_kept_keys().expect("the editor has Ctrl keys"))
            .into_iter()
            .collect();
        let owned: HashSet<Keystroke> = ACCELERATORS
            .iter()
            .filter(|entry| is_editors(entry))
            .flat_map(|entry| entry.triggers.iter())
            .flat_map(|accel| keystrokes_with_twins(accel))
            .filter(|(_, mods)| mods.contains(gdk::ModifierType::CONTROL_MASK))
            .collect();

        assert_eq!(kept, owned);
    }

    #[gtk4::test]
    fn shortcuts_dialog_matches_accelerator_table() {
        adw::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let builder =
            gtk::Builder::from_resource(&format!("{}/shortcuts-dialog.ui", crate::config::RESOURCE_BASE_PATH));
        let sections = [
            (ShortcutSection::General, "section-general"),
            (ShortcutSection::Tabs, "section-tabs"),
            (ShortcutSection::BrowseTable, "section-browse-table"),
            (ShortcutSection::DataGrid, "section-data-grid"),
            (ShortcutSection::SqlEditor, "section-sql-editor"),
            (ShortcutSection::TableStructure, "section-table-structure"),
            (ShortcutSection::ErDiagram, "section-er-diagram"),
        ];
        let mut placed: Vec<(adw::ShortcutsItem, ShortcutSection)> = Vec::new();
        for (section, id) in sections {
            let list = builder
                .object::<adw::ShortcutsSection>(id)
                .unwrap_or_else(|| panic!("the dialog has no {id}"));
            for position in 0..list.n_items() {
                let item = list
                    .item(position)
                    .and_downcast::<adw::ShortcutsItem>()
                    .expect("a shortcut item");
                placed.push((item, section));
            }
        }
        let objects = builder.objects();
        assert_eq!(
            objects
                .iter()
                .filter(|object| object.is::<adw::ShortcutsSection>())
                .count(),
            sections.len(),
            "a section the table does not know"
        );
        assert_eq!(
            objects
                .iter()
                .filter(|object| object.is::<adw::ShortcutsItem>())
                .count(),
            placed.len(),
            "an item outside the sections"
        );

        let mut listed = Vec::new();
        for entry in ACCELERATORS {
            let Listed(section) = entry.listing else {
                continue;
            };
            let id = entry.action.replace('.', "-");
            let item = builder
                .object::<adw::ShortcutsItem>(&id)
                .unwrap_or_else(|| panic!("the dialog does not list {}", entry.action));
            let found = placed
                .iter()
                .find(|(placed, _)| placed == &item)
                .map(|(_, section)| *section);
            assert_eq!(found, Some(section), "{} is in another section", entry.action);
            if shown_by_action_name(entry) {
                assert_eq!(item.action_name(), entry.action);
                assert_eq!(item.accelerator(), "", "{}", entry.action);
            } else {
                assert_eq!(item.accelerator(), entry.triggers.join(" "), "{}", entry.action);
                assert_eq!(item.action_name(), "", "{}", entry.action);
            }
            listed.push(item);
        }
        for (item, _) in &placed {
            assert!(
                listed.contains(item),
                "the dialog lists {:?}, which the table does not",
                item.title()
            );
        }
    }
}
