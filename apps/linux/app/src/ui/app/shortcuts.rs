use relm4::adw::prelude::*;
use relm4::gtk::gio;
use relm4::{ComponentSender, adw, gtk};

use super::{App, AppMsg};

pub(super) fn primary_menu_model() -> gio::Menu {
    let menu = gio::Menu::new();
    let connection_section = gio::Menu::new();
    let disconnect_item = gio::MenuItem::new(Some(&crate::tr!("Disconnect")), Some("win.disconnect"));
    disconnect_item.set_attribute_value("hidden-when", Some(&"action-disabled".to_variant()));
    connection_section.append_item(&disconnect_item);
    connection_section.append(Some(&crate::tr!("Back Up Database…")), Some("win.back-up-database"));
    connection_section.append(Some(&crate::tr!("Restore from Backup…")), Some("win.restore-database"));
    menu.append_section(None, &connection_section);
    let query_section = gio::Menu::new();
    query_section.append(Some(&crate::tr!("Open Quickly")), Some("win.open-quickly"));
    query_section.append(Some(&crate::tr!("Jump to Column…")), Some("win.jump-column"));
    query_section.append(
        Some(&crate::tr!("Reveal Table in Sidebar")),
        Some("win.reveal-in-sidebar"),
    );
    query_section.append(Some(&crate::tr!("Save Query as Favorite")), Some("win.save-favorite"));
    menu.append_section(None, &query_section);
    let history_section = gio::Menu::new();
    history_section.append(Some(&crate::tr!("Query History")), Some("win.show-history"));
    history_section.append(Some(&crate::tr!("Server activity")), Some("win.show-activity"));
    history_section.append(Some(&crate::tr!("Audit Log")), Some("win.show-audit"));
    history_section.append(Some(&crate::tr!("Catalog")), Some("win.show-catalog"));
    history_section.append(Some(&crate::tr!("Explain query")), Some("win.explain-query"));
    menu.append_section(None, &history_section);
    let prefs_section = gio::Menu::new();
    prefs_section.append(Some(&crate::tr!("Preferences")), Some("win.preferences"));
    prefs_section.append(Some(&crate::tr!("New Window")), Some("win.new-window"));
    menu.append_section(None, &prefs_section);
    let app_section = gio::Menu::new();
    app_section.append(Some(&crate::tr!("Keyboard Shortcuts")), Some("win.shortcuts"));
    app_section.append(Some(&crate::tr!("About BookiE")), Some("win.about"));
    app_section.append(Some(&crate::tr!("Quit")), Some("win.quit"));
    menu.append_section(None, &app_section);
    menu
}

pub(super) fn install_window_actions(
    window: &adw::ApplicationWindow,
    sender: ComponentSender<App>,
) -> gio::SimpleAction {
    let group = gio::SimpleActionGroup::new();
    macro_rules! input_action {
        ($name:expr, $msg:expr) => {{
            let s = sender.clone();
            gio::ActionEntry::builder($name)
                .activate(move |_, _, _| s.input($msg))
                .build()
        }};
    }
    let window_for_quit = window.clone();
    let quit = gio::ActionEntry::builder("quit")
        .activate(move |_, _, _| window_for_quit.close())
        .build();
    group.add_action_entries([
        input_action!("shortcuts", AppMsg::ShowShortcuts),
        input_action!("about", AppMsg::ShowAbout),
        quit,
        input_action!("open-editor", AppMsg::NewEditorTab),
        input_action!("open-file", AppMsg::OpenSqlFile),
        input_action!("save-file-as", AppMsg::SaveActiveEditorFileAs),
        input_action!("close-current", AppMsg::CloseActiveWorkspaceTab),
        input_action!("preferences", AppMsg::ShowPreferences),
        input_action!("new-window", AppMsg::NewWindow),
        input_action!("show-history", AppMsg::ShowHistory),
        input_action!("show-activity", AppMsg::ShowActivity),
        input_action!("show-audit", AppMsg::ShowAuditLog),
        input_action!("show-catalog", AppMsg::ShowCatalog),
        input_action!("explain-query", AppMsg::ExplainActiveQuery),
        input_action!("refresh-page", AppMsg::RefreshPage),
        input_action!("jump-column", AppMsg::JumpToColumn),
        input_action!("reveal-in-sidebar", AppMsg::RevealInSidebar),
        input_action!("recent-tab", AppMsg::SwitchToRecentTab),
        input_action!("recent-tab-end", AppMsg::EndRecentTabWalk),
        input_action!("export-csv", AppMsg::ExportCsv),
        input_action!("export-json", AppMsg::ExportJson),
        input_action!("export-all-csv", AppMsg::ExportAllCsv),
        input_action!("export-all-json", AppMsg::ExportAllJson),
        input_action!("save-changes", AppMsg::SaveActiveBrowseTab),
        input_action!("undo-change", AppMsg::UndoActiveBrowseTab),
        input_action!("redo-change", AppMsg::RedoActiveBrowseTab),
        input_action!("reopen-closed-tab", AppMsg::ReopenClosedTab),
        input_action!("open-filter", AppMsg::ShowFilterDialog),
        input_action!("open-quickly", AppMsg::ShowQuickSwitcher),
        input_action!("save-favorite", AppMsg::SaveQueryAsFavorite),
        input_action!("show-saved-queries", AppMsg::ShowSavedQueries),
        input_action!("back-up-database", AppMsg::BackUpDatabase),
        input_action!("restore-database", AppMsg::RestoreDatabase),
    ]);
    let disconnect_action = gio::SimpleAction::new("disconnect", None);
    let disconnect_sender = sender.clone();
    disconnect_action.connect_activate(move |_, _| disconnect_sender.input(AppMsg::Disconnect));
    group.add_action(&disconnect_action);
    window.insert_action_group("win", Some(&group));
    disconnect_action.set_enabled(false);
    tracing::info!(enabled = disconnect_action.is_enabled(), "registered win.disconnect");
    disconnect_action
}

pub(super) const WINDOW_SHORTCUTS: &[(&str, &str)] = &[
    ("<Primary>question", "win.shortcuts"),
    ("<Primary>q", "win.quit"),
    ("<Primary>w", "win.close-current"),
    ("<Primary>e", "win.open-editor"),
    ("<Primary>t", "win.open-editor"),
    ("<Primary>o", "win.open-file"),
    ("F5", "win.refresh-page"),
    ("<Primary>f", "win.open-filter"),
    ("<Primary>comma", "win.preferences"),
    ("<Primary>h", "win.show-history"),
    ("<Primary>p", "win.open-quickly"),
    ("<Primary><Shift>j", "win.jump-column"),
    ("<Primary><Shift>l", "win.reveal-in-sidebar"),
    ("<Primary>d", "win.save-favorite"),
    ("<Primary><Shift>d", "win.show-saved-queries"),
    ("<Primary>s", "win.save-changes"),
    ("<Primary><Shift>s", "win.save-file-as"),
    ("<Primary>z", "win.undo-change"),
    ("<Primary>y", "win.redo-change"),
    ("<Primary><Shift>z", "win.redo-change"),
    ("<Primary><Shift>t", "win.reopen-closed-tab"),
];

pub(super) fn install_window_shortcuts(window: &adw::ApplicationWindow) {
    let controller = gtk::ShortcutController::new();
    controller.set_scope(gtk::ShortcutScope::Global);
    for (trigger, action) in WINDOW_SHORTCUTS {
        controller.add_shortcut(make_shortcut(trigger, action));
    }
    window.add_controller(controller);
    install_recent_tab_key(window);
}

fn install_recent_tab_key(window: &adw::ApplicationWindow) {
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let target = window.clone();
    keys.connect_key_pressed(move |_, key, _, state| {
        let ctrl_only =
            state.contains(gtk::gdk::ModifierType::CONTROL_MASK) && !state.contains(gtk::gdk::ModifierType::SHIFT_MASK);
        if key != gtk::gdk::Key::Tab || !ctrl_only {
            return glib::Propagation::Proceed;
        }
        let _ = gtk::prelude::WidgetExt::activate_action(&target, "win.recent-tab", None);
        glib::Propagation::Stop
    });
    let target = window.clone();
    keys.connect_key_released(move |_, key, _, _| {
        if matches!(key, gtk::gdk::Key::Control_L | gtk::gdk::Key::Control_R) {
            let _ = gtk::prelude::WidgetExt::activate_action(&target, "win.recent-tab-end", None);
        }
    });
    window.add_controller(keys);
}

fn make_shortcut(trigger: &str, action: &str) -> gtk::Shortcut {
    gtk::Shortcut::builder()
        .trigger(&crate::ui::shortcut::parse(trigger))
        .action(&gtk::NamedAction::new(action))
        .build()
}

pub(super) fn build_shortcuts_dialog() -> adw::ShortcutsDialog {
    let dialog = adw::ShortcutsDialog::builder()
        .title(crate::tr!("Keyboard Shortcuts"))
        .build();
    add_shortcut_group(
        &dialog,
        &crate::tr!("General"),
        &[
            ("<Primary>e", crate::tr!("Open SQL editor")),
            ("<Primary>j", crate::tr!("Show or hide query results in the editor")),
            ("<Primary>o", crate::tr!("Open a SQL file in a new editor tab")),
            ("F5", crate::tr!("Refresh table")),
            ("<Primary>comma", crate::tr!("Open Preferences")),
            ("<Primary>h", crate::tr!("Open Query History")),
            ("<Primary>p", crate::tr!("Open Quickly: favorites and open tabs")),
            ("<Primary><Shift>l", crate::tr!("Reveal the open table in the sidebar")),
            ("<Primary>d", crate::tr!("Save the editor query as a favorite")),
            ("<Primary><Shift>d", crate::tr!("Manage saved queries")),
            ("<Primary>question", crate::tr!("Show keyboard shortcuts")),
            ("<Primary>q", crate::tr!("Quit")),
        ],
    );
    add_shortcut_group(
        &dialog,
        &crate::tr!("Browse table"),
        &[
            ("F2", crate::tr!("Edit focused cell (or press Return)")),
            ("Tab", crate::tr!("Move to next cell (commits if editing)")),
            ("<Shift>Tab", crate::tr!("Move to previous cell (commits if editing)")),
            ("Left", crate::tr!("Move to previous cell")),
            ("Right", crate::tr!("Move to next cell")),
            ("Up", crate::tr!("Move to cell above")),
            ("Down", crate::tr!("Move to cell below")),
            ("space", crate::tr!("Toggle boolean cell")),
            ("<Primary>n", crate::tr!("Insert row")),
            ("Delete", crate::tr!("Delete selected row")),
            ("<Primary><Shift>n", crate::tr!("Set focused cell to NULL")),
            ("<Primary>f", crate::tr!("Filter rows")),
            ("<Primary><Shift>j", crate::tr!("Jump to Column (focused grid)")),
            ("<Primary><Alt>f", crate::tr!("Find in loaded rows (focused grid)")),
            ("<Primary>a", crate::tr!("Select all rows")),
            ("<Primary>c", crate::tr!("Copy selected rows as TSV")),
            ("Page_Up", crate::tr!("Previous page")),
            ("Page_Down", crate::tr!("Next page")),
            ("<Primary>Home", crate::tr!("Jump to first row of page")),
            ("<Primary>End", crate::tr!("Jump to last row of page")),
        ],
    );
    add_shortcut_group(
        &dialog,
        &crate::tr!("Row selection"),
        &[
            ("Shift-click", crate::tr!("Extend selection to the clicked row")),
            ("Ctrl-click", crate::tr!("Toggle the clicked row in selection")),
        ],
    );
    add_shortcut_group(
        &dialog,
        &crate::tr!("SQL editor"),
        &[
            ("<Primary>Return", crate::tr!("Run query")),
            ("<Primary><Shift>Return", crate::tr!("Run statement at cursor")),
            ("<Primary><Shift>s", crate::tr!("Save the SQL file as")),
            ("<Primary>slash", crate::tr!("Toggle line comment")),
            ("<Primary><Shift>bracketleft", crate::tr!("Fold SQL block at cursor")),
            ("<Primary><Shift>bracketright", crate::tr!("Unfold all SQL blocks")),
            ("<Primary>t", crate::tr!("New editor tab")),
            ("<Primary>w", crate::tr!("Close current tab or window")),
            ("<Primary>Tab", crate::tr!("Switch to the most recently used tab")),
            ("<Primary><Shift>Tab", crate::tr!("Previous editor tab")),
            ("<Primary><Shift>t", crate::tr!("Reopen last closed tab")),
            ("<Primary><Shift>f", crate::tr!("Format SQL")),
            ("<Alt><Shift>Down", crate::tr!("Jump to the next statement")),
            ("<Alt><Shift>Up", crate::tr!("Jump to the previous statement")),
        ],
    );
    add_shortcut_group(
        &dialog,
        &crate::tr!("Context-sensitive actions"),
        &[
            (
                "<Primary>s",
                crate::tr!("Save grid edits, the SQL file, or table structure changes"),
            ),
            (
                "<Primary>z",
                crate::tr!("Undo a grid, SQL editor, or table structure change"),
            ),
            (
                "<Primary>y",
                crate::tr!("Redo the current change (or press Ctrl+Shift+Z)"),
            ),
            (
                "Escape",
                crate::tr!("Cancel editing or a query, clear selection, or close a dialog"),
            ),
        ],
    );
    dialog
}

fn add_shortcut_group(dialog: &adw::ShortcutsDialog, title: &str, entries: &[(&str, String)]) {
    let group = adw::ShortcutsSection::new(Some(title));
    for (accelerator, title) in entries {
        let shortcut = if gtk::accelerator_parse(*accelerator).is_some() {
            adw::ShortcutsItem::new(title, accelerator)
        } else {
            let shortcut = adw::ShortcutsItem::new(title, "");
            shortcut.set_subtitle(&localized_browse_key(accelerator));
            shortcut
        };
        group.add(shortcut);
    }
    dialog.add(group);
}

fn localized_browse_key(key: &str) -> String {
    match key {
        "Left" => crate::tr!("Left"),
        "Right" => crate::tr!("Right"),
        "space" => crate::tr!("space"),
        "Shift-click" => crate::tr!("Shift-click"),
        "Ctrl-click" => crate::tr!("Ctrl-click"),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod window_shortcut_tests {
    use super::WINDOW_SHORTCUTS;
    use std::collections::HashSet;

    const EDITOR_OWNED: &[&str] = &[
        "<Primary>slash",
        "<Primary>Return",
        "<Primary><Shift>Return",
        "<Primary><Shift>f",
        "<Primary><Shift>bracketleft",
        "<Primary><Shift>bracketright",
    ];

    #[test]
    fn no_trigger_is_bound_twice_at_window_level() {
        let mut seen = HashSet::new();
        for (trigger, action) in WINDOW_SHORTCUTS {
            assert!(
                seen.insert(*trigger),
                "{trigger} is bound twice (second action {action})"
            );
        }
    }

    fn registered(action: &str) -> bool {
        let source = include_str!("shortcuts.rs");
        let name = action.trim_start_matches("win.");
        source.contains(&format!("input_action!(\"{name}\"")) || source.contains(&format!("builder(\"{name}\")"))
    }

    #[test]
    fn every_window_shortcut_names_an_action_the_window_registers() {
        for (trigger, action) in WINDOW_SHORTCUTS {
            assert!(
                registered(action),
                "{trigger} is bound to {action}, which is never registered"
            );
        }
    }

    #[test]
    fn every_window_shortcut_is_listed_in_the_shortcuts_window() {
        let source = include_str!("shortcuts.rs");
        let dialog = source
            .split("pub(super) fn build_shortcuts_dialog")
            .nth(1)
            .unwrap_or_default();
        let dialog = dialog.split("fn add_shortcut_group").next().unwrap_or_default();
        for (trigger, action) in WINDOW_SHORTCUTS {
            let documented = if *trigger == "<Primary><Shift>z" {
                dialog.contains("Ctrl+Shift+Z")
            } else {
                dialog.contains(&format!("\"{trigger}\""))
            };
            assert!(
                documented,
                "{trigger} ({action}) is not documented in the shortcuts window"
            );
        }
    }

    #[test]
    fn window_shortcuts_never_take_a_key_the_editor_owns() {
        for (trigger, action) in WINDOW_SHORTCUTS {
            assert!(
                !EDITOR_OWNED.contains(trigger),
                "{trigger} would steal an editor key for {action}"
            );
        }
    }
}

#[cfg(test)]
mod dialog_tests {
    use super::build_shortcuts_dialog;
    use adw::prelude::*;
    use relm4::{adw, gtk};

    fn visible_contents(dialog: &adw::ShortcutsDialog) -> (Vec<String>, Vec<String>) {
        let mut labels = Vec::new();
        let mut accelerators = Vec::new();
        let mut pending = vec![dialog.clone().upcast::<gtk::Widget>()];
        while let Some(widget) = pending.pop() {
            if let Some(label) = widget.downcast_ref::<gtk::Label>().filter(|label| label.is_mapped()) {
                labels.push(label.text().to_string());
            }
            if let Some(label) = widget
                .downcast_ref::<adw::ShortcutLabel>()
                .filter(|label| label.is_mapped())
            {
                accelerators.push(label.accelerator().to_string());
            }
            let mut child = widget.first_child();
            while let Some(next) = child {
                child = next.next_sibling();
                pending.push(next);
            }
        }
        (labels, accelerators)
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn the_shortcuts_window_lists_keys_and_describes_mouse_gestures() {
        adw::init().unwrap();
        let window = adw::Window::new();
        window.set_default_size(400, 600);
        window.present();
        let dialog = build_shortcuts_dialog();
        dialog.present(Some(&window));
        let context = gtk::glib::MainContext::default();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let (labels, accelerators) = loop {
            while context.pending() {
                context.iteration(false);
            }
            let contents = visible_contents(&dialog);
            if contents.0.iter().any(|text| text == "Quit") || std::time::Instant::now() >= deadline {
                break contents;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        };
        for title in [
            "Quit",
            "Toggle the clicked row in selection",
            "Ctrl-click",
            "Shift-click",
            "Save grid edits, the SQL file, or table structure changes",
            "Edit focused cell (or press Return)",
        ] {
            assert_eq!(
                labels.iter().filter(|text| text.as_str() == title).count(),
                1,
                "{title}"
            );
        }
        assert!(accelerators.len() > 40);
        for accelerator in ["<Primary>q", "Up", "Down"] {
            assert!(accelerators.iter().any(|value| value == accelerator), "{accelerator}");
        }
        dialog.force_close();
        window.close();
    }
}
