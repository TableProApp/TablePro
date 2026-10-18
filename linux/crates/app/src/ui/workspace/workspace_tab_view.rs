use libadwaita as adw;

/// AdwTabView runs its shortcuts in a capture-phase, global controller,
/// so Ctrl+Home and Ctrl+End would switch tabs before the SQL editor or
/// a grid saw them. GNOME Text Editor removes the same four.
const CHILD_NAVIGATION_KEYS: adw::TabViewShortcuts = adw::TabViewShortcuts::CONTROL_HOME
    .union(adw::TabViewShortcuts::CONTROL_END)
    .union(adw::TabViewShortcuts::CONTROL_SHIFT_HOME)
    .union(adw::TabViewShortcuts::CONTROL_SHIFT_END);

pub(super) fn keep_child_navigation_keys(view: &adw::TabView) {
    view.remove_shortcuts(CHILD_NAVIGATION_KEYS);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn new_workspace_tab_view() -> adw::TabView {
        let view = adw::TabView::new();
        keep_child_navigation_keys(&view);
        view
    }

    #[gtk4::test]
    fn workspace_tab_view_leaves_buffer_navigation_keys_to_children() {
        adw::init().expect("libadwaita initialises under the test backend");

        let shortcuts = new_workspace_tab_view().shortcuts();

        assert!(
            !shortcuts.intersects(CHILD_NAVIGATION_KEYS),
            "the tab view still takes {:?}",
            shortcuts & CHILD_NAVIGATION_KEYS
        );
        let switching = adw::TabViewShortcuts::CONTROL_TAB
            | adw::TabViewShortcuts::CONTROL_SHIFT_TAB
            | adw::TabViewShortcuts::CONTROL_PAGE_UP
            | adw::TabViewShortcuts::CONTROL_PAGE_DOWN
            | adw::TabViewShortcuts::CONTROL_SHIFT_PAGE_UP
            | adw::TabViewShortcuts::CONTROL_SHIFT_PAGE_DOWN
            | adw::TabViewShortcuts::ALT_DIGITS
            | adw::TabViewShortcuts::ALT_ZERO;
        assert!(
            shortcuts.contains(switching),
            "a tab switching key was lost: {:?}",
            switching - shortcuts
        );
    }

    /// The table lists AdwTabView's keys as stock; it must list exactly
    /// the ones the workspace's tab view keeps.
    #[gtk4::test]
    fn tab_view_keys_in_the_table_are_the_ones_it_keeps() {
        use std::collections::HashSet;

        use crate::application::{ACCELERATORS, AcceleratorScope};
        use crate::test_support::shortcut_keys::keystroke;
        adw::init().expect("libadwaita initialises under the test backend");
        let alt_digits: Vec<String> = (1..=9).map(|digit| format!("<Alt>{digit}")).collect();
        let keys_of = |flag: adw::TabViewShortcuts| -> Vec<String> {
            let accels: &[&str] = match flag {
                adw::TabViewShortcuts::CONTROL_TAB => &["<Primary>Tab"],
                adw::TabViewShortcuts::CONTROL_SHIFT_TAB => &["<Primary><Shift>Tab"],
                adw::TabViewShortcuts::CONTROL_PAGE_UP => &["<Primary>Page_Up"],
                adw::TabViewShortcuts::CONTROL_PAGE_DOWN => &["<Primary>Page_Down"],
                adw::TabViewShortcuts::CONTROL_HOME => &["<Primary>Home"],
                adw::TabViewShortcuts::CONTROL_END => &["<Primary>End"],
                adw::TabViewShortcuts::CONTROL_SHIFT_PAGE_UP => &["<Primary><Shift>Page_Up"],
                adw::TabViewShortcuts::CONTROL_SHIFT_PAGE_DOWN => &["<Primary><Shift>Page_Down"],
                adw::TabViewShortcuts::CONTROL_SHIFT_HOME => &["<Primary><Shift>Home"],
                adw::TabViewShortcuts::CONTROL_SHIFT_END => &["<Primary><Shift>End"],
                adw::TabViewShortcuts::ALT_ZERO => &["<Alt>0"],
                _ => return alt_digits.clone(),
            };
            accels.iter().map(|accel| (*accel).to_owned()).collect()
        };
        let kept = new_workspace_tab_view().shortcuts();
        let mut expected = HashSet::new();
        for flag in adw::TabViewShortcuts::ALL_SHORTCUTS.iter() {
            if kept.contains(flag) {
                expected.extend(keys_of(flag).iter().map(|accel| keystroke(accel)));
            }
        }

        let listed: HashSet<_> = ACCELERATORS
            .iter()
            .filter(|entry| entry.scope == AcceleratorScope::Stock && entry.action.starts_with("tab-view."))
            .flat_map(|entry| entry.triggers.iter().map(|accel| keystroke(accel)))
            .collect();

        assert_eq!(listed, expected);
        assert!(
            !listed.contains(&keystroke("<Primary>Home")),
            "Ctrl+Home belongs to the tabs' content"
        );
    }
}
